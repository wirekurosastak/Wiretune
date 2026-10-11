// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/library_repository.dart';
import '../localization/localizer.dart';
import '../models/audio_format.dart';
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

/// The user hid or showed again an artist, an album or a track (`itemType` is `artist`, `album` or `track`).
class HiddenChangeEvent {
  const HiddenChangeEvent(this.itemType, this.itemId, this.hidden);
  final String itemType;
  final String itemId;
  final bool hidden;
}

/// The library: every track (local and from a server), the albums and artists built from them, and the playlists. It
/// is held in memory as an immutable snapshot that is replaced wholesale after every change, so readers need no lock.
class LibraryService {
  LibraryService(this._repository, this._scanner, {String? coverCacheDirectory})
    : _coverCacheDirectory = coverCacheDirectory ?? p.join(AppPaths.getDataDirectory(), 'Covers');

  final LibraryRepository _repository;
  final MetadataScanner _scanner;
  final String _coverCacheDirectory;
  final AsyncLock _scanGate = AsyncLock();

  // Local scans and server merges each read the snapshot, combine it with new data and replace it; one at a time, so
  // neither can overwrite the other's result with a stale view.
  final AsyncLock _commitGate = AsyncLock();
  LibrarySnapshot _snapshot = LibrarySnapshot.empty;
  List<Playlist> _playlists = const [];
  bool _isScanning = false;

  List<Track> _rawTracks = const [];
  Map<String, Track> _rawTrackById = const {};
  final Set<String> _hiddenTracks = <String>{};
  final Set<String> _hiddenAlbums = <String>{};
  final Set<String> _hiddenArtists = <String>{};

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
  List<Track> get favorites => _snapshot.tracks.where((t) => t.isFavorite).toList();

  Set<String> get hiddenTracks => Set.unmodifiable(_hiddenTracks);
  Set<String> get hiddenAlbums => Set.unmodifiable(_hiddenAlbums);
  Set<String> get hiddenArtists => Set.unmodifiable(_hiddenArtists);

  /// Switches to the hidden items of the server account [userId] (null or empty: no account), as this device last saw
  /// them.
  Future<void> setCurrentUser(String? userId) async {
    _currentUserId = (userId != null && userId.isNotEmpty) ? userId : _noAccount;
    await _loadHidden();
    _rebuildSnapshot();
    libraryChanged.emit(null);
  }

  Future<void> _loadHidden() async {
    final stored = await _repository.getHiddenItems(_currentUserId);
    _setHiddenSets(stored['artist'] ?? const {}, stored['album'] ?? const {}, stored['track'] ?? const {});
  }

  void _setHiddenSets(Iterable<String> artists, Iterable<String> albums, Iterable<String> tracks) {
    _hiddenArtists
      ..clear()
      ..addAll(artists);
    _hiddenAlbums
      ..clear()
      ..addAll(albums);
    _hiddenTracks
      ..clear()
      ..addAll(tracks);
  }

  bool isTrackHidden(Track track) {
    if (_hiddenTracks.contains(track.id)) return true;
    if (_hiddenAlbums.contains(track.albumId)) return true;
    if (_hiddenArtists.contains(stableId(track.artist.toLowerCase()))) return true;
    if (_hiddenArtists.contains(stableId(track.effectiveAlbumArtist.toLowerCase()))) return true;
    return false;
  }

  bool isTrackIdHidden(String trackId) {
    final track = _rawTrackById[trackId];
    if (track == null) return _hiddenTracks.contains(trackId);
    return isTrackHidden(track);
  }

  bool isArtistHidden(String artistId) => _hiddenArtists.contains(artistId);
  bool isAlbumHidden(String albumId) => _hiddenAlbums.contains(albumId);
  bool isTrackExplicitlyHidden(String trackId) => _hiddenTracks.contains(trackId);

  void _rebuildSnapshot() {
    final visible = _rawTracks.where((t) => !isTrackHidden(t)).toList();
    _snapshot = LibrarySnapshot.build(visible);
  }

