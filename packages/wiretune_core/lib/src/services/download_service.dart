// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/library_repository.dart';
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
/// albums, a playlist or the favourites at a time. What the user chose to download is kept in the settings. With sync on (the
/// default) the copies follow it whenever the library changes: a playlist that grows gets the new track, a copy deleted
/// outside Wiretune comes back. With sync off, marking something downloads what it covers then, and nothing more is
/// fetched on its own. Copies are downloaded again when the server's file changes, and deleted as soon as nothing wants
/// them any more. One file is downloaded at a time, and only while signed in.
///
/// A copy is a readable file in [directory], `Album artist/Album/01 - Title.flac`, its name made of the tags with
/// anything a file system or another device could trip on taken out, so no ID or tag a server sends can lead outside
/// the folder. The repository's `downloads` table records which file is the copy of which track and of which version
/// of the server's file, so two tracks that would get the same name get two files, a file someone else put there is
/// never taken for a copy or overwritten, and only Wiretune's own copies are ever deleted. A download is written to
/// [workDirectory] (private to the app, as are the covers) and moved into place once it is complete.
class DownloadService {
  DownloadService(this._library, this._session, {String? directory, String? workDirectory, http.Client? client})
    : _directory = directory,
      _workDirectory = workDirectory,
      _http = client ?? http.Client(),
      _ownsClient = client == null;

  static const String _choicesPreference = 'downloads';
  static const String _syncModePreference = 'download_sync_mode';

  static const Duration _firstRetry = Duration(seconds: 15);
  static const Duration _lastRetry = Duration(minutes: 10);
  static const Duration _idleTimeout = Duration(seconds: 30);

  // The names of earlier versions' copies (stem-version[-name].ext) and of covers (stem.ext).
  static final RegExp _legacyCopyName = RegExp(r'^([0-9a-f]{16})-([0-9a-f]{8})(?:-[^.]+)?\.([a-z0-9]{1,8})$');
  static final RegExp _coverName = RegExp(r'^([0-9a-f]{16})\.([a-z0-9]{1,8})$');

  final LibraryService _library;
  final ServerSession _session;
  final http.Client _http;
  final bool _ownsClient;
  final List<void Function()> _unsubscribers = [];
  String? _directory;
  String? _workDirectory;
  bool _initialized = false;
  bool _disposed = false;
  bool _syncModeEnabled = true;

  _Choices _choices = _Choices();

  // What the user's choices want right now, in download order: track ID -> the track.
  Map<String, Track> _wanted = const {};
  Set<String> _wantedCovers = const {};

  // The copies on disk, as the repository records them (track ID -> copy), and the covers (cover stem -> path).
  final Map<String, _Copy> _copies = {};
  final Map<String, String> _covers = {};
  int _bytesOnDisk = 0;

  // Tracks and covers the server no longer has (404): skipped until the library is refreshed.
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

  /// Raised when the choices, the copies, the progress or the error change.
  final Event<void> changed = Event<void>();

  /// Where the copies go unless the app says otherwise: `Wiretune` in the user's music folder on a computer (and on
  /// Android, whose music folder the app sets in [AppPaths.platformMusicFolder]); `Downloads` in the app's own data on
  /// the other devices.
  static String defaultDownloadDirectory() => AppPaths.platformMusicFolder == null && AppPaths.platformDataRoot != null
      ? p.join(AppPaths.getDataDirectory(), 'Downloads')
      : p.join(AppPaths.defaultMusicFolder(), 'Wiretune');

  /// The folder of the copies, where people find them.
  String get directory => _directory ??= defaultDownloadDirectory();

  /// The app's own folder for downloads in progress and the covers.
  String get workDirectory => _workDirectory ??= p.join(AppPaths.getDataDirectory(), 'DownloadCache');

  String get _partialDirectory => p.join(workDirectory, 'partial');
  String get _coverDirectory => p.join(workDirectory, 'covers');
  LibraryRepository get _repository => _library.repository;

  // ── What the user chose to download ───────────────────────────────────────────────────────────────────────

