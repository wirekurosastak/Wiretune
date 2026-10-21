// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../about.dart';
import '../models/library_models.dart';
import '../util/event.dart';
import 'app_paths.dart';
import 'wiretune_log.dart';

/// Fetches artist pictures from the internet (Deezer's public search) and caches the answers on disk and in memory.
/// An artist is found through one of their albums when they have one (several acts share a name: Deezer knows four
/// "Aza"s), else by their exact name. Artist names and album titles are sent to api.deezer.com; set
/// `WIRETUNE_NO_ARTIST_PICTURES=1` to keep the library offline.
class ArtistPictureService {
  /// [client] sends the requests (null creates one); [cacheFile] keeps the answers (null keeps them in memory only).
  ArtistPictureService({http.Client? client, String? cacheFile, this.spacing = const Duration(milliseconds: 110)})
    : _http = client ?? http.Client(),
      _ownsClient = client == null,
      _cacheFile = cacheFile;

  /// The production service: the answers kept in the Wiretune data directory.
  factory ArtistPictureService.createDefault() =>
      ArtistPictureService(cacheFile: p.join(AppPaths.getDataDirectory(), 'artist_pictures.json'));

  static const String disableEnvironmentVariable = 'WIRETUNE_NO_ARTIST_PICTURES';

  /// After a network or server failure no further requests are made for this long (and nothing is cached).
  static const Duration _failureBackoff = Duration(minutes: 5);
  static const Duration _saveDelay = Duration(seconds: 2);

  /// The cache's format; a cache of another (an earlier lookup's, which took the first artist of the name, or the best
  /// known one for an album's second act) is dropped.
  static const int _cacheVersion = 3;

  /// How many of an artist's albums are tried before their name alone.
  static const int _albumsTried = 2;

  /// The least time between two requests: Deezer allows 50 in 5 seconds.
  final Duration spacing;

  final http.Client _http;
  final bool _ownsClient;
  final String? _cacheFile;
  final Map<String, String> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Queue<Artist> _queue = Queue();
  bool _isLoaded = false;
  bool _working = false;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Future<void> _lastRequest = Future.value();
  Timer? _saveTimer;

  /// Raised (with the artist) when a picture was found and set.
  final Event<Artist> pictureResolved = Event<Artist>();

  static bool get _isDisabled {
    final value = Platform.environment[disableEnvironmentVariable];
    return value != null && value.isNotEmpty && value != '0';
  }

  bool get _mayAsk => !_isDisabled && !DateTime.now().toUtc().isBefore(_retryAfter);

  static String _key(String name) => name.trim().toLowerCase();

  /// The cached or fetched picture URL of the artist, found through [albums] (titles of theirs) when it can be; null if
  /// there is none or on error.
  Future<String?> getArtistPictureUrl(String? artistName, {Iterable<String> albums = const []}) async {
    if (artistName == null || artistName.trim().isEmpty || Track.isUnknownArtist(artistName)) return null;
    _loadCache();

    final key = _key(artistName);
    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    if (!_mayAsk) return null;

    // Callers asking for the same artist at once share one lookup.
    return _inFlight[key] ??= _fetch(artistName.trim(), key, albums.take(_albumsTried).toList());
  }

  /// Resolves the picture of [artist] at once (its page is open) and sets [Artist.picturePath] when one is found.
  void resolveArtistPicture(Artist? artist) {
    _loadCache();
    if (artist != null && _wanted(artist)) unawaited(_resolve(artist));
  }

  /// Resolves the pictures of [artists] in the background, one lookup at a time.
  void resolveArtistPictures(Iterable<Artist> artists) {
    _loadCache();
    _queue.addAll(artists.where(_wanted));
    if (!_working) unawaited(_work());
  }

  /// An artist with a name that doesn't show the picture found here yet: an album cover meanwhile, which may be an
  /// address too (the server's covers are), so only the cache can tell. One known to have none is left as it is.
  bool _wanted(Artist artist) {
    if (artist.name.trim().isEmpty) return false;
    final known = _cache[_key(artist.name)];
    return known == null || (known.isNotEmpty && artist.picturePath != known);
  }