  bool get isScanning => _isScanning;
  String libraryPath = '';

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
  final Event<HiddenChangeEvent> hiddenToggled = Event<HiddenChangeEvent>();

  /// A change the user asked for that was not made as asked ([ChangeNotice]).
  final Event<ChangeNotice> changeNotice = Event<ChangeNotice>();

  /// Set by the server session while it is signed in. The favourites, play counts and playlists of server tracks live
  /// on the server account, so they can only be changed then: a change is saved here at once and sent on.
  bool serverConnected = false;

  /// Where the library keeps its tracks, playlists and settings; the downloads keep the record of their copies there too.
  LibraryRepository get repository => _repository;

  /// Reads a small persisted user preference (interface language, theme); null when it was never set.
  Future<String?> getPreference(String name) => _repository.getSetting('preference.$name');

  Future<void> setPreference(String name, String value) => _repository.setSetting('preference.$name', value);

  Future<void> initialize() async {
    await _repository.initialize();
    libraryPath = await _repository.getSetting('library_path', '') ?? '';

    final storedTracks = await _repository.getAllTracks();
    final storedPlaylists = await _repository.getAllPlaylists();

    _rawTracks = storedTracks;
    _rawTrackById = {for (final t in storedTracks) t.id: t};
    await _loadHidden();

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

        libraryPath = root;
        await _repository.setSetting('library_path', root);

        await _commitGate.synchronized(() async {
          final existingServerTracks = _rawTracks.where((t) => !t.isLocal).toList();
          List<Track> toSave;
          if (existingServerTracks.isNotEmpty) {
            final aliased = <String, String>{};
            toSave = TrackDeduplication.mergeTracks(scanned, existingServerTracks, aliased);
            _serverAliases = aliased;
            await _updatePlaylistsWithAliases(aliased);
          } else {
            toSave = scanned;
          }
          await _replaceTracksCore(toSave);
        });

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

  Future<void> replaceTracks(Iterable<Track> tracks) async {
    final list = tracks.toList();
    await _commitGate.synchronized(() => _replaceTracksCore(list));
  }

  /// Replaces the server part of the library, with the signed-in account's favourites, play counts and playlists as
  /// the server holds them (they replace whatever this device cached).
  Future<void> mergeServerTracks(Iterable<Track> serverTracks, UserDataSnapshot userData) async {
    final incomingServer = serverTracks.toList();
    _applyUserData(incomingServer, userData);

    await _commitGate.synchronized(() async {
      _setHiddenSets(userData.hiddenArtists, userData.hiddenAlbums, userData.hiddenTracks);
      // Never kept as the device's own: the session names the account before it downloads the account's data.
      if (_currentUserId != _noAccount) {
        await _repository.replaceHiddenItems(
          _currentUserId,
          artists: userData.hiddenArtists,
          albums: userData.hiddenAlbums,
          tracks: userData.hiddenTracks,
        );
      }
      final existingLocalTracks = _rawTracks.where((t) => t.isLocal).toList();

      List<Track> merged;
      if (existingLocalTracks.isNotEmpty) {
        // Favourites and play counts of a server copy move to the local file (never the other way round).
        final aliased = <String, String>{};
        merged = TrackDeduplication.mergeTracks(existingLocalTracks, incomingServer, aliased);
        _serverAliases = aliased;
        await _updatePlaylistsWithAliases(aliased);
      } else {
        merged = incomingServer;
        _serverAliases = const {};
      }

      await _replaceServerPlaylists(userData.playlists);
      await _replaceTracksCore(merged, serverOwnsUserData: true);
    });
  }

  /// Drops the server's tracks and the cached copies of its playlists (sign-out); local tracks and playlists stay.
  Future<void> removeServerTracks() async {
    await _commitGate.synchronized(() async {
      final existingLocalTracks = _rawTracks.where((t) => t.isLocal).toList();
      _serverAliases = const {};
      if (_playlists.any((p) => p.isServer)) await _replaceServerPlaylists(const []);
      // The account's hidden items leave the device with its tracks.
      if (_currentUserId != _noAccount) await _repository.clearHiddenItems(_currentUserId);
      _currentUserId = _noAccount;
      await _loadHidden();
      await _replaceTracksCore(existingLocalTracks);
    });
  }

  /// Copies the account's favourites and play statistics onto the freshly downloaded server tracks.
  static void _applyUserData(Iterable<Track> serverTracks, UserDataSnapshot data) {
    final favorites = data.favorites.toSet();
    final plays = {for (final stats in data.plays) stats.trackId: stats};
    for (final track in serverTracks) {
      track.isFavorite = favorites.contains(track.id);
      track.favoritedAt = track.isFavorite ? data.favoritedAt[track.id] : null;
      final stats = plays[track.id];
      track.playCount = stats?.playCount ?? 0;
      track.lastPlayed = stats?.lastPlayed;
    }
  }

  /// Replaces the cached server playlists with [playlists] (an empty list removes them).
  Future<void> _replaceServerPlaylists(List<PlaylistData> playlists) async {
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

    await _repository.deleteServerPlaylists();
    for (final playlist in fromServer) {
      await _repository.savePlaylist(playlist);
    }

    _playlists = _sortedPlaylists([..._playlists.where((pl) => !pl.isServer), ...fromServer]);
    playlistsChanged.emit(null);
  }

  /// Points playlist entries at the local copy of a track that also exists on the server.
  Future<void> _updatePlaylistsWithAliases(Map<String, String> aliasedTrackIds) async {
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
      await _repository.savePlaylist(playlist);
    }
  }