  bool isTrackDownloaded(String trackId) => _choices.tracks.contains(trackId);
  bool isAlbumDownloaded(String albumId) => _choices.albums.contains(albumId);
  bool isArtistDownloaded(String artistId) => _choices.artists.contains(artistId);
  bool isPlaylistDownloaded(String playlistId) => _choices.playlists.contains(playlistId);
  bool get areFavoritesDownloaded => _choices.favorites;

  void setTrackDownloaded(String trackId, bool downloaded) => _changeChoices(
    (choices) => _toggle(choices.tracks, trackId, downloaded),
    downloaded ? [?_library.getTrack(trackId)] : const [],
  );

  void setAlbumDownloaded(String albumId, bool downloaded) => _changeChoices(
    (choices) => _toggle(choices.albums, albumId, downloaded),
    downloaded ? _library.getAlbum(albumId)?.tracks ?? const [] : const [],
  );

  /// Every album filed under the artist, also the ones that arrive later.
  void setArtistDownloaded(String artistId, bool downloaded) => _changeChoices(
    (choices) => _toggle(choices.artists, artistId, downloaded),
    downloaded
        ? [for (final album in _library.getArtist(artistId)?.albums ?? const <Album>[]) ...album.tracks]
        : const [],
  );

  void setPlaylistDownloaded(String playlistId, bool downloaded) {
    final playlist = _library.getPlaylist(playlistId);
    _changeChoices(
      (choices) => _toggle(choices.playlists, playlistId, downloaded),
      downloaded && playlist != null ? _library.getPlaylistTracks(playlist) : const [],
    );
  }

  void setFavoritesDownloaded(bool downloaded) =>
      _changeChoices((choices) => choices.favorites = downloaded, downloaded ? _library.favorites : const []);

  /// Whether the copies follow the choices on their own: tracks that join a chosen list later are downloaded, and so is a
  /// copy that was deleted outside Wiretune. Off, a choice downloads what it covers when it is made, and nothing else.
  bool get isSyncModeEnabled => _syncModeEnabled;

  void setSyncModeEnabled(bool enabled) {
    if (_syncModeEnabled == enabled) return;
    _syncModeEnabled = enabled;
    // From now on only what is still to come for the present choices is fetched; with sync on, the choices decide.
    _choices.pending
      ..clear()
      ..addAll(enabled ? const [] : _covered().keys.where((id) => !_hasCurrentCopy(id)));
    _library.setPreference(_syncModePreference, enabled ? '1' : '0');
    _saveChoices();
    _refreshWanted();
    changed.emit(null);
    _schedule();
  }

  /// Forgets every choice and deletes every copy (also what a sign-out does).
  void removeAll() => _changeChoices((choices) {
    choices.tracks.clear();
    choices.albums.clear();
    choices.artists.clear();
    choices.playlists.clear();
    choices.favorites = false;
  });

  static void _toggle(Set<String> set, String id, bool downloaded) => downloaded ? set.add(id) : set.remove(id);

  /// Applies [change] to the choices; [chosen] are the tracks a new choice covers.
  void _changeChoices(void Function(_Choices choices) change, [Iterable<Track> chosen = const []]) {
    change(_choices);
    final covered = _covered();
    _choices.pending.removeWhere((id) => !covered.containsKey(id));
    // Without sync, a new choice still downloads what it covers now: that is the point of making it.
    if (!_syncModeEnabled) {
      _choices.pending.addAll([
        for (final track in chosen)
          if (!track.isLocal && !_hasCurrentCopy(track.id, track)) track.id,
      ]);
    }
    _saveChoices();
    _refreshWanted();
    changed.emit(null);
    _schedule();
  }

  void _saveChoices() => _library.setPreference(_choicesPreference, jsonEncode(_choices.toJson()));

  // ── What is on this device ─────────────────────────────────────────────────────────────────────

  /// A server track, which can be downloaded; a local file needs no copy.
  static bool canDownload(Track track) => !track.isLocal;

  bool isWanted(Track track) => _wanted.containsKey(track.id);

  /// The path of a copy of [track] that can be played (possibly of an older version of the server's file), or null.
  String? localCopy(Track track) {
    if (track.isLocal) return null;
    final copy = _copies[track.id];
    if (copy == null || copy.isMoving) return null;
    final path = _absolute(copy.path);
    return File(path).existsSync() ? path : null;
  }

