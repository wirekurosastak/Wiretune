// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../data/library_repository.dart';
import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../models/protocol.dart';
import '../util/async_lock.dart';
import '../util/cancellation.dart';
import '../util/event.dart';
import '../util/sorting.dart';
import '../util/text.dart';
import 'app_paths.dart';
import 'metadata_scanner.dart';
import 'track_deduplication.dart';
import 'wiretune_log.dart';

/// Why a change the user asked for was not made as asked, for the interface to say: the server account's data can't be
/// changed while the server is out of reach, and a playlist made then stays on this device.
enum ChangeNotice { readOnlyOffline, playlistKeptOnDevice }

/// The library: every track (local and from a server), the albums and artists built from them, and the playlists. It
/// is held in memory as an immutable snapshot that is replaced wholesale after every change, so readers need no lock.
class LibraryService {
  LibraryService(this._repository, this._scanner, {String? coverCacheDirectory})
    : _coverCacheDirectory = coverCacheDirectory ?? p.join(AppPaths.getDataDirectory(), 'Covers');

  final LibraryRepository _repository;
  final MetadataScanner _scanner;
  final String _coverCacheDirectory;
  final AsyncLock _scanGate = AsyncLock();
  LibrarySnapshot _snapshot = LibrarySnapshot.empty;
  List<Playlist> _playlists = const [];
  bool _isScanning = false;

  List<Track> _rawTracks = const [];
  Map<String, Track> _rawTrackById = const {};

  // The favourites (track ID -> when marked; null when that is unknown) and the play statistics: the device's own for
  // its files, the signed-in account's for the server's tracks as the server last told them.
  final Map<String, DateTime?> _favorites = {};
  final Map<String, PlayStats> _plays = {};
  final Map<HiddenKind, Set<String>> _hidden = {for (final kind in HiddenKind.values) kind: <String>{}};

  /// Whose hidden items apply: [_noAccount] without a server account, else the account's ID. The device keeps a copy
  /// of the account's, which the server's replace at every refresh, so they also apply while it cannot be reached.
  static const String _noAccount = 'local';
  String _currentUserId = _noAccount;

  // Server track ID -> ID of the local file it was folded into (see TrackDeduplication); server playlists and the
  // server's favourites still refer to the server ID.
  Map<String, String> _serverAliases = const {};

  List<Track> get tracks => _snapshot.tracks;
  List<Track> get rawTracks => _rawTracks;
  List<Album> get albums => _snapshot.albums;
  List<Artist> get artists => _snapshot.artists;
  List<String> get genres => _snapshot.genres;
  List<Playlist> get playlists => _playlists;
  List<Track> get favorites => [
    for (final t in _snapshot.tracks)
      if (_favorites.containsKey(t.id)) t,
  ];

  bool isFavorite(String trackId) => _favorites.containsKey(trackId);

  /// When the track became a favourite; null when it is none, or the time is unknown (marked before Wiretune kept it).
  DateTime? favoritedAt(String trackId) => _favorites[trackId];

  int playCount(String trackId) => _plays[trackId]?.count ?? 0;
  DateTime? lastPlayedAt(String trackId) => _plays[trackId]?.lastPlayedAt;

  /// What the user hid of [kind], by ID (an artist and an album by their hashed IDs).
  Set<String> hidden(HiddenKind kind) => Set.unmodifiable(_hidden[kind]!);

  /// Switches to the hidden items of the server account [userId] (null or empty: no account), as this device last saw
  /// them.
  void setCurrentUser(String? userId) {
    _currentUserId = (userId != null && userId.isNotEmpty) ? userId : _noAccount;
    _loadHidden();
    _rebuildSnapshot();
    libraryChanged.emit(null);
  }

  void _loadHidden() => _replaceHidden(_repository.getHiddenItems(_currentUserId));

  void _replaceHidden(Map<HiddenKind, Iterable<String>> items) {
    for (final MapEntry(key: kind, value: ids) in _hidden.entries) {
      ids
        ..clear()
        ..addAll(items[kind] ?? const []);
    }
  }

  bool isTrackHidden(Track track) {
    final artists = _hidden[HiddenKind.artist]!;
    return _hidden[HiddenKind.track]!.contains(track.id) ||
        _hidden[HiddenKind.album]!.contains(track.albumId) ||
        artists.contains(stableId(track.primaryArtist.toLowerCase())) ||
        artists.contains(stableId(track.effectiveAlbumArtist.toLowerCase()));
  }

  bool isTrackExplicitlyHidden(String trackId) => _hidden[HiddenKind.track]!.contains(trackId);

