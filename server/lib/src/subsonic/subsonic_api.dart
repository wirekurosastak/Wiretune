// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../auth_service.dart';
import '../library_scan_service.dart';
import '../user_data_service.dart';
import '../transcoder.dart';
import 'subsonic_format.dart';

/// What [SubsonicApi] needs from the server beyond the library and the accounts: the files it serves are the server's
/// to send, with its range support and its checks that a path lies inside the music folder.
typedef SendTrack = Future<Response> Function(Request request, Track track, [TranscodeRequest? convert]);

/// Sends the picture of an album, a track or an artist by [id]; a 404 when there is none.
typedef SendPicture = Future<Response> Function(Request request, String id);

/// The Subsonic API (`/rest/…`, with the OpenSubsonic additions that fit), so that the many apps that speak it can play
/// from a Wiretune server: Feishin, Symfonium, Amperfy, Tempo, Substreamer and others. It reads the same library and the
/// same favourites, play counts and playlists as the Wiretune API.
///
/// Apps sign in with the account's app password ([AuthService.createAppPassword]), never with its own password: these
/// apps send the secret with every request. What Wiretune has no counterpart for is answered with an error, not
/// pretended: starring an album or an artist, ratings, podcasts.
class SubsonicApi {
  SubsonicApi({
    required this.library,
    required this.auth,
    required this.userData,
    required this.scanner,
    required this.musicFolder,
    required this.sendStream,
    required this.sendPicture,
    required this.readLyrics,
    required this.dataChanged,
    required this.played,
  });

  final LibraryService library;
  final AuthService auth;
  final UserDataService userData;
  final LibraryScanService scanner;
  final String Function() musicFolder;
  final SendTrack sendStream;
  final SendPicture sendPicture;
  final Future<String?> Function(Track track) readLyrics;
  final void Function(String userId) dataChanged;

  /// An account played a track (an app said so): the server keeps it, and sends it on where the account wants that.
  final void Function(String userId, String trackId, DateTime? at) played;

  static const int _maxBody = 1024 * 1024;
  static const int _maxPage = 500;

  /// Answers a request to `/rest/<method>[.view]`.
  Future<Response> handle(Request request) async {
    final segments = request.url.pathSegments;
    final method = segments.length < 2 ? '' : segments[1].replaceFirst(RegExp(r'\.view$'), '');
    final params = await _parameters(request);
    final json = const {'json', 'jsonp'}.contains(params.text('f'));
    try {
      final principal = _authenticate(params);
      final result = await _call(method, params, principal, request);
      WiretuneLog.debug('Subsonic', '$method for ${principal.username}: ok');
      if (result is Response) return result;
      return subsonicResponse(subsonicEnvelope(Map<String, Object?>.from(result as Map)), json: json);
    } on SubsonicFailure catch (failure) {
      WiretuneLog.debug('Subsonic', '$method failed: ${failure.code} ${failure.message}');
      return subsonicResponse(subsonicEnvelope(const {}, failure), json: json);
    }
  }

  // ── Signing in ─────────────────────────────────────────────────────────────────────────────────

  Principal _authenticate(_Params params) {
    final apiKey = params.text('apiKey');
    final hasUser = params.text('u') != null;
    if (apiKey != null) {
      if (hasUser || params.text('p') != null || params.text('t') != null || params.text('s') != null) {
        throw const SubsonicFailure(
          SubsonicError.conflictingMechanisms,
          'Multiple conflicting authentication mechanisms provided.',
        );
      }
      final principal = auth.authenticateApp(apiKey: apiKey);
      if (principal == null) throw const SubsonicFailure(SubsonicError.invalidApiKey, 'Invalid API key.');
      return principal;
    }
    if (!hasUser) throw const SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: u.');
    if (params.text('p') == null && (params.text('t') == null || params.text('s') == null)) {
      throw const SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: p, or t and s.');
    }
    final principal = auth.authenticateApp(
      username: params.text('u'),
      password: params.text('p'),
      token: params.text('t'),
      salt: params.text('s'),
    );
    if (principal == null) {
      throw const SubsonicFailure(
        SubsonicError.wrongCredentials,
        'Wrong username or app password. Make an app password in Wiretune and use it here.',
      );
    }
    return principal;
  }