  /// The downloaded copy of a cover the server serves at [url], or null.
  String? localCover(String url) => _covers[_coverStem(url)];

  DownloadState stateOf(Track track) {
    if (track.isLocal || !_wanted.containsKey(track.id)) return DownloadState.none;
    if (_hasCurrentCopy(track.id, track)) return DownloadState.done;
    return _current?.id == track.id ? DownloadState.downloading : DownloadState.queued;
  }

  /// How many of [tracks] that can be downloaded are on this device and up to date, and how many can be downloaded.
  (int done, int total) progressOf(Iterable<Track> tracks) {
    var done = 0, total = 0;
    for (final track in tracks) {
      if (track.isLocal) continue;
      total++;
      if (_hasCurrentCopy(track.id, track)) done++;
    }
    return (done, total);
  }

  /// The number of tracks the choices want, and how many of them are on this device and up to date.
  int get wantedCount => _wanted.length;
  int get doneCount => progressOf(_wanted.values).$1;

  /// The space the copies take, covers included.
  int get bytesOnDisk => _bytesOnDisk;

  /// The copies on this device, whether the choices still want them or not.
  int get copyCount => _copies.length;

  /// The track being downloaded and how far it is (0..1), or null.
  Track? get currentTrack => _current?.isCover ?? true ? null : _current!.track;
  double get currentProgress => _currentTotal <= 0 ? 0 : (_currentReceived / _currentTotal).clamp(0.0, 1.0);

  /// Downloads are waiting because the server cannot be reached or nobody is signed in.
  bool get isWaitingForServer => doneCount < wantedCount && !_session.isLoggedIn;

  /// Why the last download failed, in the active language; null while nothing failed.
  String? get errorMessage => _errorKey == null ? null : Localizer.format(_errorKey!, _errorArgs);

  bool _hasCurrentCopy(String trackId, [Track? track]) {
    final copy = _copies[trackId];
    final current = track ?? _library.getTrack(trackId);
    return copy != null && current != null && copy.version == _version(current);
  }

  String _absolute(String relative) => p.join(directory, relative);

  // ── Start-up ───────────────────────────────────────────────────────────────────────────────────