  /// [serverOwnsUserData]: the server's favourites and play counts were just applied to its tracks, so the cached ones
  /// must not overwrite them.
  Future<void> _replaceTracksCore(List<Track> tracks, {bool serverOwnsUserData = false}) async {
    final previous = _rawTrackById.isNotEmpty ? _rawTrackById : _snapshot.trackById;
    for (final track in tracks) {
      final old = previous[track.id];
      if (old != null && !identical(old, track)) {
        if (!(serverOwnsUserData && !track.isLocal)) {
          track.isFavorite = old.isFavorite;
          track.favoritedAt = old.favoritedAt;
          track.playCount = old.playCount;
          track.lastPlayed = old.lastPlayed;
        }
        track.dateAdded = old.dateAdded;
        track.isPlaying = old.isPlaying; // the list keeps highlighting the track that is still playing
      }
    }

    await _repository.replaceAllTracks(tracks);
    _rawTracks = tracks;
    _rawTrackById = {for (final t in tracks) t.id: t};
    _rebuildSnapshot();
    libraryChanged.emit(null);
  }

  /// False for a server track while the server cannot be reached: its favourite and play count live there.
  bool _canChangeUserData(Track track) => track.isLocal || serverConnected;

  Future<void> toggleFavorite(String trackId) async {
    final track = getTrack(trackId);
    if (track == null) return;
    if (!_canChangeUserData(track)) return changeNotice.emit(ChangeNotice.readOnlyOffline);

    _markFavorite(track, !track.isFavorite);
    await _repository.updateTrackFavorite(track.id, track.favoritedAt);
    favoriteChanged.emit(track);
    if (!track.isLocal) favoriteToggled.emit(track);
  }

  /// Sets a favourite without telling the server, e.g. to undo a change the server did not take.
  Future<void> setFavorite(String trackId, bool isFavorite) async {
    final track = getTrack(trackId);
    if (track == null || track.isFavorite == isFavorite) return;

    _markFavorite(track, isFavorite);
    await _repository.updateTrackFavorite(track.id, track.favoritedAt);
    favoriteChanged.emit(track);
  }

  static void _markFavorite(Track track, bool favorite) {
    track
      ..isFavorite = favorite
      ..favoritedAt = favorite ? DateTime.now().toUtc() : null;
  }

  Future<void> recordPlay(String trackId) async {
    final track = getTrack(trackId);
    if (track == null || !_canChangeUserData(track)) return;

    track.playCount++;
    track.lastPlayed = DateTime.now().toUtc();
    await _repository.incrementPlayCount(track.id);
    if (!track.isLocal) playRecorded.emit(track);
  }