  Future<void> _work() async {
    _working = true;
    try {
      while (_queue.isNotEmpty) {
        final artist = _queue.removeFirst();
        if (!_cache.containsKey(_key(artist.name)) && !_mayAsk) {
          _queue.clear(); // switched off or backing off: the next batch tries again
          break;
        }
        await _resolve(artist);
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _resolve(Artist artist) async {
    try {
      final albums = {for (final album in artist.albums) album.title};
      final url = await getArtistPictureUrl(artist.name, albums: albums);
      if (url != null && url.isNotEmpty && artist.picturePath != url) {
        artist.picturePath = url;
        pictureResolved.emit(artist);
      }
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', "Error resolving picture for '${artist.name}': $e");
    }
  }

  Future<String?> _fetch(String artistName, String key, List<String> albums) async {
    try {
      String? pictureUrl;
      // Through an album of theirs: its artist is them, whoever else has the name.
      for (final album in albums) {
        final found = await _search('album', 'artist:"${_quoted(artistName)}" album:"${_quoted(album)}"', 5);
        var artist = found
            .map((a) => a['artist'])
            .whereType<Map<Object?, Object?>>()
            .where((a) => _sameName(a['name'], artistName))
            .firstOrNull;
        // An album's second act is among its contributors, while its artist is the first.
        final id = found.where((a) => _sameName(a['title'], album)).map((a) => a['id']).whereType<num>().firstOrNull;
        if (artist == null && id != null) {
          final contributors = (await _get('/album/${id.toInt()}'))['contributors'];
          artist = (contributors is List ? contributors : const [])
              .whereType<Map<Object?, Object?>>()
              .where((c) => _sameName(c['name'], artistName))
              .firstOrNull;
        }
        if (artist != null) {
          pictureUrl = _pictureOf(artist);
          break;
        }
      }
      // Else by the name alone: the best known of the artists who have exactly it.
      if (pictureUrl == null) {
        final named = (await _search('artist', artistName, 10)).where((a) => _sameName(a['name'], artistName)).toList()
          ..sort((a, b) => _fans(b).compareTo(_fans(a)));
        pictureUrl = named.map(_pictureOf).nonNulls.firstOrNull;
      }

      // A definitive answer, including "no picture" (empty string), is cached so it is never asked again.
      _cache[key] = pictureUrl ?? '';
      _saveTimer?.cancel();
      _saveTimer = Timer(_saveDelay, _saveCache);
      return pictureUrl;
    } catch (e) {
      // An outage, a refusal or too many requests say nothing about the artist: remember nothing, back off instead.
      _backOff('$e');
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// The results of Deezer's search for [kind] (`artist` or `album`).
  Future<List<Map<Object?, Object?>>> _search(String kind, String query, int limit) async {
    final data = (await _get('/search/$kind', {'q': query, 'limit': '$limit'}))['data'];
    if (data is! List) throw const FormatException('Deezer answered without results');
    return data.whereType<Map<Object?, Object?>>().toList();
  }

  /// Deezer's answer at [path], one request at a time and [spacing] apart; throws when it is an error (Deezer reports
  /// some, such as too many requests, in a body sent with 200 OK).
  Future<Map<Object?, Object?>> _get(String path, [Map<String, String>? query]) async {
    final previous = _lastRequest;
    final turn = Completer<void>();
    _lastRequest = turn.future;
    await previous;
    try {
      final uri = Uri.https('api.deezer.com', path, query);
      final response = await _http
          .get(uri, headers: {'User-Agent': WiretuneInfo.userAgent})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw HttpException('Deezer answered HTTP ${response.statusCode}');
      }
      final document = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (document is! Map<Object?, Object?> || document['error'] != null) {
        throw FormatException('Deezer answered with an error: ${document is Map ? document['error'] : document}');
      }
      return document;
    } finally {
      unawaited(Future<void>.delayed(spacing).then((_) => turn.complete()));
    }
  }

  static String _quoted(String text) => text.replaceAll('"', ' ');

  static bool _sameName(Object? name, String wanted) => name is String && _key(name) == _key(wanted);

  static int _fans(Map<Object?, Object?> artist) => (artist['nb_fan'] as num?)?.toInt() ?? 0;

  /// An artist's https picture; null for none, or Deezer's grey stand-in for one (its address names no image).
  static String? _pictureOf(Map<Object?, Object?> artist) {
    for (final field in const ['picture_medium', 'picture_big', 'picture']) {
      final value = artist[field];
      final uri = value is String ? Uri.tryParse(value) : null;
      if (uri != null && uri.isAbsolute && uri.scheme == 'https') {
        return uri.path.contains('/artist//') ? null : uri.toString();
      }
    }
    return null;
  }

  void _backOff(String reason) {
    _retryAfter = DateTime.now().toUtc().add(_failureBackoff);
    WiretuneLog.warn(
      'ArtistPicture',
      'Artist picture lookup failed ($reason); pausing lookups for ${_failureBackoff.inMinutes} minutes.',
    );
  }

  void _loadCache() {
    final file = _cacheFile;
    if (_isLoaded || file == null) return;
    _isLoaded = true;
    try {
      if (!File(file).existsSync()) return;
      final decoded = jsonDecode(File(file).readAsStringSync());
      final artists = decoded is Map && decoded['version'] == _cacheVersion ? decoded['artists'] : null;
      if (artists is Map) {
        artists.forEach((name, url) {
          if (name is String && url is String) _cache[_key(name)] = url;
        });
      }
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', 'Failed to load artist cache: $e');
    }
  }

  void _saveCache() {
    _saveTimer?.cancel();
    final file = _cacheFile;
    if (file == null) return;
    try {
      final temp = '$file.tmp';
      File(
        temp,
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'version': _cacheVersion, 'artists': _cache}));
      File(temp).renameSync(file); // never leave a half-written cache behind
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', 'Failed to save artist cache: $e');
    }
  }

  /// Saves what is still to be saved, and lets go of the connection.
  void close() {
    if (_saveTimer?.isActive ?? false) _saveCache();
    _queue.clear();
    if (_ownsClient) _http.close();
  }
}
