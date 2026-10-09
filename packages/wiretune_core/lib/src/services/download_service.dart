// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../util/event.dart';
import 'app_paths.dart';
import 'library_service.dart';
import 'server_session.dart';
import 'wiretune_log.dart';

/// Where a track stands with the downloads.
enum DownloadState {
  /// Not wanted on this device, or a local file, which needs no download.
  none,

  /// Wanted, and waiting for its turn or for the server.
  queued,

  /// Being downloaded now.
  downloading,

  /// On this device and up to date.
  done,
}

/// Copies of server tracks kept on this device, so that they play without the server: a track, an album, an artist's
/// albums, a playlist or the favourites at a time. What the user marked is kept in the settings; the copies follow it whenever the library
/// changes (a playlist that grows gets the new track), are downloaded again when the server's file changes, and are
/// deleted as soon as nothing wants them any more. One file is downloaded at a time, and only while signed in.
///
/// A copy is named after hashes of the track's ID and of the server's size and modification time of the file, so no ID
/// a server sends ends up in a path, and a copy that no longer matches the server's file is recognised by its name.
class DownloadService {
  DownloadService(this._library, this._session, {String? directory, http.Client? client})
    : _directory = directory,
      _client = client,
      _ownsClient = client == null;

  static const String _pinsPreference = 'downloads';

  /// How long a download may go without receiving anything before it counts as failed.
  static const Duration _idleTimeout = Duration(seconds: 30);
  static const Duration _firstRetry = Duration(seconds: 15);
  static const Duration _lastRetry = Duration(minutes: 10);

  static final RegExp _copyName = RegExp(r'^([0-9a-f]{16})-([0-9a-f]{8})(?:-[^.]+)?\.([a-z0-9]{1,8})$');
  static final RegExp _coverName = RegExp(r'^([0-9a-f]{16})\.([a-z0-9]{1,8})$');

  final LibraryService _library;
  final ServerSession _session;
  http.Client? _client;
  final bool _ownsClient;
  final List<void Function()> _unsubscribers = [];
  String? _directory;
  bool _initialized = false;
  bool _disposed = false;

  _Pins _pins = _Pins();

  // What the pins want right now, in download order: the copy's stem -> the track.
  Map<String, Track> _wanted = const {};
  Set<String> _wantedCovers = const {};

  // The files on disk: stem -> version -> path, and cover stem -> path.
  final Map<String, Map<String, String>> _copies = {};
  final Map<String, String> _covers = {};
  int _bytesOnDisk = 0;

  // Tracks the server no longer has (404): skipped until the library is refreshed.
  final Set<String> _unavailable = {};

  bool _running = false;
  bool _runAgain = false;
  Timer? _retryTimer;
  Duration _retryDelay = _firstRetry;
  bool _stopped = false; // the server refused the token: wait for the session to change
  _Job? _current;
  bool _cancelCurrent = false;
  int _currentReceived = 0;
  int _currentTotal = 0;
  final Stopwatch _sinceProgress = Stopwatch();
  String? _errorKey;
  List<Object?> _errorArgs = const [];

  /// Raised when the pins, the copies, the progress or the error change.
  final Event<void> changed = Event<void>();

  static String defaultDownloadDirectory() {
    if (AppPaths.platformDataRoot != null) {
      return p.join(AppPaths.getDataDirectory(), 'Downloads');
    }
    final legacy = p.join(AppPaths.getDataDirectory(), 'Downloads');
    final legacyDir = Directory(legacy);
    if (legacyDir.existsSync()) {
      try {
        final entries = legacyDir.listSync();
        if (entries.isNotEmpty) {
          return legacy;
        }
      } catch (_) {}
    }
    return p.join(AppPaths.musicFolder(), 'Wiretune');
  }

  String get directory => _directory ??= defaultDownloadDirectory();
  String get _coverDirectory => p.join(directory, 'covers');