  Future<void> updateTrackBpm(String trackId, int bpm) async {
    final track = getTrack(trackId);
    if (track != null) track.bpm = bpm;
    await _repository.updateTrackBpm(trackId, bpm);
  }

  Future<Playlist> createPlaylist(String name, [String? description]) async {
    final playlist = Playlist(
      id: newId(),
      name: isBlank(name) ? Localizer.get('PlaylistNew') : name.trim(),
      description: description,
      isServer: serverConnected,
    );
    if (!serverConnected && _currentUserId != _noAccount) changeNotice.emit(ChangeNotice.playlistKeptOnDevice);

    await _repository.savePlaylist(playlist);
    _playlists = _sortedPlaylists([..._playlists, playlist]);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
    return playlist;
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) =>
      _updatePlaylist(playlistId, (ids) => ids.contains(trackId) ? null : [...ids, trackId]);

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) =>
      _updatePlaylist(playlistId, (ids) => ids.contains(trackId) ? ids.where((id) => id != trackId).toList() : null);

  Future<void> _updatePlaylist(String playlistId, List<String>? Function(List<String> ids) change) async {
    final playlist = getPlaylist(playlistId);
    if (playlist == null) return;
    if (!_canChangePlaylist(playlist)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    final updated = change(playlist.trackIds);
    if (updated == null) return;

    playlist.trackIds = updated;
    playlist.modifiedAt = DateTime.now().toUtc();
    await _repository.savePlaylist(playlist);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
  }

  /// A playlist of the server account cannot be changed while the server cannot be reached.
  bool _canChangePlaylist(Playlist playlist) => !playlist.isServer || serverConnected;

  Future<void> renamePlaylist(String playlistId, String newName) async {
    if (isBlank(newName)) return;
    final playlist = getPlaylist(playlistId);
    if (playlist == null) return;
    if (!_canChangePlaylist(playlist)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    playlist.name = newName.trim();
    playlist.modifiedAt = DateTime.now().toUtc();

    await _repository.savePlaylist(playlist);
    _playlists = _sortedPlaylists(_playlists);
    playlistsChanged.emit(null);
    if (playlist.isServer) playlistEdited.emit(playlist);
  }

  Future<void> deletePlaylist(String playlistId) async {
    final removed = getPlaylist(playlistId);
    if (removed == null) return;
    if (!_canChangePlaylist(removed)) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    _playlists = _playlists.where((pl) => pl.id != playlistId).toList();

    await _repository.deletePlaylist(playlistId);
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

  Track? getTrack(String trackId) => _snapshot.trackById[trackId] ?? _rawTrackById[trackId];

  Future<void> hideTrack(String trackId) => _setHidden('track', trackId, true);
  Future<void> unhideTrack(String trackId) => _setHidden('track', trackId, false);
  Future<void> hideAlbum(String albumId) => _setHidden('album', albumId, true);
  Future<void> unhideAlbum(String albumId) => _setHidden('album', albumId, false);
  Future<void> hideArtist(String artistId) => _setHidden('artist', artistId, true);
  Future<void> unhideArtist(String artistId) => _setHidden('artist', artistId, false);

  Future<void> unhideAll() async {
    for (final (type, ids) in [('artist', _hiddenArtists), ('album', _hiddenAlbums), ('track', _hiddenTracks)]) {
      for (final id in ids.toList()) {
        await _setHidden(type, id, false);
      }
    }
  }

  /// Sets hidden state locally without emitting hiddenToggled event, e.g. to undo a change rejected by the server.
  Future<void> setHiddenLocal(String itemType, String itemId, bool hidden) =>
      _setHidden(itemType, itemId, hidden, fromServer: true);

  /// Whether hidden items can be changed now: always without an account; with one, like its favourites, only while
  /// signed in to the server, which holds them (a change made meanwhile would be undone by the next refresh).
  bool get canChangeHidden => _currentUserId == _noAccount || serverConnected;

  Future<void> _setHidden(String itemType, String itemId, bool hidden, {bool fromServer = false}) async {
    final set = switch (itemType) {
      'artist' => _hiddenArtists,
      'album' => _hiddenAlbums,
      'track' => _hiddenTracks,
      _ => throw ArgumentError.value(itemType, 'itemType'),
    };
    if (!fromServer && !canChangeHidden) return changeNotice.emit(ChangeNotice.readOnlyOffline);
    if (!(hidden ? set.add(itemId) : set.remove(itemId))) return;

    await _repository.setHiddenItem(itemType, itemId, hidden, _currentUserId);
    if (!fromServer && _currentUserId != _noAccount) hiddenToggled.emit(HiddenChangeEvent(itemType, itemId, hidden));
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

    final matchingTracks = _snapshot.tracks.where((t) => equalsIgnoreCase(t.artist, trimmed)).toList();
    if (matchingTracks.isEmpty) return null;
    return Artist(
      id: stableId(trimmed.toLowerCase()),
      name: trimmed,
      trackCount: matchingTracks.length,
      albumCount: 0,
      tracks: matchingTracks,
    );
  }

  Playlist? getPlaylist(String playlistId) => _playlists.where((pl) => pl.id == playlistId).firstOrNull;

  List<Track> getPlaylistTracks(Playlist playlist) => resolveTracks(playlist.trackIds);

  /// The tracks with these IDs, in their order; a server ID also finds the local file it was matched to. Unknown IDs
  /// are left out.
  List<Track> resolveTracks(Iterable<String> trackIds) {
    final byId = _rawTrackById.isNotEmpty ? _rawTrackById : _snapshot.trackById;
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

  static LibrarySnapshot build(Iterable<Track> source) {
    final seen = <String>{};
    final tracks = [
      for (final t in source)
        if (seen.add(t.id)) t,
    ];
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
    // folder on disk and have no colliding track numbers count. What is inferred here is kept apart from what the tags
    // say (albumArtistInferred), recomputed on every build and never stored, so a value inferred from an earlier set of
    // files cannot outlive them.
    String? tagged(Track t) => t.albumArtistInferred ? null : t.albumArtist;
    final inferred = <Track, String>{};

    // Only files on this machine have a folder; the server already did this for its own tracks.
    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      if (t.filePath.isEmpty || isBlank(t.album) || equalsIgnoreCase(t.album, MetadataScanner.unknownAlbum)) continue;
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
        final key = t.artist.toLowerCase();
        final current = counts[key];
        counts[key] = (current?.$1 ?? t.artist, (current?.$2 ?? 0) + 1);
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

    for (final t in tracks) {
      final value = inferred[t];
      if (value != null) {
        t.albumArtist = value;
        t.albumArtistInferred = true;
      } else if (t.albumArtistInferred) {
        // The files this was inferred from changed: back to what the tag says.
        t.albumArtist = null;
        t.albumArtistInferred = false;
      }
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
      final quality = QualitySummary.of(ordered.map((t) => t.format))!; // an album always has at least one track
      albums.add(
        Album(
          id: entry.key,
          title: first.album,
          artist: first.effectiveAlbumArtist,
          year: ordered.map((t) => t.year).whereType<int>().firstOrNull,
          coverArtPath: ordered.where((t) => !isBlank(t.coverArtPath)).firstOrNull?.coverArtPath,
          trackCount: ordered.length,
          totalDuration: ordered.fold(Duration.zero, (sum, t) => sum + t.duration),
          tier: quality.tier,
          tagSpec: quality.spec,
          tracks: ordered,
        ),
      );
    }
    sortStable(albums, (a, b) => compareText(a.title, b.title));

    final albumsByArtist = <String, List<Album>>{};
    for (final a in albums) {
      albumsByArtist.putIfAbsent(a.artist.toLowerCase(), () => []).add(a);
    }
    final tracksByArtist = <String, List<Track>>{};
    for (final t in tracks) {
      tracksByArtist.putIfAbsent(t.artist.toLowerCase(), () => []).add(t);
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
          (a, b) => (b.year ?? -0x80000000).compareTo(a.year ?? -0x80000000),
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
          albumCount: artistAlbums.length,
          trackCount: artistTracks.length,
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
}