  void _rebuildSnapshot() {
    final visible = _rawTracks.where((t) => !isTrackHidden(t)).toList();
    _snapshot = LibrarySnapshot.build(visible, musicFolder: musicFolder);
  }

  bool get isScanning => _isScanning;
  String musicFolder = '';

  final Event<void> libraryChanged = Event<void>();
  final Event<void> playlistsChanged = Event<void>();
  final Event<Track> favoriteChanged = Event<Track>();
  final Event<bool> scanningStateChanged = Event<bool>();

  // The next five are raised only for changes the user made to data that lives on the server; the server session
  // listens and sends them on. favoriteChanged and playlistsChanged stay the "something changed, redraw" events.
  final Event<Track> favoriteToggled = Event<Track>();
  final Event<Track> playRecorded = Event<Track>();
  final Event<Playlist> playlistEdited = Event<Playlist>();
  final Event<String> playlistRemoved = Event<String>();
  final Event<({HiddenKind kind, String id, bool hidden})> hiddenToggled = Event();

  /// A change the user asked for that was not made as asked ([ChangeNotice]).
  final Event<ChangeNotice> changeNotice = Event<ChangeNotice>();

  /// Set by the server session while it is signed in. The favourites, play counts and playlists of server tracks live
  /// on the server account, so they can only be changed then: a change is saved here at once and sent on.
  bool serverConnected = false;

  /// Where the library keeps its tracks, playlists and settings; the downloads keep the record of their copies there too.
  LibraryRepository get repository => _repository;

  /// Reads a small persisted user preference (interface language, theme); null when it was never set.
  String? getPreference(String name) => _repository.getSetting('preference.$name');

  void setPreference(String name, String value) => _repository.setSetting('preference.$name', value);

  void initialize() {
    _repository.initialize();
    musicFolder = _repository.getSetting('music_folder', '') ?? '';

    final storedTracks = _repository.getAllTracks();
    final storedPlaylists = _repository.getAllPlaylists();
    final userData = _repository.getUserData();

    _rawTracks = storedTracks;
    _rawTrackById = {for (final t in storedTracks) t.id: t};
    _favorites
      ..clear()
      ..addAll(userData.favorites);
    _plays
      ..clear()
      ..addAll(userData.plays);
    _loadHidden();

    _rebuildSnapshot();
    _playlists = _sortedPlaylists(storedPlaylists);

    WiretuneLog.info(
      'LibraryService',
      'Initialized with ${tracks.length} tracks (${_rawTracks.length} total), ${albums.length} albums, ${artists.length} artists, ${playlists.length} playlists.',
    );
    libraryChanged.emit(null);
    playlistsChanged.emit(null);
  }

  static List<Playlist> _sortedPlaylists(Iterable<Playlist> playlists) {
    final list = playlists.toList();
    sortStable(list, (a, b) => compareText(a.name, b.name));
    return list;
  }