  // ── What the user marked ───────────────────────────────────────────────────────────────────────

  bool isTrackPinned(String trackId) => _pins.tracks.contains(trackId);
  bool isAlbumPinned(String albumId) => _pins.albums.contains(albumId);
  bool isArtistPinned(String artistId) => _pins.artists.contains(artistId);
  bool isPlaylistPinned(String playlistId) => _pins.playlists.contains(playlistId);
  bool get areFavoritesPinned => _pins.favorites;

  Future<void> pinTrack(String trackId, bool pinned) => _changePins((pins) => _toggle(pins.tracks, trackId, pinned));

  Future<void> pinAlbum(String albumId, bool pinned) => _changePins((pins) => _toggle(pins.albums, albumId, pinned));

  /// Every album filed under the artist, also the ones that arrive later.
  Future<void> pinArtist(String artistId, bool pinned) =>
      _changePins((pins) => _toggle(pins.artists, artistId, pinned));

  Future<void> pinPlaylist(String playlistId, bool pinned) =>
      _changePins((pins) => _toggle(pins.playlists, playlistId, pinned));

  Future<void> pinFavorites(bool pinned) => _changePins((pins) => pins.favorites = pinned);

  /// Forgets every mark and deletes every copy (also what a sign-out does).
  Future<void> removeAll() => _changePins((pins) {
    pins.tracks.clear();
    pins.albums.clear();
    pins.artists.clear();
    pins.playlists.clear();
    pins.favorites = false;
  });

  static void _toggle(Set<String> set, String id, bool pinned) => pinned ? set.add(id) : set.remove(id);

  Future<void> _changePins(void Function(_Pins pins) change) async {
    change(_pins);
    await _library.setPreference(_pinsPreference, jsonEncode(_pins.toJson()));
    _refreshWanted();
    changed.emit(null);
    _schedule();
  }

  // ── What is on this device ─────────────────────────────────────────────────────────────────────

  /// A server track, which can be downloaded; a local file needs no copy.
  static bool canDownload(Track track) => !track.isLocal;

  bool isWanted(Track track) => _wanted.containsKey(_stemOf(track));

  /// The path of a copy of [track] that can be played (possibly of an older version of the server's file), or null.
  String? localCopy(Track track) {
    if (track.isLocal) return null;
    final versions = _copies[_stemOf(track)];
    if (versions == null || versions.isEmpty) return null;
    final path = versions[_version(track)] ?? versions.values.first;
    return File(path).existsSync() ? path : null;
  }

  /// The downloaded copy of a cover the server serves at [url], or null.
  String? localCover(String url) => _covers[_coverStem(url)];

  DownloadState stateOf(Track track) {
    if (track.isLocal) return DownloadState.none;
    final stem = _stemOf(track);
    if (!_wanted.containsKey(stem)) return DownloadState.none;
    if (_copies[stem]?.containsKey(_version(track)) ?? false) return DownloadState.done;
    return _current?.stem == stem ? DownloadState.downloading : DownloadState.queued;
  }

  /// How many of [tracks] that can be downloaded are on this device and up to date, and how many can be downloaded.
  (int done, int total) progressOf(Iterable<Track> tracks) {
    var done = 0, total = 0;
    for (final track in tracks) {
      if (track.isLocal) continue;
      total++;
      if (_copies[_stemOf(track)]?.containsKey(_version(track)) ?? false) done++;
    }
    return (done, total);
  }

  /// The number of tracks the marks want, and how many of them are on this device and up to date.
  int get wantedCount => _wanted.length;
  int get doneCount => progressOf(_wanted.values).$1;

  /// The space the copies take, covers included.
  int get bytesOnDisk => _bytesOnDisk;

  /// The track being downloaded and how far it is (0..1), or null.
  Track? get currentTrack => _current?.track;
  double get currentProgress => _currentTotal <= 0 ? 0 : (_currentReceived / _currentTotal).clamp(0.0, 1.0);

