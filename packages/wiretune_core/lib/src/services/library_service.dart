import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/library_repository.dart';
import '../localization/localizer.dart';
import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../models/protocol.dart';
import '../util/async_lock.dart';
import '../util/cancellation.dart';
import '../util/dotnet_format.dart';
import '../util/event.dart';
import '../util/sorting.dart';
import '../util/text.dart';
import 'app_paths.dart';
import 'metadata_scanner.dart';
import 'track_deduplication.dart';
import 'wiretune_log.dart';

/// Where the favourites, play counts and playlists of server tracks are kept.
enum UserDataMode {
  /// On this device only: no server, or a server that predates per-account data.
  local,

  /// On the signed-in server account. Changes are saved here and sent to the server.
  server,

  /// On a server account that cannot be reached right now. Server tracks and their playlists cannot be changed.
  serverUnavailable,
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

  // Server track ID -> ID of the local file it was folded into (see TrackDeduplication); server playlists and the
  // server's favourites still refer to the server ID.
  Map<String, String> _serverAliases = const {};

  List<Track> get tracks => _snapshot.tracks;
  List<Album> get albums => _snapshot.albums;
  List<Artist> get artists => _snapshot.artists;
  List<String> get genres => _snapshot.genres;
  List<Playlist> get playlists => _playlists;
  List<Track> get favorites => _snapshot.tracks.where((t) => t.isFavorite).toList();

  bool get isScanning => _isScanning;
  String libraryPath = '';

  final Event<void> libraryChanged = Event<void>();
  final Event<void> playlistsChanged = Event<void>();
  final Event<Track> favoriteChanged = Event<Track>();
  final Event<bool> scanningStateChanged = Event<bool>();

  // The next four are raised only for changes the user made to data that lives on the server; the server session
  // listens and sends them on. favoriteChanged and playlistsChanged stay the "something changed, redraw" events.
  final Event<Track> favoriteToggled = Event<Track>();
  final Event<Track> playRecorded = Event<Track>();
  final Event<Playlist> playlistEdited = Event<Playlist>();
  final Event<String> playlistRemoved = Event<String>();

  /// Set by the server session; decides whether changes to server tracks are kept locally or on the server.
  UserDataMode userDataMode = UserDataMode.local;

  /// Reads a small persisted user preference (interface language, theme); null when it was never set.
  Future<String?> getPreference(String name) => _repository.getSetting('Preference.$name');

  Future<void> setPreference(String name, String value) => _repository.setSetting('Preference.$name', value);