  /// Scans [folderPath] (incrementally) and makes it the local part of the library. False when the folder does not
  /// exist, another scan is running, or the scan was cancelled.
  Future<bool> scanFolder(
    String folderPath, {
    void Function(ScanProgressReport report)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    if (folderPath.trim().isEmpty || !Directory(folderPath).existsSync()) return false;
    if (_scanGate.isLocked) return false;

    final result = await _scanGate.synchronized(() async {
      _isScanning = true;
      scanningStateChanged.emit(true);
      try {
        final root = AppPaths.fullPath(folderPath);
        WiretuneLog.info('LibraryService', "Scanning '$root'...");

        final known = <String, Track>{};
        for (final t in _rawTracks) {
          if (t.filePath.isNotEmpty) known.putIfAbsent(t.filePath, () => t);
        }

        List<Track> scanned;
        try {
          scanned = await _scanner.scanDirectory(
            root,
            coverCacheDirectory: _coverCacheDirectory,
            onProgress: onProgress,
            cancellationToken: cancellationToken,
            knownTracks: known,
          );
        } on OperationCanceledException {
          WiretuneLog.info('LibraryService', 'Scan cancelled; library left unchanged.');
          return false;
        }
        if (cancellationToken?.isCancelled ?? false) return false;

        musicFolder = root;
        _repository.setSetting('music_folder', root);

        // From here on nothing waits, so a server refresh can't interleave with this one.
        final existingServerTracks = _rawTracks.where((t) => !t.isLocal).toList();
        List<Track> toSave;
        if (existingServerTracks.isNotEmpty) {
          final aliased = <String, String>{};
          toSave = TrackDeduplication.mergeTracks(scanned, existingServerTracks, aliased);
          _serverAliases = aliased;
          _foldServerData(aliased);
          _updatePlaylistsWithAliases(aliased);
        } else {
          toSave = scanned;
        }
        _replaceTracksCore(toSave);
        _pruneCoverCache();

        WiretuneLog.info(
          'LibraryService',
          'Scan finished: ${tracks.length} tracks, ${albums.length} albums, ${artists.length} artists.',
        );
        return true;
      } catch (e, s) {
        WiretuneLog.error('LibraryService', 'Error during scan: $e', e, s);
        rethrow;
      } finally {
        _isScanning = false;
        scanningStateChanged.emit(false);
      }
    });
    return result;
  }

  /// Deletes the covers cached from files that no track shows any more: an album that went, a picture that changed.
  void _pruneCoverCache() {
    final used = {
      for (final t in _rawTracks)
        if (t.coverArtPath case final path?) p.basename(path),
    };
    try {
      final directory = Directory(_coverCacheDirectory);
      if (!directory.existsSync()) return;
      for (final file in directory.listSync().whereType<File>()) {
        final name = p.basename(file.path);
        if (name.startsWith('cover_') && !used.contains(name)) file.deleteSync();
      }
    } on FileSystemException catch (e) {
      WiretuneLog.debug('LibraryService', 'Could not tidy the cover cache: $e');
    }
  }

  /// Replaces the server part of the library, with the signed-in account's favourites, play counts and playlists as
  /// the server holds them (they replace whatever this device cached).
  void mergeServerTracks(Iterable<Track> serverTracks, UserDataSnapshot userData) {
    final incomingServer = serverTracks.toList();
    _applyUserData(incomingServer, userData);

    _replaceHidden(userData.hidden);
    // Never kept as the device's own: the session names the account before it downloads the account's data.
    if (_currentUserId != _noAccount) _repository.replaceHiddenItems(_currentUserId, userData.hidden);
    final existingLocalTracks = _rawTracks.where((t) => t.isLocal).toList();

    List<Track> merged;
    if (existingLocalTracks.isNotEmpty) {
      // Favourites and play counts of a server copy move to the local file (never the other way round).
      final aliased = <String, String>{};
      merged = TrackDeduplication.mergeTracks(existingLocalTracks, incomingServer, aliased);
      _serverAliases = aliased;
      _foldServerData(aliased);
      _updatePlaylistsWithAliases(aliased);
    } else {
      merged = incomingServer;
      _serverAliases = const {};
    }

    _replaceServerPlaylists(userData.playlists);
    _replaceTracksCore(merged);
  }

  /// Drops the server's tracks and the cached copies of its playlists (sign-out); local tracks and playlists stay.
  void removeServerTracks() {
    final existingLocalTracks = _rawTracks.where((t) => t.isLocal).toList();
    _serverAliases = const {};
    if (_playlists.any((p) => p.isServer)) _replaceServerPlaylists(const []);
    // The account's hidden items leave the device with its tracks.
    if (_currentUserId != _noAccount) _repository.clearHiddenItems(_currentUserId);
    _currentUserId = _noAccount;
    _loadHidden();
    _replaceTracksCore(existingLocalTracks);
  }

  /// The account's favourites and play statistics, as the server holds them, for its tracks: they replace what this
  /// device cached.
  void _applyUserData(Iterable<Track> serverTracks, UserDataSnapshot data) {
    final favorites = data.favorites.toSet();
    final plays = {for (final stats in data.plays) stats.trackId: stats};
    for (final track in serverTracks) {
      final id = track.id;
      if (favorites.contains(id)) {
        _favorites[id] = data.favoritedAt[id];
      } else {
        _favorites.remove(id);
      }
      final stats = plays[id];
      if (stats != null) {
        _plays[id] = (count: stats.playCount, lastPlayedAt: stats.lastPlayedAt);
      } else {
        _plays.remove(id);
      }
    }
  }

  /// A server track that is the same song as a local file is shown as the file: its favourite (marked whenever the
  /// first of the two was) and play statistics (the higher count, the later play) move to the file, never back.
  void _foldServerData(Map<String, String> aliases) {
    for (final MapEntry(key: serverId, value: localId) in aliases.entries) {
      if (_favorites.containsKey(serverId)) {
        final local = _favorites[localId];
        final server = _favorites[serverId];
        _favorites[localId] = !_favorites.containsKey(localId)
            ? server
            : local != null && server != null && server.isBefore(local)
            ? server
            : local ?? server;
      }
      final server = _plays[serverId];
      if (server != null) {
        final local = _plays[localId];
        final lastServer = server.lastPlayedAt;
        final lastLocal = local?.lastPlayedAt;
        _plays[localId] = (
          count: local == null || server.count > local.count ? server.count : local.count,
          lastPlayedAt: lastLocal == null || (lastServer != null && lastServer.isAfter(lastLocal))
              ? lastServer
              : lastLocal,
        );
      }
    }
  }

  /// Replaces the cached server playlists with [playlists] (an empty list removes them).
  void _replaceServerPlaylists(List<PlaylistData> playlists) {
    final fromServer = [
      for (final pl in playlists)
        Playlist(
          id: pl.id,
          name: pl.name,
          description: pl.description,
          trackIds: List.of(pl.trackIds),
          createdAt: pl.createdAt,
          modifiedAt: pl.modifiedAt,
          isServer: true,
        ),
    ];

    _repository.deleteServerPlaylists();
    for (final playlist in fromServer) {
      _repository.savePlaylist(playlist);
    }

    _playlists = _sortedPlaylists([..._playlists.where((pl) => !pl.isServer), ...fromServer]);
    playlistsChanged.emit(null);
  }

  /// Points playlist entries at the local copy of a track that also exists on the server.
  void _updatePlaylistsWithAliases(Map<String, String> aliasedTrackIds) {
    if (aliasedTrackIds.isEmpty) return;
    // Server playlists keep the server's IDs (other devices resolve them); getPlaylistTracks follows the aliases.
    for (final playlist in _playlists.where((pl) => !pl.isServer).toList()) {
      if (!playlist.trackIds.any(aliasedTrackIds.containsKey)) continue;
      // Copy-on-write, like every other playlist change: readers may be iterating trackIds right now.
      final seen = <String>{};
      playlist.trackIds = [
        for (final id in playlist.trackIds)
          if (seen.add(aliasedTrackIds[id] ?? id)) aliasedTrackIds[id] ?? id,
      ];
      playlist.modifiedAt = DateTime.now().toUtc();
      _repository.savePlaylist(playlist);
    }
  }

  void _replaceTracksCore(List<Track> tracks) {
    _rawTracks = tracks;
    _rawTrackById = {for (final t in tracks) t.id: t};
    // What tracks that are gone had goes with them, as their rows do.
    _favorites.removeWhere((id, _) => !_rawTrackById.containsKey(id));
    _plays.removeWhere((id, _) => !_rawTrackById.containsKey(id));
    _repository.replaceAllTracks(tracks);
    _repository.saveUserData(_rawTrackById.keys, _favorites, _plays);
    _rebuildSnapshot();
    libraryChanged.emit(null);
  }

  /// False for a server track while the server cannot be reached: its favourite and play count live there.
  bool _canChangeUserData(Track track) => track.isLocal || serverConnected;

  void toggleFavorite(String trackId) {
    final track = getTrack(trackId);
    if (track == null) return;
    if (!_canChangeUserData(track)) return changeNotice.emit(ChangeNotice.readOnlyOffline);

    _markFavorite(track, !isFavorite(trackId));
    if (!track.isLocal) favoriteToggled.emit(track);
  }

  /// Sets a favourite without telling the server, e.g. to undo a change the server did not take.
  void setFavorite(String trackId, bool favorite) {
    final track = getTrack(trackId);
    if (track == null || isFavorite(trackId) == favorite) return;
    _markFavorite(track, favorite);
  }

  void _markFavorite(Track track, bool favorite) {
    final at = favorite ? DateTime.now().toUtc() : null;
    if (favorite) {
      _favorites[track.id] = at;
    } else {
      _favorites.remove(track.id);
    }
    _repository.saveUserData([track.id], _favorites, _plays);
    favoriteChanged.emit(track);
  }

  void recordPlay(String trackId) {
    final track = getTrack(trackId);
    if (track == null || !_canChangeUserData(track)) return;

    _plays[trackId] = (count: playCount(trackId) + 1, lastPlayedAt: DateTime.now().toUtc());
    _repository.saveUserData([trackId], _favorites, _plays);
    if (!track.isLocal) playRecorded.emit(track);
  }

  Playlist createPlaylist(String name, [String? description]) {
    final playlist = Playlist(
      id: newId(),
      name: isBlank(name) ? Localizer.get('PlaylistNew') : name.trim(),
      description: description,
      isServer: serverConnected,
    );
    if (!serverConnected && _currentUserId != _noAccount) changeNotice.emit(ChangeNotice.playlistKeptOnDevice);

    _repository.savePlaylist(playlist);
    _playlists = _sortedPlaylists([..._playlists, playlist]);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
    return playlist;
  }

  /// Adds [trackIds] to the end of the playlist, those not in it yet and in their order, as one change.
  void addTracksToPlaylist(String playlistId, Iterable<String> trackIds) => _updatePlaylist(playlistId, (ids) {
    final present = ids.toSet();
    final added = [
      for (final id in trackIds)
        if (present.add(id)) id,
    ];
    return added.isEmpty ? null : [...ids, ...added];
  });

  /// Moves the entry shown at [from] among the playlist's tracks ([getPlaylistTracks]) to [to], counted after it has
  /// been taken out. Entries of tracks this library doesn't have (which aren't shown) keep their places among the rest.
  void movePlaylistTrack(String playlistId, int from, int to) => _updatePlaylist(playlistId, (ids) {
    final byId = _rawTrackById;
    final aliases = _serverAliases;
    final shown = [
      for (var i = 0; i < ids.length; i++)
        if (byId[ids[i]] != null || byId[aliases[ids[i]]] != null) i,
    ];
    if (from == to || from < 0 || to < 0 || from >= shown.length || to >= shown.length) return null;
    final at = shown[to];
    final list = List.of(ids);
    list.insert(at, list.removeAt(shown[from]));
    return list;
  });

  void removeTrackFromPlaylist(String playlistId, String trackId) =>
      _updatePlaylist(playlistId, (ids) => ids.contains(trackId) ? ids.where((id) => id != trackId).toList() : null);

  void _updatePlaylist(String playlistId, List<String>? Function(List<String> ids) change) {
    final playlist = getPlaylist(playlistId);
    if (playlist == null) return;
    if (!_canChangePlaylist(playlist)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    final updated = change(playlist.trackIds);
    if (updated == null) return;

    playlist.trackIds = updated;
    playlist.modifiedAt = DateTime.now().toUtc();
    _repository.savePlaylist(playlist);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
  }

  /// A playlist of the server account cannot be changed while the server cannot be reached.
  bool _canChangePlaylist(Playlist playlist) => !playlist.isServer || serverConnected;

  void renamePlaylist(String playlistId, String newName) {
    if (isBlank(newName)) return;
    final playlist = getPlaylist(playlistId);
    if (playlist == null) return;
    if (!_canChangePlaylist(playlist)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    playlist.name = newName.trim();
    playlist.modifiedAt = DateTime.now().toUtc();

    _repository.savePlaylist(playlist);
    _playlists = _sortedPlaylists(_playlists);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
  }

  void deletePlaylist(String playlistId) {
    final removed = getPlaylist(playlistId);
    if (removed == null) return;
    if (!_canChangePlaylist(removed)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    _playlists = _playlists.where((pl) => pl.id != playlistId).toList();

    _repository.deletePlaylist(playlistId);
    playlistsChanged.emit(null);
    if (removed.isServer) playlistRemoved.emit(playlistId);
  }

  /// Tracks whose title, artist, album, album artist or genre contain [query] (ignoring case).
  Iterable<Track> search(String query) {
    final all = _snapshot.tracks;
    if (isBlank(query)) return all;
    final q = query.trim().toLowerCase();
    bool has(String? text) => text != null && text.toLowerCase().contains(q);
    return all.where((t) => has(t.title) || has(t.artist) || has(t.album) || has(t.albumArtist) || has(t.genre));
  }

  Track? getTrack(String trackId) => _rawTrackById[trackId];

  /// Hides (or shows again) an artist, an album or a track, by [id].
  void setHidden(HiddenKind kind, String id, bool hidden) => _setHidden(kind, id, hidden);

  void unhideAll() {
    for (final MapEntry(key: kind, value: ids) in _hidden.entries) {
      for (final id in ids.toList()) {
        _setHidden(kind, id, false);
      }
    }
  }

  /// Sets hidden state locally without emitting hiddenToggled event, e.g. to undo a change rejected by the server.
  void setHiddenLocal(HiddenKind kind, String id, bool hidden) => _setHidden(kind, id, hidden, fromServer: true);

  /// Whether hidden items can be changed now: always without an account; with one, like its favourites, only while
  /// signed in to the server, which holds them (a change made meanwhile would be undone by the next refresh).
  bool get canChangeHidden => _currentUserId == _noAccount || serverConnected;

  void _setHidden(HiddenKind kind, String id, bool hidden, {bool fromServer = false}) {
    if (!fromServer && !canChangeHidden) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    final ids = _hidden[kind]!;
    if (!(hidden ? ids.add(id) : ids.remove(id))) return;

    _repository.setHiddenItem(kind, id, hidden, _currentUserId);
    if (!fromServer && _currentUserId != _noAccount) hiddenToggled.emit((kind: kind, id: id, hidden: hidden));
    _rebuildSnapshot();
    libraryChanged.emit(null);
  }

  Album? getAlbum(String albumId) => _snapshot.albumById[albumId];

  Album? getAlbumForTrack(Track track) => _snapshot.albumById[track.albumId];

  Artist? getArtist(String artistId) => _snapshot.artists.where((a) => a.id == artistId).firstOrNull;

  Artist? getArtistByName(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    final existing = _snapshot.artists.where((a) => equalsIgnoreCase(a.name, trimmed)).firstOrNull;
    if (existing != null) return existing;

    final matchingTracks = _snapshot.tracks
        .where((t) => t.artistNames.any((n) => equalsIgnoreCase(n, trimmed)))
        .toList();
    if (matchingTracks.isEmpty) return null;
    return Artist(id: stableId(trimmed.toLowerCase()), name: trimmed, tracks: matchingTracks);
  }

  Playlist? getPlaylist(String playlistId) => _playlists.where((pl) => pl.id == playlistId).firstOrNull;

  List<Track> getPlaylistTracks(Playlist playlist) => resolveTracks(playlist.trackIds);

  /// The tracks with these IDs, in their order; a server ID also finds the local file it was matched to. Unknown IDs
  /// are left out.
  List<Track> resolveTracks(Iterable<String> trackIds) {
    final byId = _rawTrackById;
    final aliases = _serverAliases;
    return [for (final id in trackIds) ?(byId[id] ?? byId[aliases[id]])];
  }

  /// The ID the other devices of the account know [track] by: the server's, also for a local file that was matched to
  /// a server track; the track's own ID for a file only this device has.
  String sharedId(Track track) {
    if (!track.isLocal) return track.id;
    final aliases = _serverAliases;
    if (!identical(aliases, _sharedIdsSource)) {
      _sharedIdsSource = aliases;
      _sharedIds = {for (final MapEntry(key: serverId, value: localId) in aliases.entries) localId: serverId};
    }
    return _sharedIds[track.id] ?? track.id;
  }

  Map<String, String> _sharedIdsSource = const {};
  Map<String, String> _sharedIds = const {};
}

/// Immutable view of the library; replaced wholesale so readers never need a lock or a copy.
class LibrarySnapshot {
  LibrarySnapshot._(this.tracks, this.trackById, this.albums, this.albumById, this.artists, this.genres);

  static final LibrarySnapshot empty = LibrarySnapshot.build(const []);

  final List<Track> tracks;
  final Map<String, Track> trackById;
  final List<Album> albums;
  final Map<String, Album> albumById;
  final List<Artist> artists;
  final List<String> genres;

  static int _disc(Track t) => t.discNumber ?? 1;
  static int _number(Track t) => t.trackNumber ?? 0x7FFFFFFF;

  /// What a folder of one artist's songs from several albums is called when the folder is named after the artist.
  static const String essentialsSuffix = 'Essentials';

  /// Builds the library from [source]. [musicFolder] is the local music folder: its loose files are never one album.
  static LibrarySnapshot build(Iterable<Track> source, {String musicFolder = ''}) {
    final seen = <String>{};
    final tracks = [
      for (final t in source)
        if (seen.add(t.id)) t,
    ];
    // Where to file each track is worked out from its tags alone, never from an earlier build.
    for (final t in tracks) {
      t.filed = null;
    }
    final folderAlbums = _folderAlbums(tracks, musicFolder);
    sortStable(
      tracks,
      thenBy<Track>([
        (a, b) => compareText(a.artist, b.artist),
        (a, b) => compareText(a.album, b.album),
        (a, b) => _disc(a).compareTo(_disc(b)),
        (a, b) => _number(a).compareTo(_number(b)),
        (a, b) => compareText(a.title, b.title),
      ]),
    );

    // Consolidate multi-artist albums where the album artist tag is missing or incomplete. Only tracks that share a
    // folder on disk and have no colliding track numbers count. What is inferred here is where the track is filed, not
    // what its tags say, so a value inferred from an earlier set of files cannot outlive them.
    String? tagged(Track t) => t.tagged.albumArtist;
    final inferred = <Track, String>{};

    // Only files on this machine have a folder; the server already did this for its own tracks.
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      if (t.filePath.isEmpty || isBlank(t.album) || equalsIgnoreCase(t.album, Track.unknownAlbum)) continue;
      if (folderAlbums.contains(t)) continue;
      final folder = p.dirname(t.filePath).toLowerCase();
      groups.putIfAbsent('${t.album.trim()}\u0000$folder', () => []).add(t);
    }

    for (final groupTracks in groups.values) {
      if (groupTracks.length < 2) continue;

      // Do not merge when distinct tracks collide on (disc, track number).
      final numbers = <String>{};
      var collision = false;
      for (final t in groupTracks) {
        if (t.trackNumber != null && t.trackNumber! > 0 && !numbers.add('${_disc(t)}:${t.trackNumber}')) {
          collision = true;
          break;
        }
      }
      if (collision) continue;

      final explicitAlbumArtist = groupTracks.map(tagged).where((a) => !isBlank(a)).firstOrNull;
      if (explicitAlbumArtist != null) {
        for (final t in groupTracks.where((t) => isBlank(tagged(t)))) {
          inferred[t] = explicitAlbumArtist;
        }
        continue;
      }

      final counts = <String, (String, int)>{};
      for (final t in groupTracks) {
        final key = t.primaryArtist.toLowerCase();
        final current = counts[key];
        counts[key] = (current?.$1 ?? t.primaryArtist, (current?.$2 ?? 0) + 1);
      }
      if (counts.length > 1) {
        var top = counts.values.first;
        for (final entry in counts.values) {
          if (entry.$2 > top.$2) top = entry;
        }
        final resolved = top.$2 * 2 > groupTracks.length ? top.$1 : 'Various Artists';
        for (final t in groupTracks) {
          inferred[t] = resolved;
        }
      }
    }

    for (final MapEntry(key: t, value: albumArtist) in inferred.entries) {
      t.filed = (album: t.album, albumArtist: albumArtist, trackNumber: t.trackNumber, discNumber: t.discNumber);
    }

    final byAlbum = <String, List<Track>>{};
    for (final t in tracks) {
      byAlbum.putIfAbsent(t.albumId, () => []).add(t);
    }

    final albums = <Album>[];
    for (final entry in byAlbum.entries) {
      final ordered = List<Track>.of(entry.value);
      sortStable(
        ordered,
        thenBy<Track>([
          (a, b) => _disc(a).compareTo(_disc(b)),
          (a, b) => _number(a).compareTo(_number(b)),
          (a, b) => compareText(a.title, b.title),
        ]),
      );
      final first = ordered.first;
      // A folder's collection gathers songs of many years: it is as new as its newest. An album that strays joined
      // keeps its own release year.
      final own = ordered.where((t) => equalsIgnoreCase(t.tagged.album, t.album));
      final folderAlbum = own.isEmpty;
      final years = (folderAlbum ? ordered : own).map((t) => t.releaseYear).whereType<int>();
      albums.add(
        Album(
          id: entry.key,
          title: first.album,
          artist: first.effectiveAlbumArtist,
          releaseYear: folderAlbum && years.isNotEmpty ? years.reduce(math.max) : years.firstOrNull,
          coverArtPath: ordered.where((t) => !isBlank(t.coverArtPath)).firstOrNull?.coverArtPath,
          totalDuration: ordered.fold(Duration.zero, (sum, t) => sum + t.duration),
          quality: qualityOf(ordered)!, // an album always has a track
          tracks: ordered,
        ),
      );
    }
    sortStable(albums, (a, b) => compareText(a.title, b.title));

    final albumsByArtist = <String, List<Album>>{};
    for (final a in albums) {
      albumsByArtist.putIfAbsent(a.artist.toLowerCase(), () => []).add(a);
    }
    // Each artist of a track, featured ones too, so an artist's page also has the songs they guest on.
    final tracksByArtist = <String, List<Track>>{};
    for (final t in tracks) {
      for (final name in t.artistNames) {
        tracksByArtist.putIfAbsent(name.toLowerCase(), () => []).add(t);
      }
    }

    // The Artists view lists album artists only: guest performers and one-off compilation artists stay out of it.
    final artistNames = <String, String>{};
    for (final a in albums) {
      artistNames.putIfAbsent(a.artist.toLowerCase(), () => a.artist);
    }

    final artists = <Artist>[];
    for (final MapEntry(key: key, value: name) in artistNames.entries) {
      final artistAlbums = List<Album>.of(albumsByArtist[key] ?? const []);
      sortStable(
        artistAlbums,
        thenBy<Album>([
          (a, b) => (b.releaseYear ?? -0x80000000).compareTo(a.releaseYear ?? -0x80000000),
          (a, b) => compareText(a.title, b.title),
        ]),
      );
      final seenTracks = <String>{};
      final artistTracks = [
        for (final t in [...artistAlbums.expand((a) => a.tracks), ...?tracksByArtist[key]])
          if (seenTracks.add(t.id)) t,
      ];
      sortStable(
        artistTracks,
        thenBy<Track>([
          (a, b) => compareText(a.album, b.album),
          (a, b) => _disc(a).compareTo(_disc(b)),
          (a, b) => _number(a).compareTo(_number(b)),
        ]),
      );
      artists.add(
        Artist(
          id: stableId(name.toLowerCase()),
          name: name,
          picturePath: artistAlbums.where((a) => !isBlank(a.coverArtPath)).firstOrNull?.coverArtPath,
          albums: artistAlbums,
          tracks: artistTracks,
        ),
      );
    }
    sortStable(artists, (a, b) => compareText(a.name, b.name));

    final genreNames = <String, String>{};
    for (final t in tracks) {
      if (!isBlank(t.genre)) genreNames.putIfAbsent(t.genre!.toLowerCase(), () => t.genre!);
    }
    final genres = genreNames.values.toList();
    sortStable(genres, compareText);

    return LibrarySnapshot._(
      tracks,
      {for (final t in tracks) t.id: t},
      albums,
      {for (final a in albums) a.id: a},
      artists,
      genres,
    );
  }

  /// Files folders put together by hand under one album: a folder whose songs come from several albums but share one
  /// artist (an "essentials" or "best of" collected track by track, each keeping its original album tag). The album
  /// is the one of those tags that is named like the folder, so that strays join it; else the folder's name, or
  /// "Eminem Essentials" when the folder is named after the artist (Eminem). A collection is numbered by title. Only
  /// folders inside [musicFolder] count. Loose files in it, folders of several artists, and a folder holding a whole
  /// album (an artist's albums side by side in one folder) keep their own albums. Returns the tracks it refiled.
  static Set<Track> _folderAlbums(List<Track> tracks, String musicFolder) {
    final refiled = <Track>{};
    if (isBlank(musicFolder)) return refiled;
    final root = AppPaths.comparable(p.normalize(musicFolder));
    final byFolder = <String, List<Track>>{};
    for (final t in tracks) {
      if (t.filePath.isEmpty) continue;
      final key = AppPaths.comparable(p.normalize(p.dirname(t.filePath)));
      if (p.isWithin(root, key)) byFolder.putIfAbsent(key, () => []).add(t);
    }

    String simple(String text) => lettersAndDigits(text.toLowerCase());

    for (final folderTracks in byFolder.values) {
      if (folderTracks.length < 2) continue;
      final albums = <String, String>{};
      final albumTracks = <String, List<Track>>{};
      for (final t in folderTracks) {
        albums.putIfAbsent(t.album.toLowerCase(), () => t.album);
        albumTracks.putIfAbsent(t.album.toLowerCase(), () => []).add(t);
      }
      if (albums.length < 2) continue;

      // The artist every song shares: as album artist, main artist or featured artist.
      bool credits(Track t, String name) =>
          equalsIgnoreCase(t.tagged.albumArtist, name) || t.artistNames.any((n) => equalsIgnoreCase(n, name));
      final first = folderTracks.first;
      final artist = [
        ?cleanText(first.tagged.albumArtist),
        ...first.artistNames,
      ].where((name) => folderTracks.every((t) => credits(t, name))).firstOrNull;
      if (artist == null) continue;

      final folderName = p.basename(p.dirname(first.filePath)).trim();
      final named = simple(folderName);
      if (named.isEmpty) continue;
      final matching = albums.values.where((a) => simple(a) == named).firstOrNull;
      if (matching == null && albumTracks.values.any(_isWholeAlbum)) continue;
      final title = matching ?? (named == simple(artist) ? '$artist $essentialsSuffix' : folderName);

      final ordered = List<Track>.of(folderTracks);
      if (matching == null) sortStable(ordered, (a, b) => compareText(a.title, b.title));
      for (final (index, t) in ordered.indexed) {
        t.filed = matching == null
            ? (album: title, albumArtist: artist, trackNumber: index + 1, discNumber: null)
            : (album: title, albumArtist: artist, trackNumber: t.trackNumber, discNumber: t.discNumber);
        refiled.add(t);
      }
    }
    return refiled;
  }

  /// True when [tracks] (of one album, in one folder) are all of the album: as many as its track total says, or, the
  /// total untagged, five or more numbered 1, 2, 3... without a gap. A single or a pair of songs never is.
  static bool _isWholeAlbum(List<Track> tracks) {
    if (tracks.length < 3) return false;
    final total = tracks.map((t) => t.trackCount).whereType<int>().firstOrNull;
    if (total != null) return tracks.length >= total;
    final numbers = tracks.map((t) => t.trackNumber).whereType<int>().toSet();
    return tracks.length >= 5 && numbers.length == tracks.length && numbers.every((n) => n <= tracks.length);
  }
}