  /// Downloads are waiting because the server cannot be reached or nobody is signed in.
  bool get isWaitingForServer => doneCount < wantedCount && !_session.isLoggedIn;

  /// Why the last download failed, in the active language; null while nothing failed.
  String? get errorMessage => _errorKey == null ? null : Localizer.format(_errorKey!, _errorArgs);

  // ── Start-up ───────────────────────────────────────────────────────────────────────────────────

  /// Reads the marks and the files on disk, then keeps the copies in line with the library from now on.
  Future<void> initialize() async {
    if (_initialized) return;
    _pins = _Pins.fromJson(_decode(await _library.getPreference(_pinsPreference)));
    await _scanDirectory();
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) {
        _unavailable.clear();
        _refreshWanted();
        changed.emit(null);
        _schedule();
      }),
      _library.playlistsChanged.listen((_) => _onListChanged(_pins.playlists.isNotEmpty)),
      _library.favoriteChanged.listen((_) => _onListChanged(_pins.favorites)),
      _session.stateChanged.listen((_) {
        if (!_session.isLoggedIn) return;
        _stopped = false;
        _retryDelay = _firstRetry;
        _schedule();
      }),
    ]);
    _initialized = true;
    _refreshWanted();
    changed.emit(null);
    _schedule();
  }

  void _onListChanged(bool affectsPins) {
    if (!affectsPins) return;
    _refreshWanted();
    changed.emit(null);
    _schedule();
  }

  static Object? _decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<void> _scanDirectory() async {
    _copies.clear();
    _covers.clear();
    _bytesOnDisk = 0;
    for (final (folder, isCover) in [(directory, false), (_coverDirectory, true)]) {
      final dir = Directory(folder);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.endsWith('.part')) continue; // resumed, or removed by the next run
        final match = (isCover ? _coverName : _copyName).firstMatch(name);
        if (match == null) continue;
        if (isCover) {
          _covers[match.group(1)!] = entity.path;
        } else {
          (_copies[match.group(1)!] ??= {})[match.group(2)!] = entity.path;
        }
        _bytesOnDisk += await entity.length();
      }
    }
  }

  // ── Keeping the copies in line with the marks ──────────────────────────────────────────────────

  /// Every server track the marks cover: the albums', the artists' albums', the playlists', the favourites and the
  /// single tracks.
  void _refreshWanted() {
    final wanted = <String, Track>{};
    void add(Track? track) {
      if (track != null && !track.isLocal) wanted.putIfAbsent(_stemOf(track), () => track);
    }

    for (final albumId in _pins.albums) {
      _library.getAlbum(albumId)?.tracks.forEach(add);
    }
    for (final artistId in _pins.artists) {
      for (final album in _library.getArtist(artistId)?.albums ?? const <Album>[]) {
        album.tracks.forEach(add);
      }
    }
    for (final playlistId in _pins.playlists) {
      final playlist = _library.getPlaylist(playlistId);
      if (playlist != null) _library.getPlaylistTracks(playlist).forEach(add);
    }
    if (_pins.favorites) _library.favorites.forEach(add);
    for (final trackId in _pins.tracks) {
      add(_library.getTrack(trackId));
    }
    _wanted = wanted;
    _wantedCovers = {
      for (final track in wanted.values)
        if (_isServerUrl(track.coverArtPath)) _coverStem(track.coverArtPath!),
    };
    final current = _current;
    if (current != null &&
        !(current.isCover ? _wantedCovers.contains(current.stem) : wanted.containsKey(current.stem))) {
      _cancelCurrent = true;
    }
  }

  void _schedule() {
    if (!_initialized || _disposed) return;
    if (_running) {
      _runAgain = true;
      return;
    }
    unawaited(_run());
  }

  bool get _canDownload => _session.isLoggedIn && !_stopped && !_disposed;

  Future<void> _run() async {
    _running = true;
    try {
      do {
        _runAgain = false;
        await _prune();
        while (_canDownload) {
          final job = _nextJob();
          if (job == null) break;
          if (!await _perform(job)) break;
        }
      } while (_runAgain && !_disposed);
    } finally {
      _running = false;
      _current = null;
      if (!_disposed) changed.emit(null);
    }
  }

  /// Deletes the copies nothing wants, the copies replaced by a newer version, and the partial files of either.
  Future<void> _prune() async {
    for (final stem in _copies.keys.toList()) {
      final track = _wanted[stem];
      final versions = _copies[stem]!;
      final current = track == null ? null : _version(track);
      // An older version stays until the current one has arrived: it still plays.
      final keep = track == null ? null : (versions.containsKey(current) ? current : versions.keys.first);
      for (final version in versions.keys.toList()) {
        if (version == keep) continue;
        if (await _delete(versions[version]!)) versions.remove(version);
      }
      if (versions.isEmpty) _copies.remove(stem);
    }
    for (final stem in _covers.keys.toList()) {
      if (!_wantedCovers.contains(stem) && await _delete(_covers[stem]!)) _covers.remove(stem);
    }
    for (final (folder, isCover) in [(directory, false), (_coverDirectory, true)]) {
      final dir = Directory(folder);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is! File || !name.endsWith('.part')) continue;
        final current = _current;
        if (current != null && entity.path == current.partPath) continue;
        final stem = name.split(RegExp(r'[-.]')).first;
        final wanted = isCover ? _wantedCovers.contains(stem) : _isCurrentPart(stem, name);
        if (!wanted) await _delete(entity.path);
      }
    }
  }

  bool _isCurrentPart(String stem, String name) {
    final track = _wanted[stem];
    return track != null && name == '${_fileName(track)}.part';
  }

  /// The next file to fetch: an album's cover before its first track, then the track.
  _Job? _nextJob() {
    for (final MapEntry(key: stem, value: track) in _wanted.entries) {
      if (_unavailable.contains(stem)) continue;
      final cover = track.coverArtPath;
      if (_isServerUrl(cover)) {
        final coverStem = _coverStem(cover!);
        if (!_covers.containsKey(coverStem) && !_unavailable.contains(coverStem)) {
          return _Job(coverStem, cover, p.join(_coverDirectory, coverStem), track, isCover: true);
        }
      }
      if (!(_copies[stem]?.containsKey(_version(track)) ?? false)) {
        return _Job(stem, track.streamUrl!, p.join(directory, _fileName(track)), track);
      }
    }
    return null;
  }

  /// Fetches one file. False when downloading has to stop for now (a failure that a retry may fix, or a refusal).
  Future<bool> _perform(_Job job) async {
    _current = job;
    _cancelCurrent = false;
    _currentReceived = 0;
    _currentTotal = job.isCover ? 0 : job.track.fileSizeBytes;
    changed.emit(null);
    try {
      final path = await _fetch(job);
      _errorKey = null;
      _retryDelay = _firstRetry;
      _bytesOnDisk += File(path).lengthSync();
      if (job.isCover) {
        _covers[job.stem] = path;
      } else {
        final versions = _copies[job.stem] ??= {};
        final version = _version(job.track);
        versions[version] = path;
        // The copy of the server's earlier file has been playable until now; this one replaces it.
        for (final old in versions.keys.where((v) => v != version).toList()) {
          if (await _delete(versions[old]!)) versions.remove(old);
        }
        WiretuneLog.info('Downloads', "Downloaded '${job.track.artist} - ${job.track.title}'.");
      }
      return true;
    } on _Cancelled {
      await _delete(job.partPath);
      return true;
    } on _Gone {
      // The server no longer has it: nothing to retry until the library is refreshed.
      _unavailable.add(job.stem);
      return true;
    } on _Refused {
      _stopped = true;
      _setError('DownloadsSignInAgain');
      return false;
    } on FileSystemException catch (e) {
      WiretuneLog.warn('Downloads', 'Could not write a download: $e');
      _setError('DownloadsDiskError', [e.osError?.message ?? e.message]);
      _retryLater();
      return false;
    } catch (e) {
      WiretuneLog.warn('Downloads', "Downloading '${job.track.title}' failed: $e");
      _setError('DownloadsFailed', ['$e']);
      _retryLater();
      return false;
    } finally {
      _current = null;
    }
  }

  void _setError(String key, [List<Object?> args = const []]) {
    _errorKey = key;
    _errorArgs = args;
  }

  void _retryLater() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, _schedule);
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > _lastRetry ? _lastRetry : doubled;
  }

  /// Downloads [job] into its partial file (continuing one an earlier attempt left), then gives it its final name.
  Future<String> _fetch(_Job job) async {
    final token = _session.authToken;
    if (token == null || token.isEmpty || !_isServerUrl(job.url)) throw const _Refused();

    final part = File(job.partPath);
    await part.parent.create(recursive: true);
    var offset = await part.exists() ? await part.length() : 0;
    final request = http.Request('GET', Uri.parse(job.url))..headers['Authorization'] = 'Bearer $token';
    if (offset > 0) request.headers['Range'] = 'bytes=$offset-';

    final response = await (_client ??= http.Client()).send(request).timeout(_idleTimeout);
    final status = response.statusCode;
    if (status == 401 || status == 403) throw const _Refused();
    if (status == 404 || status == 410) throw const _Gone();
    if (status == 416) {
      await _delete(job.partPath); // the partial file is longer than the server's: start again next time
      throw const HttpException('The partial download did not match the server file.');
    }
    final resumed = status == 206 && _rangeStart(response.headers['content-range']) == offset;
    if (status != 200 && !resumed) throw HttpException('HTTP $status');
    if (!resumed) offset = 0;

    final length = response.contentLength;
    if (length != null) _currentTotal = offset + length;
    _currentReceived = offset;
    _sinceProgress
      ..reset()
      ..start();

    final file = await part.open(mode: resumed ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        if (_cancelCurrent || _disposed) throw const _Cancelled();
        await file.writeFrom(chunk);
        _currentReceived += chunk.length;
        if (_sinceProgress.elapsedMilliseconds >= 500) {
          _sinceProgress.reset();
          changed.emit(null);
        }
      }
    } finally {
      await file.close();
    }

    final size = await part.length();
    if ((length != null && size != offset + length) || (!job.isCover && !_matchesServer(job.track, size))) {
      await _delete(job.partPath);
      throw HttpException('The download ended early ($size bytes).');
    }

    final target = job.isCover ? '${job.target}.${_imageExtension(response.headers['content-type'])}' : job.target;
    final targetFile = File(target);
    if (await targetFile.exists()) {
      await _delete(target);
    }
    return (await part.rename(target)).path;
  }

  /// The server's listing gives the file's size; a copy of another size is not a whole copy of it.
  static bool _matchesServer(Track track, int size) => track.fileSizeBytes <= 0 || track.fileSizeBytes == size;

  static int? _rangeStart(String? contentRange) {
    final match = RegExp(r'^bytes (\d+)-\d+/(\d+|\*)$').firstMatch(contentRange?.trim() ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Deletes a file; false when it could not be (still open on Windows): the next run tries again.
  Future<bool> _delete(String path) async {
    final file = File(path);
    try {
      if (await file.exists()) {
        final size = path.endsWith('.part') ? 0 : await file.length();
        await file.delete();
        _bytesOnDisk -= size;
      }
      return true;
    } on FileSystemException catch (e) {
      WiretuneLog.warn('Downloads', 'Could not delete a download: $e');
      return false;
    }
  }

  /// Only the server the session is signed in to is sent the token (`http://host:52001` is not `http://host:5200`).
  bool _isServerUrl(String? url) => url != null && url.startsWith('${_session.serverUrl}/');

  // ── Names ──────────────────────────────────────────────────────────────────────────────────────

  static String _stem(String trackId) => stableId('track\u001f$trackId');

  // The names of a track's copy, worked out once per Track (the library replaces them when the server's data changes).
  static final Expando<(String stem, String version)> _names = Expando();

  static (String, String) _namesOf(Track track) => _names[track] ??= (_stem(track.id), _versionOf(track));

  static String _stemOf(Track track) => _namesOf(track).$1;

  static String _version(Track track) => _namesOf(track).$2;

  static String _coverStem(String url) => stableId('cover\u001f$url');

  /// Changes when the server's file does (its size or its modification time, to the second).
  static String _versionOf(Track track) {
    final modified = track.fileModifiedUtc?.toUtc().millisecondsSinceEpoch;
    return stableId('${track.fileSizeBytes}\u001f${modified == null ? '' : modified ~/ 1000}').substring(0, 8);
  }

  /// The filename of a downloaded track: stem+version prefix (for dedup) followed by a human-readable
  /// "Artist - Title.ext" suffix so the file is recognisable in a file manager.
  static String _fileName(Track track) {
    final safeName = _safeFileName('${track.artist} - ${track.title}');
    final ext = _extension(track.format.codec);
    return '${_stemOf(track)}-${_version(track)}-$safeName.$ext';
  }

  /// Replaces filesystem-unsafe and control characters with underscores, strips trailing dots/spaces,
  /// and trims to 160 characters so the full path stays well within every platform's limit.
  static String _safeFileName(String name) {
    var safe = name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_').trim();
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) safe = 'track';
    return safe.length > 160 ? safe.substring(0, 160).trimRight() : safe;
  }

  /// The usual extension of a codec; the decoders look at the content, the extension is for people.
  static String _extension(String codec) => switch (codec.toUpperCase()) {
    'FLAC' => 'flac',
    'WAV' => 'wav',
    'AIFF' => 'aiff',
    'WAVPACK' => 'wv',
    'APE' => 'ape',
    'DSD' => 'dsf',
    'AAC' || 'ALAC' => 'm4a',
    'MP3' => 'mp3',
    'VORBIS' => 'ogg',
    'OPUS' => 'opus',
    _ => 'audio',
  };

  static String _imageExtension(String? contentType) => switch (contentType?.split(';').first.trim().toLowerCase()) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    _ => 'img',
  };

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    _unsubscribers.clear();
    if (_ownsClient) _client?.close();
  }
}