  /// Reads the choices, the record of the copies and the files on disk, then keeps the copies in line with the library.
  Future<void> initialize() async {
    if (_initialized) return;
    _syncModeEnabled = _library.getPreference(_syncModePreference) != '0';
    _choices = _Choices.fromJson(_decode(_library.getPreference(_choicesPreference)));
    await _loadCopies();
    await _loadCovers();
    await _adoptLegacyCopies();
    if (!_syncModeEnabled) _dropEmptyChoices();
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) {
        _unavailable.clear();
        _onListChanged(true);
      }),
      _library.playlistsChanged.listen((_) => _onListChanged(_choices.playlists.isNotEmpty)),
      _library.favoriteChanged.listen((_) => _onListChanged(_choices.favorites)),
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

  /// The copies the repository records, as far as they are still there. A copy deleted outside Wiretune is forgotten
  /// (and with sync on fetched again); one that was being moved into place when the app stopped may be cut short, so it
  /// goes.
  Future<void> _loadCopies() async {
    _copies.clear();
    _bytesOnDisk = 0;
    for (final MapEntry(key: id, value: (version, path)) in _repository.getDownloads().entries) {
      final file = File(_absolute(path));
      if (version.isNotEmpty && _isInside(path) && await file.exists()) {
        _copies[id] = _Copy(version, path);
        _bytesOnDisk += await file.length();
        continue;
      }
      if (version.isEmpty && _isInside(path)) await _deleteFile(file.path);
      _repository.deleteDownload(id);
    }
  }

  Future<void> _loadCovers() async {
    _covers.clear();
    final dir = Directory(_coverDirectory);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      final match = _coverName.firstMatch(p.basename(entity.path));
      if (entity is! File || match == null) continue;
      _covers[match.group(1)!] = entity.path;
      _bytesOnDisk += await entity.length();
    }
  }

  /// Earlier versions of Wiretune named copies by hashes (`stem-version-name.ext`), in the app's data or in this
  /// folder, and kept the covers next to them. The copies of the present server files move into place under their
  /// readable names; the rest, which nothing could find again, are deleted. Without a library to tell them by (before
  /// the first sign-in) they wait.
  Future<void> _adoptLegacyCopies() async {
    final legacyFolders = {
      AppPaths.fullPath(directory),
      AppPaths.fullPath(p.join(AppPaths.getDataDirectory(), 'Downloads')),
    };
    final byStem = {for (final t in _library.rawTracks.where((t) => !t.isLocal)) _stem(t.id): t};
    if (byStem.isEmpty) return;
    for (final folder in legacyFolders) {
      final dir = Directory(folder);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        final match = _legacyCopyName.firstMatch(p.basename(entity.path));
        if (entity is! File || match == null) continue;
        final track = byStem[match.group(1)!];
        if (track != null && !_copies.containsKey(track.id) && match.group(2) == _version(track)) {
          try {
            await _placeCopy(entity.path, track);
            continue;
          } on FileSystemException catch (e) {
            WiretuneLog.warn('Downloads', 'Could not move an earlier copy into place: $e');
          }
        }
        await _deleteFile(entity.path);
      }
      final oldCovers = Directory(p.join(folder, 'covers'));
      if (await oldCovers.exists()) {
        await for (final entity in oldCovers.list(followLinks: false)) {
          final match = _coverName.firstMatch(p.basename(entity.path));
          if (entity is! File || match == null) continue;
          if (_covers.containsKey(match.group(1))) {
            await _deleteFile(entity.path);
            continue;
          }
          try {
            final target = p.join(_coverDirectory, p.basename(entity.path));
            await Directory(_coverDirectory).create(recursive: true);
            await _move(entity.path, target);
            _covers[match.group(1)!] = target;
            _bytesOnDisk += await File(target).length();
          } on FileSystemException {
            await _deleteFile(entity.path);
          }
        }
        await _deleteIfEmpty(oldCovers);
      }
      if (folder != AppPaths.fullPath(directory)) await _deleteIfEmpty(dir);
    }
  }

  /// With sync off, a choice none of whose tracks are on the device or still to come has nothing left to keep: the copies
  /// it downloaded were deleted outside Wiretune.
  void _dropEmptyChoices() {
    bool keeps(Iterable<Track> tracks) =>
        tracks.any((t) => !t.isLocal && (_copies.containsKey(t.id) || _choices.pending.contains(t.id)));
    final before = jsonEncode(_choices.toJson());
    _choices.tracks.removeWhere((id) => !_copies.containsKey(id) && !_choices.pending.contains(id));
    _choices.albums.removeWhere((id) => !keeps(_library.getAlbum(id)?.tracks ?? const []));
    _choices.artists.removeWhere((id) => !keeps(_library.getArtist(id)?.albums.expand((a) => a.tracks) ?? const []));
    _choices.playlists.removeWhere((id) {
      final playlist = _library.getPlaylist(id);
      return !keeps(playlist == null ? const [] : _library.getPlaylistTracks(playlist));
    });
    if (_choices.favorites && !keeps(_library.favorites)) _choices.favorites = false;
    if (jsonEncode(_choices.toJson()) != before) _saveChoices();
  }

  // ── Keeping the copies in line with the choices ──────────────────────────────────────────────────

  /// Every server track the choices cover: the albums', the artists' albums', the playlists', the favourites and the
  /// single tracks.
  Map<String, Track> _covered() {
    final covered = <String, Track>{};
    void add(Track? track) {
      if (track != null && !track.isLocal) covered.putIfAbsent(track.id, () => track);
    }

    for (final albumId in _choices.albums) {
      _library.getAlbum(albumId)?.tracks.forEach(add);
    }
    for (final artistId in _choices.artists) {
      for (final album in _library.getArtist(artistId)?.albums ?? const <Album>[]) {
        album.tracks.forEach(add);
      }
    }
    for (final playlistId in _choices.playlists) {
      final playlist = _library.getPlaylist(playlistId);
      if (playlist != null) _library.getPlaylistTracks(playlist).forEach(add);
    }
    if (_choices.favorites) _library.favorites.forEach(add);
    for (final trackId in _choices.tracks) {
      add(_library.getTrack(trackId));
    }
    return covered;
  }

  /// What to keep and fetch: everything the choices cover with sync on; with it off, of that only what is on the device
  /// already or still to come from a choice.
  void _refreshWanted() {
    final wanted = _covered();
    if (!_syncModeEnabled) wanted.removeWhere((id, _) => !_copies.containsKey(id) && !_choices.pending.contains(id));
    _wanted = wanted;
    _wantedCovers = {
      for (final track in wanted.values)
        if (_isServerUrl(track.coverArtPath)) _coverStem(track.coverArtPath!),
    };
    final current = _current;
    if (current != null && !(current.isCover ? _wantedCovers.contains(current.id) : wanted.containsKey(current.id))) {
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
        while (_canDownload && !_runAgain) {
          final job = await _nextJob();
          if (job == null) break;
          if (!await _perform(job)) break;
        }
      } while (_runAgain && !_disposed);
    } catch (e, s) {
      WiretuneLog.error('Downloads', 'Keeping the downloads in step failed', e, s);
    } finally {
      _running = false;
      _current = null;
      if (!_disposed) changed.emit(null);
    }
  }

  /// Deletes the copies and covers nothing wants, and the partial downloads of either.
  Future<void> _prune() async {
    for (final MapEntry(key: id, value: copy) in _copies.entries.toList()) {
      if (_wanted.containsKey(id)) continue;
      if (await _deleteFile(_absolute(copy.path), counted: true, cleanParents: true)) {
        _copies.remove(id);
        _repository.deleteDownload(id);
      }
    }
    for (final MapEntry(key: stem, value: path) in _covers.entries.toList()) {
      if (!_wantedCovers.contains(stem) && await _deleteFile(path, counted: true)) _covers.remove(stem);
    }
    final partial = Directory(_partialDirectory);
    if (await partial.exists()) {
      final keep = {for (final t in _wanted.values) _partName(t), for (final c in _wantedCovers) '$c.part'};
      await for (final entity in partial.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is File && !keep.contains(name) && entity.path != _current?.partPath) await _deleteFile(entity.path);
      }
    }
  }

  /// The next file to fetch: an album's cover before its first track, then the track. A file already at a track's
  /// place that is the server's file to the byte (the record of it was lost, say with the app's data) is taken as the
  /// copy instead of being downloaded again.
  Future<_Job?> _nextJob() async {
    for (final track in _wanted.values) {
      final cover = track.coverArtPath;
      if (_isServerUrl(cover)) {
        final coverStem = _coverStem(cover!);
        if (!_covers.containsKey(coverStem) && !_unavailable.contains(coverStem)) {
          return _Job(coverStem, cover, p.join(_partialDirectory, '$coverStem.part'), track, isCover: true);
        }
      }
      if (_hasCurrentCopy(track.id, track) || _unavailable.contains(track.id)) continue;
      if (!_copies.containsKey(track.id) && await _adoptExisting(track)) continue;
      return _Job(track.id, track.streamUrl!, p.join(_partialDirectory, _partName(track)), track);
    }
    return null;
  }

  Future<bool> _adoptExisting(Track track) async {
    if (track.fileSizeBytes <= 0) return false;
    final candidate = _freePath(track, adoptable: true);
    final file = File(_absolute(candidate));
    if (!await file.exists() || await file.length() != track.fileSizeBytes) return false;
    _record(track.id, _version(track), candidate);
    _bytesOnDisk += track.fileSizeBytes;
    if (_choices.pending.remove(track.id)) _saveChoices();
    return true;
  }

  /// Fetches one file. False when downloading has to stop for now (a failure that a retry may fix, or a refusal).
  Future<bool> _perform(_Job job) async {
    _current = job;
    _cancelCurrent = false;
    _currentReceived = 0;
    _currentTotal = job.isCover ? 0 : job.track.fileSizeBytes;
    changed.emit(null);
    final token = _session.authToken;
    try {
      if (token == null || token.isEmpty || !_isServerUrl(job.url)) throw const _Refused();

      final contentType = await _fetch(job, token);
      if (job.isCover) {
        await Directory(_coverDirectory).create(recursive: true);
        final target = p.join(_coverDirectory, '${job.id}.${imageExtension(contentType)}');
        await _move(job.partPath, target);
        _covers[job.id] = target;
        _bytesOnDisk += await File(target).length();
      } else {
        await _placeCopy(job.partPath, job.track);
        WiretuneLog.info('Downloads', "Downloaded '${job.track.artist} - ${job.track.title}'.");
      }
      _errorKey = null;
      _retryDelay = _firstRetry;
      return true;
    } on _Cancelled {
      // Unwanted now: the partial file goes. The app closing keeps it, and the download continues next time.
      if (!_disposed) await _deleteFile(job.partPath);
      return true;
    } on _Gone {
      // The server no longer has it: nothing to retry until the library is refreshed.
      _unavailable.add(job.id);
      return true;
    } on _Refused {
      // Refused for a token the session has replaced since (a password change): the next try carries the new one.
      if (token != null && _session.authToken != null && _session.authToken != token) return true;
      _stopped = true;
      _setError('DownloadsSignInAgain');
      return false;
    } on FileSystemException catch (e) {
      WiretuneLog.warn('Downloads', 'Could not write a download: $e');
      _setError('DownloadsDiskError', [e.osError?.message ?? e.message]);
      _retryLater();
      return false;
    } catch (e) {
      if (job.isCover) {
        // The audio matters more than its picture: the cover waits for the next refresh of the library instead.
        WiretuneLog.warn('Downloads', "The cover of '${job.track.album}' could not be downloaded: $e");
        _unavailable.add(job.id);
        return true;
      }
      WiretuneLog.warn('Downloads', "Downloading '${job.track.title}' failed: $e");
      _setError('DownloadsFailed', ['$e']);
      _retryLater();
      return false;
    } finally {
      _current = null;
    }
  }

  /// Downloads [job] into its partial file, continuing one that was cut off with a range request; the content type.
  /// The file is complete when this returns: as long as the server said, and for a track as long as its listing said.
  Future<String?> _fetch(_Job job, String token) async {
    final part = File(job.partPath);
    await part.parent.create(recursive: true);
    var offset = await part.exists() ? await part.length() : 0;
    // Complete already: it could not be moved into place last time.
    if (!job.isCover && offset > 0 && offset == job.track.fileSizeBytes) return null;
    final request = http.Request('GET', Uri.parse(job.url))..headers['Authorization'] = 'Bearer $token';
    if (offset > 0) request.headers['Range'] = 'bytes=$offset-';

    final response = await _http.send(request).timeout(_idleTimeout);
    final status = response.statusCode;
    if (status == 401 || status == 403) throw const _Refused();
    if (status == 404 || status == 410) throw const _Gone();
    if (status == 416) {
      await _deleteFile(job.partPath); // the partial file is longer than the server's: start again next time
      throw const HttpException('The partial download did not match the server file.');
    }
    final resumed = status == 206 && rangeStart(response.headers['content-range']) == offset;
    if (status != 200 && !resumed) throw HttpException('HTTP $status');
    if (!resumed) offset = 0;

    final length = response.contentLength;
    _currentTotal = length != null ? offset + length : _currentTotal;
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
    if ((length != null && size != offset + length) || (!job.isCover && !matchesServer(job.track, size))) {
      await _deleteFile(job.partPath);
      throw HttpException('The download ended early ($size bytes).');
    }
    return response.headers['content-type'];
  }

  /// Moves the complete file [source] into the copy's place: the place of the copy it replaces, or a free one. The
  /// record says "moving" until the file is all there, so a move that the app's end cuts short is noticed at the next
  /// start.
  Future<void> _placeCopy(String source, Track track) async {
    final previous = _copies[track.id];
    final relative = previous?.path ?? _freePath(track);
    final target = _absolute(relative);
    final previousSize = previous == null ? 0 : await _sizeOf(target);
    _record(track.id, '', relative);
    try {
      await Directory(p.dirname(target)).create(recursive: true);
      await _move(source, target);
    } on FileSystemException {
      // Nothing was moved (a full disk, a folder the app may not write to, a file still open on Windows).
      if (previous != null) {
        _record(track.id, previous.version, previous.path);
      } else {
        _copies.remove(track.id);
        _repository.deleteDownload(track.id);
      }
      rethrow;
    }
    _record(track.id, _version(track), relative);
    _bytesOnDisk += await File(target).length() - previousSize;
    if (_choices.pending.remove(track.id)) _saveChoices();
  }

  void _record(String trackId, String version, String relative) {
    _copies[trackId] = _Copy(version, relative);
    _repository.saveDownload(trackId, version, relative);
  }

  /// A place for a new copy of [track]: its readable path, or with " (2)", " (3)" … when another copy has that name or
  /// a file that is not a copy is there. Names are compared ignoring case, as most of the file systems involved do.
  /// [adoptable]: the first place that no other copy has, existing file or not (to look for a copy whose record was
  /// lost).
  String _freePath(Track track, {bool adoptable = false}) {
    final taken = {
      for (final MapEntry(key: id, value: copy) in _copies.entries)
        if (id != track.id) copy.path.toLowerCase(),
    };
    final (folder, name, extension) = _readableName(track);
    for (var n = 1; ; n++) {
      final relative = p.join(folder, '${n == 1 ? name : '$name ($n)'}.$extension');
      if (taken.contains(relative.toLowerCase())) continue;
      if (adoptable || !File(_absolute(relative)).existsSync()) return relative;
    }
  }

  /// The readable place of [track]: `Album artist/Album`, and `01 - Title` (`2-01 - Title` on an album of more than
  /// one disc), with the extension of its format.
  (String folder, String name, String extension) _readableName(Track track) {
    final artist = safeFileName(track.effectiveAlbumArtist, fallback: 'Unknown Artist', maxLength: 60);
    final album = safeFileName(track.album, fallback: 'Unknown Album', maxLength: 60);
    final title = safeFileName(track.title, fallback: 'Track', maxLength: 80);
    final number = track.trackNumber;
    final disc = track.discNumber ?? 1;
    final discs = _library.getAlbumForTrack(track)?.tracks.map((t) => t.discNumber ?? 1).toSet().length ?? 1;
    final prefix = [
      if (number != null && number > 0) ...[
        discs > 1 || disc > 1 ? '$disc-' : '',
        '${number.toString().padLeft(2, '0')} - ',
      ],
    ].join();
    return (p.join(artist, album), '$prefix$title', _extension(track.format.codec));
  }

  /// [name] as one part of a path on every system Wiretune runs on: no separators, no characters Windows refuses, no
  /// control characters, no leading dots (a hidden file) or trailing dots and spaces (which Windows drops), no device
  /// names such as `CON`, at most [maxLength] characters and 200 bytes. [fallback] when nothing is left.
  static String safeFileName(String name, {required String fallback, int maxLength = 80}) {
    var safe = name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_').trim();
    safe = safe.replaceFirst(RegExp(r'^[. ]+'), '').replaceFirst(RegExp(r'[. ]+$'), '');
    final runes = safe.runes.toList();
    if (runes.length > maxLength) safe = String.fromCharCodes(runes.take(maxLength)).trimRight();
    while (utf8.encode(safe).length > 200) {
      safe = String.fromCharCodes(safe.runes.take(safe.runes.length - 1));
    }
    safe = safe.replaceFirst(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) return fallback;
    final device = RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$', caseSensitive: false);
    return device.hasMatch(safe) ? '${safe}_' : safe;
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

  /// The server's listing gives the file's size; a copy of another size is not a whole copy of it.
  static bool matchesServer(Track track, int size) => track.fileSizeBytes <= 0 || track.fileSizeBytes == size;

  static int? rangeStart(String? contentRange) {
    final match = RegExp(r'^bytes (\d+)-\d+/(\d+|\*)$').firstMatch(contentRange?.trim() ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  // ── Files ──────────────────────────────────────────────────────────────────────────────────────

  bool _isInside(String relative) => !p.isAbsolute(relative) && p.isWithin(directory, _absolute(relative));

  /// Moves [source] to [target], over a file that is there: a rename on one file system, a copy and a delete across
  /// two (the app's own storage and a shared music folder usually are two).
  static Future<void> _move(String source, String target) async {
    try {
      await File(source).rename(target);
    } on FileSystemException {
      await File(source).copy(target);
      await File(source).delete();
    }
  }

  static Future<int> _sizeOf(String path) async {
    final file = File(path);
    return await file.exists() ? await file.length() : 0;
  }

  /// Deletes a file; false when it could not be (still open on Windows): the next run tries again. [counted]: a copy or
  /// a cover, whose size [bytesOnDisk] includes. [cleanParents] removes the folders of the downloads folder that this
  /// leaves empty.
  Future<bool> _deleteFile(String path, {bool counted = false, bool cleanParents = false}) async {
    final file = File(path);
    try {
      if (await file.exists()) {
        final size = counted ? await file.length() : 0;
        await file.delete();
        _bytesOnDisk -= size;
        if (cleanParents) await _deleteEmptyParents(file.parent);
      }
      return true;
    } on FileSystemException catch (e) {
      WiretuneLog.warn('Downloads', 'Could not delete a download: $e');
      return false;
    }
  }

  Future<void> _deleteEmptyParents(Directory dir) async {
    var current = dir;
    while (p.isWithin(directory, current.path) && await _deleteIfEmpty(current)) {
      current = current.parent;
    }
  }

  static Future<bool> _deleteIfEmpty(Directory dir) async {
    try {
      if (!await dir.exists() || !await dir.list().isEmpty) return false;
      await dir.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Only the server the session is signed in to is sent the token (`http://host:52001` is not `http://host:5200`).
  bool _isServerUrl(String? url) => url != null && url.startsWith('${_session.serverUrl}/');

  // ── Names ──────────────────────────────────────────────────────────────────────────────────────

  // Hashes, so that no ID a server sends becomes part of a path.
  static String _stem(String trackId) => stableId('track\u001f$trackId');

  static String _coverStem(String url) => stableId('cover\u001f$url');

  // The version of a track's server file, worked out once per Track (the library replaces them when the server's data
  // changes).
  static final Expando<String> _versions = Expando();

  static String _version(Track track) => _versions[track] ??= _versionOf(track);

  /// Changes when the server's file does (its size or its modification time, to the second).
  static String _versionOf(Track track) {
    final modified = track.fileModifiedAt?.toUtc().millisecondsSinceEpoch;
    return stableId('${track.fileSizeBytes}\u001f${modified == null ? '' : modified ~/ 1000}').substring(0, 8);
  }

  /// The partial download of one version of a track: a new version starts afresh.
  static String _partName(Track track) => '${_stem(track.id)}-${_version(track)}.part';

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

  static String imageExtension(String? contentType) => switch (contentType?.split(';').first.trim().toLowerCase()) {
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
    if (_ownsClient) _http.close();
  }
}

/// A copy on disk: the version of the server's file it is ('' while it is being moved into place), and its path
/// relative to the downloads folder.
class _Copy {
  const _Copy(this.version, this.path);

  final String version;
  final String path;

  bool get isMoving => version.isEmpty;
}

/// What the user chose to download, and (with sync off) the tracks the choices still have to fetch.
class _Choices {
  final Set<String> tracks = {};
  final Set<String> albums = {};
  final Set<String> artists = {};
  final Set<String> playlists = {};
  bool favorites = false;
  final Set<String> pending = {};

  Map<String, Object?> toJson() => {
    'tracks': tracks.toList(),
    'albums': albums.toList(),
    'artists': artists.toList(),
    'playlists': playlists.toList(),
    'favorites': favorites,
    if (pending.isNotEmpty) 'pending': pending.toList(),
  };

  static _Choices fromJson(Object? json) {
    final choices = _Choices();
    if (json is! Map) return choices;
    Iterable<String> ids(Object? list) => list is List ? list.whereType<String>() : const [];
    choices.tracks.addAll(ids(json['tracks']));
    choices.albums.addAll(ids(json['albums']));
    choices.artists.addAll(ids(json['artists']));
    choices.playlists.addAll(ids(json['playlists']));
    choices.favorites = json['favorites'] == true;
    choices.pending.addAll(ids(json['pending']));
    return choices;
  }
}

/// One file to fetch: a track's audio (its [id] the track's), or an album's cover (its [id] the cover's stem).
class _Job {
  _Job(this.id, this.url, this.partPath, this.track, {this.isCover = false});

  final String id;
  final String url;
  final String partPath;
  final Track track;
  final bool isCover;
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