  Future<void> initialize() async {
    await _repository.initialize();
    libraryPath = await _repository.getSetting('LibraryPath', '') ?? '';

    final storedTracks = await _repository.getAllTracks();
    final storedPlaylists = await _repository.getAllPlaylists();

    _snapshot = LibrarySnapshot.build(storedTracks);
    _playlists = _sortedPlaylists(storedPlaylists);

    WiretuneLog.info(
      'LibraryService',
      'Initialized with ${tracks.length} tracks, ${albums.length} albums, ${artists.length} artists, ${playlists.length} playlists.',
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
        for (final t in _snapshot.tracks) {
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
        await _repository.setSetting('LibraryPath', root);

        await _commitGate.synchronized(() async {
          final existingServerTracks = _snapshot.tracks.where((t) => !t.isLocal).toList();
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

  /// Replaces the server part of the library. With [userData] the signed-in account's favourites, play counts and
  /// playlists from the server win over whatever this device cached; without it the cached values stay.
  Future<void> mergeServerTracks(Iterable<Track> serverTracks, [UserDataSnapshot? userData]) async {
    final incomingServer = serverTracks.toList();
    if (userData != null) _applyUserData(incomingServer, userData);

    await _commitGate.synchronized(() async {
      final existingLocalTracks = _snapshot.tracks.where((t) => t.isLocal).toList();

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

      if (userData != null) await _replaceServerPlaylists(userData.playlists);
      await _replaceTracksCore(merged, serverOwnsUserData: userData != null);
    });
  }

  /// Drops the server's tracks and the cached copies of its playlists (sign-out); local tracks and playlists stay.
  Future<void> removeServerTracks() async {
    await _commitGate.synchronized(() async {
      final existingLocalTracks = _snapshot.tracks.where((t) => t.isLocal).toList();
      _serverAliases = const {};
      if (_playlists.any((p) => p.isServer)) await _replaceServerPlaylists(const []);
      await _replaceTracksCore(existingLocalTracks);
    });
  }

  /// Copies the account's favourites and play statistics onto the freshly downloaded server tracks.
  static void _applyUserData(Iterable<Track> serverTracks, UserDataSnapshot data) {
    final favorites = data.favorites.toSet();
    final plays = {for (final stats in data.plays) stats.trackId: stats};
    for (final track in serverTracks) {
      track.isFavorite = favorites.contains(track.id);
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

    final serverIds = fromServer.map((pl) => pl.id).toSet();
    // A local playlist handed over to the server (same ID) is replaced by the server's copy.
    _playlists = _sortedPlaylists([
      ..._playlists.where((pl) => !pl.isServer && !serverIds.contains(pl.id)),
      ...fromServer,
    ]);
    playlistsChanged.emit(null);
  }

  /// What this device holds for server tracks (favourites, play counts, playlists made while signed out), in the form
  /// the server stores it; null when there is nothing. Used once per account to hand old local data over to the server.
  UserDataSnapshot? collectServerTrackUserData() {
    final serverTracks = _snapshot.tracks.where((t) => !t.isLocal).toList();
    final serverIds = serverTracks.map((t) => t.id).toSet();

    // The server turns down a whole import when one entry breaks its rules (UserDataRules), so only what it accepts is
    // sent: valid IDs, names and descriptions cut to their limits, and no more than an account may hold.
    final favorites = serverTracks
        .where((t) => t.isFavorite && UserDataRules.validateId(t.id) == null)
        .map((t) => t.id)
        .take(UserDataRules.maxFavorites)
        .toList();
    final plays = serverTracks
        .where((t) => t.playCount > 0 && UserDataRules.validateId(t.id) == null)
        .map((t) => TrackPlayStats(t.id, t.playCount, t.lastPlayed))
        .take(UserDataRules.maxTrackStats)
        .toList();
    final playlists = _playlists
        .where((pl) => !pl.isServer && pl.trackIds.any(serverIds.contains))
        .map(_forImport)
        .whereType<PlaylistData>()
        .take(UserDataRules.maxPlaylists)
        .toList();

    return favorites.length + plays.length + playlists.length == 0
        ? null
        : UserDataSnapshot(favorites, plays, playlists);
  }

  /// The playlist as the server accepts it, or null when it cannot be stored there at all (no name, unusable ID).
  static PlaylistData? _forImport(Playlist playlist) {
    if (UserDataRules.validateId(playlist.id) != null || isBlank(playlist.name)) return null;
    final name = playlist.name.trim();
    final description = playlist.description?.trim();
    return PlaylistData(
      playlist.id,
      name.length > UserDataRules.maxPlaylistNameLength ? name.substring(0, UserDataRules.maxPlaylistNameLength) : name,
      description != null && description.length > UserDataRules.maxPlaylistDescriptionLength
          ? description.substring(0, UserDataRules.maxPlaylistDescriptionLength)
          : description,
      playlist.trackIds
          .where((id) => UserDataRules.validateId(id) == null)
          .take(UserDataRules.maxPlaylistTracks)
          .toList(),
      playlist.createdAt,
      playlist.modifiedAt,
    );
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
    final previous = _snapshot.trackById;
    for (final track in tracks) {
      final old = previous[track.id];
      if (old != null && !identical(old, track)) {
        if (!(serverOwnsUserData && !track.isLocal)) {
          track.isFavorite = old.isFavorite;
          track.playCount = old.playCount;
          track.lastPlayed = old.lastPlayed;
        }
        track.dateAdded = old.dateAdded;
        track.isPlaying = old.isPlaying; // the list keeps highlighting the track that is still playing
      }
    }

    await _repository.replaceAllTracks(tracks);
    _snapshot = LibrarySnapshot.build(tracks);
    libraryChanged.emit(null);
  }

  /// False while the favourites, play count and playlists of this track live on a server that cannot be reached.
  bool _canChangeUserData(Track track) => track.isLocal || userDataMode != UserDataMode.serverUnavailable;

  Future<void> toggleFavorite(String trackId) async {
    final track = getTrack(trackId);
    if (track == null || !_canChangeUserData(track)) return;

    track.isFavorite = !track.isFavorite;
    await _repository.updateTrackFavorite(track.id, track.isFavorite);
    favoriteChanged.emit(track);
    if (!track.isLocal && userDataMode == UserDataMode.server) favoriteToggled.emit(track);
  }

  /// Sets a favourite without telling the server, e.g. to undo a change the server did not take.
  Future<void> setFavorite(String trackId, bool isFavorite) async {
    final track = getTrack(trackId);
    if (track == null || track.isFavorite == isFavorite) return;

    track.isFavorite = isFavorite;
    await _repository.updateTrackFavorite(track.id, track.isFavorite);
    favoriteChanged.emit(track);
  }

  Future<void> recordPlay(String trackId) async {
    final track = getTrack(trackId);
    if (track == null || !_canChangeUserData(track)) return;

    track.playCount++;
    track.lastPlayed = DateTime.now().toUtc();
    await _repository.incrementPlayCount(track.id);
    if (!track.isLocal && userDataMode == UserDataMode.server) playRecorded.emit(track);
  }

  Future<Playlist> createPlaylist(String name, [String? description]) async {
    final playlist = Playlist(
      id: newId(),
      name: isBlank(name) ? Localizer.get('PlaylistNew') : name.trim(),
      description: description,
      isServer: userDataMode == UserDataMode.server,
    );

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
    if (playlist == null || !_canChangePlaylist(playlist)) return;
    final updated = change(playlist.trackIds);
    if (updated == null) return;

    playlist.trackIds = updated;
    playlist.modifiedAt = DateTime.now().toUtc();
    await _repository.savePlaylist(playlist);
    playlistsChanged.emit(null);
    if (playlist.isServer && userDataMode == UserDataMode.server) playlistEdited.emit(playlist);
  }

  /// A playlist of the server account cannot be changed while the server cannot be reached.
  bool _canChangePlaylist(Playlist playlist) => !playlist.isServer || userDataMode != UserDataMode.serverUnavailable;

  Future<void> renamePlaylist(String playlistId, String newName) async {
    if (isBlank(newName)) return;
    final playlist = getPlaylist(playlistId);
    if (playlist == null || !_canChangePlaylist(playlist)) return;
    playlist.name = newName.trim();
    playlist.modifiedAt = DateTime.now().toUtc();

    await _repository.savePlaylist(playlist);
    _playlists = _sortedPlaylists(_playlists);
    playlistsChanged.emit(null);
    if (playlist.isServer && userDataMode == UserDataMode.server) playlistEdited.emit(playlist);
  }

  Future<void> deletePlaylist(String playlistId) async {
    final removed = getPlaylist(playlistId);
    if (removed == null || !_canChangePlaylist(removed)) return;
    _playlists = _playlists.where((pl) => pl.id != playlistId).toList();

    await _repository.deletePlaylist(playlistId);
    playlistsChanged.emit(null);
    if (removed.isServer && userDataMode == UserDataMode.server) playlistRemoved.emit(playlistId);
  }

  /// Tracks whose title, artist, album, album artist or genre contain [query] (ignoring case).
  Iterable<Track> search(String query) {
    final all = _snapshot.tracks;
    if (isBlank(query)) return all;
    final q = query.trim().toLowerCase();
    bool has(String? text) => text != null && text.toLowerCase().contains(q);
    return all.where((t) => has(t.title) || has(t.artist) || has(t.album) || has(t.albumArtist) || has(t.genre));
  }

  Track? getTrack(String trackId) => _snapshot.trackById[trackId];

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
      id: stableId(toUpperInvariant(trimmed)),
      name: trimmed,
      trackCount: matchingTracks.length,
      albumCount: 0,
      tracks: matchingTracks,
    );
  }

  Playlist? getPlaylist(String playlistId) => _playlists.where((pl) => pl.id == playlistId).firstOrNull;

  List<Track> getPlaylistTracks(Playlist playlist) {
    final byId = _snapshot.trackById;
    final aliases = _serverAliases;
    return [for (final id in playlist.trackIds) ?(byId[id] ?? byId[aliases[id]])];
  }
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

  static String _directoryOf(String filePath) {
    if (!filePath.contains('/') && !filePath.contains('\\')) return ''; // "server:{id}" has no folder
    return toLowerInvariant(p.dirname(filePath));
  }

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

    final groups = <String, List<Track>>{};
    for (final t in tracks) {
      if (isBlank(t.album) || t.filePath.trim().isEmpty) continue;
      if (equalsIgnoreCase(t.album, MetadataScanner.unknownAlbum) || equalsIgnoreCase(t.album, 'Unknown Album')) {
        continue;
      }
      final dir = _directoryOf(t.filePath);
      if (dir.isEmpty) continue;
      groups.putIfAbsent('${t.album.trim()}\u0000$dir', () => []).add(t);
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
      final formats = ordered.map((t) => t.format).toList();
      final quality = QualitySummary.of(formats)!; // an album always has at least one track
      albums.add(
        Album(
          id: entry.key,
          title: first.album,
          artist: first.effectiveAlbumArtist,
          year: ordered.map((t) => t.year).whereType<int>().firstOrNull,
          genre: ordered.map((t) => t.genre).where((g) => !isBlank(g)).firstOrNull,
          coverArtPath: ordered.where((t) => !isBlank(t.coverArtPath)).firstOrNull?.coverArtPath,
          trackCount: ordered.length,
          totalDuration: ordered.fold(Duration.zero, (sum, t) => sum + t.duration),
          isHiRes: formats.any((f) => f.isHiRes),
          formatBadge: quality.isMixed ? 'MIXED HQ' : formats.first.displayBadge,
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
          id: stableId(toUpperInvariant(name)),
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