/// What the user marked for download.
class _Pins {
  final Set<String> tracks = {};
  final Set<String> albums = {};
  final Set<String> artists = {};
  final Set<String> playlists = {};
  bool favorites = false;

  Map<String, Object?> toJson() => {
    'tracks': tracks.toList(),
    'albums': albums.toList(),
    'artists': artists.toList(),
    'playlists': playlists.toList(),
    'favorites': favorites,
  };

  static _Pins fromJson(Object? json) {
    final pins = _Pins();
    if (json is! Map) return pins;
    Iterable<String> ids(Object? list) => list is List ? list.whereType<String>() : const [];
    pins.tracks.addAll(ids(json['tracks']));
    pins.albums.addAll(ids(json['albums']));
    pins.artists.addAll(ids(json['artists']));
    pins.playlists.addAll(ids(json['playlists']));
    pins.favorites = json['favorites'] == true;
    return pins;
  }
}

/// One file to fetch: a track's audio, or an album's cover.
class _Job {
  _Job(this.stem, this.url, this.target, this.track, {this.isCover = false});

  final String stem;
  final String url;

  /// The final path; a cover's gets the extension of the image type the server answers with.
  final String target;
  final Track track;
  final bool isCover;

  String get partPath => '$target.part';
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Gone implements Exception {
  const _Gone();
}

class _Refused implements Exception {
  const _Refused();
}