  Future<_Params> _parameters(Request request) async {
    final values = <String, List<String>>{};
    void add(Map<String, List<String>> more) {
      for (final MapEntry(:key, :value) in more.entries) {
        (values[key] ??= []).addAll(value);
      }
    }

    add(request.url.queryParametersAll);
    if (request.method == 'POST' &&
        (request.headers['content-type'] ?? '').startsWith('application/x-www-form-urlencoded')) {
      final bytes = <int>[];
      await for (final chunk in request.read()) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) throw const SubsonicFailure(SubsonicError.generic, 'The request is too large.');
      }
      add(Uri(query: utf8.decode(bytes, allowMalformed: true)).queryParametersAll);
    }
    return _Params(values);
  }

  // ── The calls ──────────────────────────────────────────────────────────────────────────────────

  /// The answer of [method]: a map for the call's result (without the envelope), or a [Response] for the audio and the
  /// pictures.
  Future<Object> _call(String method, _Params params, Principal who, Request request) async {
    switch (method) {
      case 'ping':
        return <String, Object?>{};
      case 'getLicense':
        return {
          'license': {'valid': true, 'email': '', 'licenseExpires': '2099-12-31T00:00:00.000Z'},
        };
      case 'getOpenSubsonicExtensions':
        return {
          'openSubsonicExtensions': [
            {
              'name': 'apiKeyAuthentication',
              'versions': [1],
            },
            {
              'name': 'formPost',
              'versions': [1],
            },
            {
              'name': 'songLyrics',
              'versions': [1],
            },
          ],
        };
      case 'getMusicFolders':
        return {
          'musicFolders': {
            'musicFolder': [
              {'id': 1, 'name': _folderName()},
            ],
          },
        };
      case 'getUser':
        return _getUser(params, who);
      case 'getScanStatus':
        return {
          'scanStatus': {'scanning': library.isScanning, 'count': library.tracks.length},
        };
      case 'startScan':
        if (!who.isAdmin) throw const SubsonicFailure(SubsonicError.notAuthorized, 'Only an administrator can scan.');
        scanner.requestScan();
        return {
          'scanStatus': {'scanning': true, 'count': library.tracks.length},
        };

      case 'getArtists':
        return {'artists': _artistIndex()};
      case 'getIndexes':
        return {'indexes': _artistIndex()};
      case 'getArtist':
        return _getArtist(params, who);
      case 'getAlbum':
        return _getAlbum(params, who);
      case 'getSong':
        return {'song': _song(_track(params), _context(who))};
      case 'getMusicDirectory':
        return _getMusicDirectory(params, who);
      case 'getAlbumList':
      case 'getAlbumList2':
        return _getAlbumList(method, params, who);
      case 'getRandomSongs':
        return _getRandomSongs(params, who);
      case 'getSongsByGenre':
        return _getSongsByGenre(params, who);
      case 'getGenres':
        return _getGenres();
      case 'search2':
      case 'search3':
        return _search(method, params, who);

      case 'getStarred':
      case 'getStarred2':
        return _getStarred(method, who);
      case 'star':
        return _star(params, who, true);
      case 'unstar':
        return _star(params, who, false);
      case 'scrobble':
        return _scrobble(params, who);

      case 'getPlaylists':
        return _getPlaylists(who);
      case 'getPlaylist':
        return _getPlaylist(params, who);
      case 'createPlaylist':
        return _createPlaylist(params, who);
      case 'updatePlaylist':
        return _updatePlaylist(params, who);
      case 'deletePlaylist':
        return _deletePlaylist(params, who);

      case 'getLyricsBySongId':
        return await _getLyricsBySongId(params);

      case 'stream':
        return sendStream(request, _track(params), _conversion(params, _track(params)));
      case 'download':
        return sendStream(request, _track(params));
      case 'getCoverArt':
        return sendPicture(request, params.required('id'));

      // Things Wiretune has none of: empty, so the apps that ask for them everywhere still work.
      case 'getNowPlaying':
        return {'nowPlaying': <String, Object?>{}};
      case 'getBookmarks':
        return {'bookmarks': <String, Object?>{}};
      case 'getInternetRadioStations':
        return {'internetRadioStations': <String, Object?>{}};
      case 'getPodcasts':
        return {'podcasts': <String, Object?>{}};
      case 'getNewestPodcasts':
        return {'newestPodcasts': <String, Object?>{}};
      case 'getShares':
        return {'shares': <String, Object?>{}};
      case 'getTopSongs':
        return {'topSongs': <String, Object?>{}};
      case 'getSimilarSongs':
        return {'similarSongs': <String, Object?>{}};
      case 'getSimilarSongs2':
        return {'similarSongs2': <String, Object?>{}};
      case 'getArtistInfo':
        return {'artistInfo': <String, Object?>{}};
      case 'getArtistInfo2':
        return {'artistInfo2': <String, Object?>{}};
      case 'getAlbumInfo':
      case 'getAlbumInfo2':
        return {'albumInfo': <String, Object?>{}};
      case 'getPlayQueue':
        return <String, Object?>{};
      default:
        throw SubsonicFailure(SubsonicError.generic, 'Wiretune does not have "$method".');
    }
  }

  /// What `stream` asks to be converted to, or null for the file itself: a `format` of `mp3` or `opus` (`raw` is the
  /// file), or a `maxBitRate` below the file's, converted to the `format`, else MP3, which every app plays.
  static TranscodeRequest? _conversion(_Params params, Track track) {
    final format = params.text('format');
    if (format == 'raw') return null;
    final limit = params.integer('maxBitRate');
    final bitrate = limit != null && limit > 0 ? '$limit' : null;
    if (TranscodeFormat.named(format) != null) return TranscodeRequest.parse(format, bitrate);
    if (bitrate != null && track.format.bitrateKbps > limit!) return TranscodeRequest.parse('mp3', bitrate);
    return null;
  }

  String _folderName() {
    final name = p.basename(musicFolder());
    return name.isEmpty ? 'Music' : name;
  }

  Track _track(_Params params) {
    final id = params.required('id');
    final track = library.getTrack(id);
    if (track == null) throw const SubsonicFailure(SubsonicError.notFound, 'Song not found.');
    return track;
  }

  Map<String, Object?> _getUser(_Params params, Principal who) {
    final name = params.text('username') ?? who.username;
    if (!equalsIgnoreCase(name, who.username) && !who.isAdmin) {
      throw const SubsonicFailure(SubsonicError.notAuthorized, 'You can only see your own account.');
    }
    final user = auth.getAllUsers().where((u) => equalsIgnoreCase(u.username, name)).firstOrNull;
    if (user == null) throw const SubsonicFailure(SubsonicError.notFound, 'User not found.');
    return {
      'user': {
        'username': user.username,
        'email': '',
        'scrobblingEnabled': true,
        'adminRole': user.isAdmin,
        'settingsRole': false,
        'downloadRole': true,
        'uploadRole': false,
        'playlistRole': true,
        'coverArtRole': false,
        'commentRole': false,
        'podcastRole': false,
        'streamRole': true,
        'jukeboxRole': false,
        'shareRole': false,
        'videoConversionRole': false,
        'folder': [1],
      },
    };
  }

  // ── Browsing ───────────────────────────────────────────────────────────────────────────────────

  Map<String, Object?> _artistIndex() {
    final artists = [...library.artists]..sort((a, b) => compareText(a.name, b.name));
    final groups = <String, List<Map<String, Object?>>>{};
    for (final artist in artists) {
      groups.putIfAbsent(_initial(artist.name), () => []).add(_artist(artist));
    }
    return {
      'ignoredArticles': '',
      'lastModified': DateTime.now().toUtc().millisecondsSinceEpoch,
      'index': [
        for (final MapEntry(:key, :value) in groups.entries) {'name': key, 'artist': value},
      ],
    };
  }

  /// The letter an artist is listed under: the first letter without its accent, capitalised, or `#`.
  static String _initial(String name) {
    final first = foldForSearch(name.trim()).split('').firstOrNull ?? '#';
    return RegExp(r'^[a-z]$').hasMatch(first) ? first.toUpperCase() : '#';
  }

  Map<String, Object?> _getArtist(_Params params, Principal who) {
    final artist = library.getArtist(params.required('id'));
    if (artist == null) throw const SubsonicFailure(SubsonicError.notFound, 'Artist not found.');
    final context = _context(who);
    return {
      'artist': {
        ..._artist(artist),
        'album': [for (final album in artist.albums) _album(album, context)],
      },
    };
  }

  Map<String, Object?> _getAlbum(_Params params, Principal who) {
    final album = library.getAlbum(params.required('id'));
    if (album == null) throw const SubsonicFailure(SubsonicError.notFound, 'Album not found.');
    final context = _context(who);
    return {
      'album': {
        ..._album(album, context),
        'song': [for (final track in _inAlbumOrder(album)) _song(track, context)],
      },
    };
  }

  /// The old, folder-shaped way of browsing: an artist holds its albums, an album its songs.
  Map<String, Object?> _getMusicDirectory(_Params params, Principal who) {
    final id = params.required('id');
    final context = _context(who);
    final album = library.getAlbum(id);
    if (album != null) {
      return {
        'directory': {
          'id': album.id,
          'name': album.title,
          'parent': artistIdOf(album.artistNames.first),
          'child': [for (final track in _inAlbumOrder(album)) _song(track, context)],
        },
      };
    }
    final artist = library.getArtist(id);
    if (artist == null) throw const SubsonicFailure(SubsonicError.notFound, 'Directory not found.');
    return {
      'directory': {
        'id': artist.id,
        'name': artist.name,
        'child': [
          for (final album in artist.albums)
            {
              'id': album.id,
              'parent': artist.id,
              'isDir': true,
              'title': album.title,
              'album': album.title,
              'artist': album.artist,
              'year': album.releaseYear,
              'coverArt': _hasCover(album) ? album.id : null,
            },
        ],
      },
    };
  }

  Map<String, Object?> _getAlbumList(String method, _Params params, Principal who) {
    final type = params.required('type');
    final context = _context(who);
    var albums = [...library.albums];
    final random = Random();

    DateTime added(Album a) => a.tracks.map((t) => t.addedAt).reduce((x, y) => x.isAfter(y) ? x : y);
    int plays(Album a) => a.tracks.fold(0, (sum, t) => sum + (context.plays[t.id]?.playCount ?? 0));
    DateTime? lastPlayed(Album a) => a.tracks
        .map((t) => context.plays[t.id]?.lastPlayedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (best, t) => best == null || t.isAfter(best) ? t : best);

    switch (type) {
      case 'random':
        albums.shuffle(random);
      case 'newest':
        albums.sort((a, b) => added(b).compareTo(added(a)));
      case 'frequent':
        albums = albums.where((a) => plays(a) > 0).toList()..sort((a, b) => plays(b).compareTo(plays(a)));
      case 'recent':
        albums = albums.where((a) => lastPlayed(a) != null).toList()
          ..sort((a, b) => lastPlayed(b)!.compareTo(lastPlayed(a)!));
      case 'starred':
        albums = albums.where((a) => a.tracks.any((t) => context.favorites.contains(t.id))).toList()
          ..sort((a, b) => compareText(a.title, b.title));
      case 'highest':
        albums = []; // Wiretune has no ratings
      case 'alphabeticalByName':
        albums.sort((a, b) => compareText(a.title, b.title));
      case 'alphabeticalByArtist':
        albums.sort((a, b) {
          final byArtist = compareText(a.artist, b.artist);
          return byArtist != 0 ? byArtist : compareText(a.title, b.title);
        });
      case 'byYear':
        final from = params.integer('fromYear') ?? 0;
        final to = params.integer('toYear') ?? 9999;
        final low = min(from, to);
        final high = max(from, to);
        albums = albums.where((a) => a.releaseYear != null && a.releaseYear! >= low && a.releaseYear! <= high).toList()
          ..sort(
            (a, b) => from <= to ? a.releaseYear!.compareTo(b.releaseYear!) : b.releaseYear!.compareTo(a.releaseYear!),
          );
      case 'byGenre':
        final genre = params.required('genre');
        albums = albums.where((a) => a.tracks.any((t) => equalsIgnoreCase(t.genre, genre))).toList()
          ..sort((a, b) => compareText(a.title, b.title));
      default:
        throw SubsonicFailure(SubsonicError.generic, 'Unknown list type: $type.');
    }
    final page = _page(albums, params.integer('size') ?? 10, params.integer('offset') ?? 0);
    final key = method == 'getAlbumList' ? 'albumList' : 'albumList2';
    return {
      key: {
        'album': [for (final album in page) _album(album, context)],
      },
    };
  }

  Map<String, Object?> _getRandomSongs(_Params params, Principal who) {
    final genre = params.text('genre');
    final from = params.integer('fromYear');
    final to = params.integer('toYear');
    final songs = library.tracks.where((t) {
      if (genre != null && !equalsIgnoreCase(t.genre, genre)) return false;
      final year = t.releaseYear;
      if (from != null && (year == null || year < from)) return false;
      if (to != null && (year == null || year > to)) return false;
      return true;
    }).toList()..shuffle(Random());
    final context = _context(who);
    return {
      'randomSongs': {
        'song': [for (final track in _page(songs, params.integer('size') ?? 10, 0)) _song(track, context)],
      },
    };
  }

  Map<String, Object?> _getSongsByGenre(_Params params, Principal who) {
    final genre = params.required('genre');
    final songs = library.tracks.where((t) => equalsIgnoreCase(t.genre, genre)).toList();
    final context = _context(who);
    return {
      'songsByGenre': {
        'song': [
          for (final track in _page(songs, params.integer('count') ?? 10, params.integer('offset') ?? 0))
            _song(track, context),
        ],
      },
    };
  }

  Map<String, Object?> _getGenres() {
    final songs = <String, int>{};
    final albums = <String, Set<String>>{};
    final names = <String, String>{};
    for (final track in library.tracks) {
      final genre = track.genre?.trim();
      if (genre == null || genre.isEmpty) continue;
      final key = genre.toLowerCase();
      names.putIfAbsent(key, () => genre);
      songs[key] = (songs[key] ?? 0) + 1;
      albums.putIfAbsent(key, () => {}).add(track.albumId);
    }
    final keys = songs.keys.toList()..sort((a, b) => compareText(names[a]!, names[b]!));
    return {
      'genres': {
        'genre': [
          for (final key in keys) {'value': names[key], 'songCount': songs[key], 'albumCount': albums[key]!.length},
        ],
      },
    };
  }

  Map<String, Object?> _search(String method, _Params params, Principal who) {
    // An empty query (or "") asks for everything, which is how some apps copy the whole library page by page.
    final words = foldForSearch(
      (params.text('query') ?? '').replaceAll('"', ''),
    ).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    bool matches(Iterable<String?> fields) {
      final text = foldForSearch(fields.whereType<String>().join(' '));
      return words.every(text.contains);
    }

    final context = _context(who);
    final artists = library.artists.where((a) => matches([a.name])).toList()
      ..sort((a, b) => compareText(a.name, b.name));
    final albums = library.albums.where((a) => matches([a.title, ...a.artistNames])).toList()
      ..sort((a, b) => compareText(a.title, b.title));
    final songs = library.tracks.where((t) => matches([t.title, t.artist, t.album])).toList()
      ..sort((a, b) => compareText(a.title, b.title));
    final key = method == 'search2' ? 'searchResult2' : 'searchResult3';
    return {
      key: {
        'artist': [
          for (final a in _page(artists, params.integer('artistCount') ?? 20, params.integer('artistOffset') ?? 0))
            _artist(a),
        ],
        'album': [
          for (final a in _page(albums, params.integer('albumCount') ?? 20, params.integer('albumOffset') ?? 0))
            _album(a, context),
        ],
        'song': [
          for (final t in _page(songs, params.integer('songCount') ?? 20, params.integer('songOffset') ?? 0))
            _song(t, context),
        ],
      },
    };
  }

  // ── Favourites and plays ───────────────────────────────────────────────────────────────────────

  Map<String, Object?> _getStarred(String method, Principal who) {
    final context = _context(who);
    final songs = [for (final id in context.data.favorites) ?library.getTrack(id)];
    return {
      method == 'getStarred' ? 'starred' : 'starred2': {
        'artist': <Object?>[],
        'album': <Object?>[],
        'song': [for (final track in songs) _song(track, context)],
      },
    };
  }

  Map<String, Object?> _star(_Params params, Principal who, bool starred) {
    if (params.all('albumId').isNotEmpty || params.all('artistId').isNotEmpty) {
      throw const SubsonicFailure(SubsonicError.generic, 'Wiretune stars songs only, not albums or artists.');
    }
    final ids = params.all('id');
    if (ids.isEmpty) throw const SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: id.');
    for (final id in ids) {
      if (library.getTrack(id) == null && (library.getAlbum(id) != null || library.getArtist(id) != null)) {
        throw const SubsonicFailure(SubsonicError.generic, 'Wiretune stars songs only, not albums or artists.');
      }
    }
    for (final id in ids) {
      if (!userData.setFavorite(who.userId, id, starred)) {
        throw const SubsonicFailure(SubsonicError.generic, 'The account has the most favorites it can have.');
      }
    }
    dataChanged(who.userId);
    return {};
  }

  Map<String, Object?> _scrobble(_Params params, Principal who) {
    final ids = params.all('id');
    if (ids.isEmpty) throw const SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: id.');
    // "Now playing" (submission=false) is not a play.
    if (params.text('submission') != 'false') {
      // `time` is when it was played, in milliseconds since 1970, one for each id.
      final times = params.all('time');
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        if (library.getTrack(id) == null || userData.recordPlay(who.userId, id) == null) continue;
        final millis = i < times.length ? int.tryParse(times[i]) : null;
        final at = millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
        // An app's clock may be anywhere: only a time that was not too long ago, and is not in the future, counts.
        final plausible = at != null && at.isBefore(DateTime.now().toUtc().add(const Duration(minutes: 5)));
        played(who.userId, id, plausible ? at : null);
      }
    }
    return {};
  }

  // ── Playlists ──────────────────────────────────────────────────────────────────────────────────

  Map<String, Object?> _getPlaylists(Principal who) => {
    'playlists': {
      'playlist': [for (final playlist in userData.get(who.userId).playlists) _playlist(playlist, who)],
    },
  };

  Map<String, Object?> _getPlaylist(_Params params, Principal who) {
    final playlist = _ownPlaylist(params.required('id'), who);
    return {'playlist': _playlistWithSongs(playlist, who)};
  }

  PlaylistData _ownPlaylist(String id, Principal who) {
    final playlist = userData.get(who.userId).playlists.where((p) => p.id == id).firstOrNull;
    if (playlist == null) throw const SubsonicFailure(SubsonicError.notFound, 'Playlist not found.');
    return playlist;
  }

  Map<String, Object?> _createPlaylist(_Params params, Principal who) {
    final existing = params.text('playlistId');
    final songs = params.all('songId');
    final String id;
    final String name;
    String? description;
    if (existing != null) {
      final playlist = _ownPlaylist(existing, who);
      id = playlist.id;
      name = params.text('name') ?? playlist.name;
      description = playlist.description;
    } else {
      final given = params.text('name');
      if (given == null) {
        throw const SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: name.');
      }
      id = newId();
      name = given;
    }
    final saved = _savePlaylist(who, id, PlaylistUpdate(name, description, songs));
    return {'playlist': _playlistWithSongs(saved, who)};
  }

  Map<String, Object?> _updatePlaylist(_Params params, Principal who) {
    final playlist = _ownPlaylist(params.required('playlistId'), who);
    final ids = [...playlist.trackIds];
    // Positions refer to the playlist as it was; remove from the end so the others keep theirs.
    final remove = params.all('songIndexToRemove').map(int.tryParse).whereType<int>().toSet().toList()..sort();
    for (final index in remove.reversed) {
      if (index >= 0 && index < ids.length) ids.removeAt(index);
    }
    ids.addAll(params.all('songIdToAdd'));
    _savePlaylist(
      who,
      playlist.id,
      PlaylistUpdate(params.text('name') ?? playlist.name, params.text('comment') ?? playlist.description, ids),
    );
    return {};
  }

  Map<String, Object?> _deletePlaylist(_Params params, Principal who) {
    final playlist = _ownPlaylist(params.required('id'), who);
    userData.deletePlaylist(who.userId, playlist.id);
    dataChanged(who.userId);
    return {};
  }

  PlaylistData _savePlaylist(Principal who, String id, PlaylistUpdate update) {
    final violation = UserDataService.validatePlaylist(id, update);
    if (violation != null) throw SubsonicFailure(SubsonicError.generic, violation.message);
    final saved = userData.savePlaylist(who.userId, id, update);
    if (saved == null) throw const SubsonicFailure(SubsonicError.generic, 'The account has the most playlists it can.');
    dataChanged(who.userId);
    return saved;
  }

  Future<Map<String, Object?>> _getLyricsBySongId(_Params params) async {
    final track = _track(params);
    final text = await readLyrics(track);
    final timed = LrcParser.parse(text);
    return {
      'lyricsList': {
        'structuredLyrics': [
          if (text != null && text.trim().isNotEmpty)
            {
              'displayArtist': track.artist,
              'displayTitle': track.title,
              'lang': 'xxx',
              'synced': timed.isNotEmpty,
              'line': timed.isNotEmpty
                  ? [
                      for (final line in timed) {'start': line.time.inMilliseconds, 'value': line.text},
                    ]
                  : [
                      for (final line in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'))
                        {'value': line},
                    ],
            },
        ],
      },
    };
  }

  // ── Shapes ─────────────────────────────────────────────────────────────────────────────────────

  _Context _context(Principal who) => _Context(userData.get(who.userId));

  Map<String, Object?> _artist(Artist artist) => {
    'id': artist.id,
    'name': artist.name,
    'albumCount': artist.albumCount,
    if (library.artistPictureFiles.containsKey(artist.id)) 'coverArt': artist.id,
  };

  static bool _hasCover(Album album) => album.tracks.any((t) => t.hasCoverArt);

  Map<String, Object?> _album(Album album, _Context context) {
    final genres = <String, int>{};
    for (final track in album.tracks) {
      final genre = track.genre?.trim();
      if (genre != null && genre.isNotEmpty) genres[genre] = (genres[genre] ?? 0) + 1;
    }
    final genre = genres.isEmpty
        ? null
        : (genres.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final names = album.artistNames;
    return {
      'id': album.id,
      'name': album.title,
      'title': album.title,
      'artist': album.artist,
      'artistId': artistIdOf(names.first),
      'coverArt': _hasCover(album) ? album.id : null,
      'songCount': album.trackCount,
      'duration': album.totalDuration.inSeconds,
      'year': album.releaseYear,
      'genre': genre,
      'created': _iso(album.tracks.map((t) => t.addedAt).reduce((a, b) => a.isBefore(b) ? a : b)),
      'playCount': album.tracks.fold<int>(0, (sum, t) => sum + (context.plays[t.id]?.playCount ?? 0)),
      'isDir': true,
      'artists': [
        for (final name in names) {'id': artistIdOf(name), 'name': name},
      ],
      'displayArtist': album.artist,
      'sortName': album.title.toLowerCase(),
    };
  }

  Map<String, Object?> _song(Track track, _Context context) {
    final path = p.relative(track.filePath, from: musicFolder());
    final starred = context.favoritedAt[track.id];
    final stats = context.plays[track.id];
    final artists = track.artistNames;
    final albumArtists = track.albumArtistNames;
    return {
      'id': track.id,
      'parent': track.albumId,
      'isDir': false,
      'title': track.title,
      'album': track.album,
      'artist': track.artist,
      'track': track.trackNumber,
      'year': track.releaseYear,
      'genre': track.genre,
      'coverArt': track.hasCoverArt ? track.albumId : null,
      'size': track.fileSizeBytes,
      'contentType': AudioFileTypes.mimeType(track.filePath),
      'suffix': p.extension(track.filePath).replaceFirst('.', '').toLowerCase(),
      'duration': (track.duration.inMilliseconds / 1000).round(),
      'bitRate': track.format.bitrateKbps,
      'bitDepth': track.format.bitsPerSample,
      'samplingRate': track.format.sampleRate,
      'channelCount': track.format.channels,
      'path': p.posix.joinAll(p.split(path)),
      'playCount': stats?.playCount ?? 0,
      if (stats?.lastPlayedAt != null) 'played': _iso(stats!.lastPlayedAt!),
      'discNumber': track.discNumber,
      'created': _iso(track.addedAt),
      if (context.favorites.contains(track.id)) 'starred': _iso(starred ?? track.addedAt),
      'albumId': track.albumId,
      'artistId': artistIdOf(track.primaryArtist),
      'type': 'music',
      'mediaType': 'song',
      'isVideo': false,
      'bpm': track.bpm,
      'artists': [
        for (final name in artists) {'id': artistIdOf(name), 'name': name},
      ],
      'albumArtists': [
        for (final name in albumArtists) {'id': artistIdOf(name), 'name': name},
      ],
      'displayArtist': track.artist,
      'displayAlbumArtist': albumArtists.join(', '),
      if (track.genre != null && track.genre!.trim().isNotEmpty)
        'genres': [
          {'name': track.genre},
        ],
    };
  }

  Map<String, Object?> _playlist(PlaylistData playlist, Principal who) {
    final songs = [for (final id in playlist.trackIds) ?library.getTrack(id)];
    return {
      'id': playlist.id,
      'name': playlist.name,
      'comment': playlist.description,
      'owner': who.username,
      'public': false,
      'songCount': songs.length,
      'duration': songs.fold<int>(0, (sum, t) => sum + t.duration.inSeconds),
      'created': _iso(playlist.createdAt),
      'changed': _iso(playlist.modifiedAt),
      'coverArt': songs.where((t) => t.hasCoverArt).firstOrNull?.albumId,
    };
  }

  Map<String, Object?> _playlistWithSongs(PlaylistData playlist, Principal who) {
    final context = _context(who);
    return {
      ..._playlist(playlist, who),
      'entry': [
        for (final id in playlist.trackIds)
          if (library.getTrack(id) case final track?) _song(track, context),
      ],
    };
  }

  /// An album's tracks in the order of the disc and the track number.
  static List<Track> _inAlbumOrder(Album album) => [...album.tracks]
    ..sort((a, b) {
      final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
      if (disc != 0) return disc;
      final number = (a.trackNumber ?? 1 << 30).compareTo(b.trackNumber ?? 1 << 30);
      return number != 0 ? number : compareText(a.title, b.title);
    });

  static List<T> _page<T>(List<T> items, int size, int offset) {
    final start = offset.clamp(0, items.length);
    final end = (start + size.clamp(0, _maxPage)).clamp(start, items.length);
    return items.sublist(start, end);
  }

  static String _iso(DateTime time) => formatIsoUtc(time);
}

/// The account's data of one request: the favourites and the plays, which the songs show.
class _Context {
  _Context(this.data)
    : favorites = data.favorites.toSet(),
      favoritedAt = data.favoritedAt,
      plays = {for (final stats in data.plays) stats.trackId: stats};

  final UserDataSnapshot data;
  final Set<String> favorites;
  final Map<String, DateTime> favoritedAt;
  final Map<String, TrackPlayStats> plays;
}

/// The parameters of a call, from the address and from a posted form; one name may come more than once.
class _Params {
  _Params(this._values);

  final Map<String, List<String>> _values;

  String? text(String name) {
    final value = _values[name]?.firstOrNull;
    return value == null || value.isEmpty ? null : value;
  }

  String required(String name) =>
      text(name) ?? (throw SubsonicFailure(SubsonicError.missingParameter, 'Required parameter is missing: $name.'));

  int? integer(String name) => int.tryParse(text(name) ?? '');

  List<String> all(String name) => [
    for (final value in _values[name] ?? const <String>[])
      if (value.isNotEmpty) value,
  ];
}
