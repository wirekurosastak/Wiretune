using Wiretune.Core.Models;
using Wiretune.Core.Data;
using Wiretune.Core.Localization;

namespace Wiretune.Core.Services;

/// <summary>Where the favourites, play counts and playlists of server tracks are kept.</summary>
public enum UserDataMode
{
    /// <summary>On this device only: no server, or a server that predates per-account data.</summary>
    Local,

    /// <summary>On the signed-in server account. Changes are saved here and sent to the server.</summary>
    Server,

    /// <summary>On a server account that cannot be reached right now. Server tracks and their playlists cannot be changed.</summary>
    ServerUnavailable
}

public class LibraryService
{
    private readonly LibraryRepository _repository;
    private readonly MetadataScanner _scanner;
    private readonly string _coverCacheDirectory;
    private readonly object _playlistLock = new();
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    // Local scans and server merges each read the snapshot, combine it with new data and replace it; one at a time,
    // so neither can overwrite the other's result with a stale view.
    private readonly SemaphoreSlim _commitGate = new(1, 1);
    private volatile LibrarySnapshot _snapshot = LibrarySnapshot.Empty;
    private volatile IReadOnlyList<Playlist> _playlists = Array.Empty<Playlist>();
    private volatile bool _isScanning;
    // Server track ID -> ID of the local file it was folded into (see TrackDeduplication); server playlists and the
    // server's favourites still refer to the server ID.
    private volatile IReadOnlyDictionary<string, string> _serverAliases = new Dictionary<string, string>();

    public IReadOnlyList<Track> Tracks => _snapshot.Tracks;
    public IReadOnlyList<Album> Albums => _snapshot.Albums;
    public IReadOnlyList<Artist> Artists => _snapshot.Artists;
    public IReadOnlyList<string> Genres => _snapshot.Genres;
    public IReadOnlyList<Playlist> Playlists => _playlists;
    public IReadOnlyList<Track> Favorites => _snapshot.Tracks.Where(t => t.IsFavorite).ToList();

    public bool IsScanning => _isScanning;
    public string LibraryPath { get; private set; } = string.Empty;

    public event EventHandler? LibraryChanged;
    public event EventHandler? PlaylistsChanged;
    public event EventHandler<Track>? FavoriteChanged;
    public event EventHandler<bool>? ScanningStateChanged;

    // The next four are raised only for changes the user made to data that lives on the server; the server session
    // listens and sends them on. FavoriteChanged and PlaylistsChanged stay the "something changed, redraw" events.
    public event EventHandler<Track>? FavoriteToggled;
    public event EventHandler<Track>? PlayRecorded;
    public event EventHandler<Playlist>? PlaylistEdited;
    public event EventHandler<string>? PlaylistRemoved;

    /// <summary>Set by <see cref="ServerSession"/>; decides whether changes to server tracks are kept locally or on the server.</summary>
    public UserDataMode UserDataMode { get; set; } = UserDataMode.Local;

    public LibraryService(LibraryRepository repository, MetadataScanner scanner, string? coverCacheDirectory = null)
    {
        _repository = repository;
        _scanner = scanner;
        _coverCacheDirectory = coverCacheDirectory ?? Path.Combine(AppPaths.GetDataDirectory(), "Covers");
    }

    /// <summary>Reads a small persisted user preference (interface language, theme); null when it was never set.</summary>
    public Task<string?> GetPreferenceAsync(string name) => _repository.GetSettingAsync("Preference." + name);

    public Task SetPreferenceAsync(string name, string value) => _repository.SetSettingAsync("Preference." + name, value);

    public async Task InitializeAsync(CancellationToken ct = default)
    {
        await _repository.InitializeAsync();
        LibraryPath = await _repository.GetSettingAsync("LibraryPath", string.Empty) ?? string.Empty;

        var storedTracks = await _repository.GetAllTracksAsync();
        var storedPlaylists = await _repository.GetAllPlaylistsAsync();

        _snapshot = LibrarySnapshot.Build(storedTracks);
        _playlists = storedPlaylists.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

        WiretuneLog.Info("LibraryService", $"Initialized with {Tracks.Count} tracks, {Albums.Count} albums, {Artists.Count} artists, {Playlists.Count} playlists.");
        LibraryChanged?.Invoke(this, EventArgs.Empty);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task<bool> ScanFolderAsync(string folderPath, IProgress<ScanProgressReport>? progress = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || !Directory.Exists(folderPath)) return false;
        if (!await _scanGate.WaitAsync(0, CancellationToken.None)) return false;

        try
        {
            _isScanning = true;
            ScanningStateChanged?.Invoke(this, true);

            var root = Path.GetFullPath(folderPath);
            WiretuneLog.Info("LibraryService", $"Scanning '{root}'...");

            var known = _snapshot.Tracks
                .Where(t => !string.IsNullOrEmpty(t.FilePath))
                .GroupBy(t => t.FilePath, StringComparer.Ordinal)
                .ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);

            List<Track> scanned;
            try
            {
                scanned = await _scanner.ScanDirectoryAsync(root, _coverCacheDirectory, progress, ct, known);
            }
            catch (OperationCanceledException)
            {
                WiretuneLog.Info("LibraryService", "Scan cancelled; library left unchanged.");
                return false;
            }

            if (ct.IsCancellationRequested) return false;

            LibraryPath = root;
            await _repository.SetSettingAsync("LibraryPath", root);

            await _commitGate.WaitAsync(CancellationToken.None);
            try
            {
                var existingServerTracks = _snapshot.Tracks.Where(t => !string.IsNullOrEmpty(t.StreamUrl)).ToList();
                List<Track> toSave;
                if (existingServerTracks.Count > 0)
                {
                    toSave = TrackDeduplication.MergeTracks(scanned, existingServerTracks, out var aliased);
                    _serverAliases = aliased;
                    await UpdatePlaylistsWithAliasesAsync(aliased);
                }
                else
                {
                    toSave = scanned;
                }

                await ReplaceTracksCoreAsync(toSave);
            }
            finally
            {
                _commitGate.Release();
            }
            WiretuneLog.Info("LibraryService", $"Scan finished: {Tracks.Count} tracks, {Albums.Count} albums, {Artists.Count} artists.");
            return true;
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("LibraryService", $"Error during scan: {ex.Message}", ex);
            throw;
        }
        finally
        {
            _isScanning = false;
            _scanGate.Release();
            ScanningStateChanged?.Invoke(this, false);
        }
    }

    public async Task ReplaceTracksAsync(IEnumerable<Track> tracks, CancellationToken ct = default)
    {
        var list = tracks.ToList();
        await _commitGate.WaitAsync(CancellationToken.None);
        try
        {
            await ReplaceTracksCoreAsync(list);
        }
        finally
        {
            _commitGate.Release();
        }
    }

    public Task MergeServerTracksAsync(IEnumerable<Track> serverTracks, CancellationToken ct = default) =>
        MergeServerTracksAsync(serverTracks, null, ct);

    /// <summary>
    /// Replaces the server part of the library. With <paramref name="userData"/> the signed-in account's favourites,
    /// play counts and playlists from the server win over whatever this device cached; without it the cached values stay.
    /// </summary>
    public async Task MergeServerTracksAsync(IEnumerable<Track> serverTracks, UserDataSnapshot? userData, CancellationToken ct = default)
    {
        var incomingServer = serverTracks.ToList();
        if (userData != null) ApplyUserData(incomingServer, userData);

        await _commitGate.WaitAsync(CancellationToken.None);
        try
        {
            var existingLocalTracks = _snapshot.Tracks.Where(t => string.IsNullOrEmpty(t.StreamUrl)).ToList();

            List<Track> merged;
            if (existingLocalTracks.Count > 0)
            {
                // Favourites and play counts of a server copy move to the local file (never the other way round).
                merged = TrackDeduplication.MergeTracks(existingLocalTracks, incomingServer, out var aliased);
                _serverAliases = aliased;
                await UpdatePlaylistsWithAliasesAsync(aliased);
            }
            else
            {
                merged = incomingServer;
                _serverAliases = new Dictionary<string, string>();
            }

            if (userData != null) await ReplaceServerPlaylistsAsync(userData.Playlists);
            await ReplaceTracksCoreAsync(merged, serverOwnsUserData: userData != null);
        }
        finally
        {
            _commitGate.Release();
        }
    }

    /// <summary>Drops the server's tracks and the cached copies of its playlists (sign-out); local tracks and playlists stay.</summary>
    public async Task RemoveServerTracksAsync(CancellationToken ct = default)
    {
        await _commitGate.WaitAsync(CancellationToken.None);
        try
        {
            var existingLocalTracks = _snapshot.Tracks.Where(t => string.IsNullOrEmpty(t.StreamUrl)).ToList();
            _serverAliases = new Dictionary<string, string>();
            if (_playlists.Any(p => p.IsServer)) await ReplaceServerPlaylistsAsync(Array.Empty<PlaylistData>());
            await ReplaceTracksCoreAsync(existingLocalTracks);
        }
        finally
        {
            _commitGate.Release();
        }
    }

    /// <summary>Copies the account's favourites and play statistics onto the freshly downloaded server tracks.</summary>
    private static void ApplyUserData(IEnumerable<Track> serverTracks, UserDataSnapshot data)
    {
        var favorites = new HashSet<string>(data.Favorites, StringComparer.Ordinal);
        var plays = new Dictionary<string, TrackPlayStats>(StringComparer.Ordinal);
        foreach (var stats in data.Plays) plays[stats.TrackId] = stats;

        foreach (var track in serverTracks)
        {
            track.IsFavorite = favorites.Contains(track.Id);
            if (plays.TryGetValue(track.Id, out var stats))
            {
                track.PlayCount = stats.PlayCount;
                track.LastPlayed = stats.LastPlayed;
            }
            else
            {
                track.PlayCount = 0;
                track.LastPlayed = null;
            }
        }
    }

    /// <summary>Replaces the cached server playlists with <paramref name="playlists"/> (an empty list removes them).</summary>
    private async Task ReplaceServerPlaylistsAsync(IReadOnlyList<PlaylistData> playlists)
    {
        var fromServer = playlists
            .Select(p => new Playlist
            {
                Id = p.Id,
                Name = p.Name,
                Description = p.Description,
                TrackIds = p.TrackIds ?? new List<string>(),
                CreatedAt = p.CreatedAt,
                ModifiedAt = p.ModifiedAt,
                IsServer = true
            })
            .ToList();

        await _repository.DeleteServerPlaylistsAsync();
        foreach (var playlist in fromServer) await _repository.SavePlaylistAsync(playlist);

        var serverIds = fromServer.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
        lock (_playlistLock)
        {
            // A local playlist handed over to the server (same ID) is replaced by the server's copy.
            _playlists = _playlists
                .Where(p => !p.IsServer && !serverIds.Contains(p.Id))
                .Concat(fromServer)
                .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }

        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// What this device holds for server tracks (favourites, play counts, playlists made while signed out), in the form the
    /// server stores it; null when there is nothing. Used once per account to hand old local data over to the server.
    /// </summary>
    public UserDataSnapshot? CollectServerTrackUserData()
    {
        var serverTracks = _snapshot.Tracks.Where(t => !t.IsLocal).ToList();
        var serverIds = serverTracks.Select(t => t.Id).ToHashSet(StringComparer.Ordinal);

        // The server turns down a whole import when one entry breaks its rules (UserDataRules), so only what it accepts is
        // sent: valid IDs, names and descriptions cut to their limits, and no more than an account may hold.
        var favorites = serverTracks
            .Where(t => t.IsFavorite && UserDataRules.ValidateId(t.Id) == null)
            .Select(t => t.Id)
            .Take(UserDataRules.MaxFavorites)
            .ToList();
        var plays = serverTracks
            .Where(t => t.PlayCount > 0 && UserDataRules.ValidateId(t.Id) == null)
            .Select(t => new TrackPlayStats(t.Id, t.PlayCount, t.LastPlayed))
            .Take(UserDataRules.MaxTrackStats)
            .ToList();
        var playlists = _playlists
            .Where(p => !p.IsServer && p.TrackIds.Any(serverIds.Contains))
            .Select(ForImport)
            .OfType<PlaylistData>()
            .Take(UserDataRules.MaxPlaylists)
            .ToList();

        return favorites.Count + plays.Count + playlists.Count == 0
            ? null
            : new UserDataSnapshot(favorites, plays, playlists);
    }

    /// <summary>The playlist as the server accepts it, or null when it cannot be stored there at all (no name, unusable ID).</summary>
    private static PlaylistData? ForImport(Playlist playlist)
    {
        if (UserDataRules.ValidateId(playlist.Id) != null || string.IsNullOrWhiteSpace(playlist.Name)) return null;

        var name = playlist.Name.Trim();
        var description = playlist.Description?.Trim();
        return new PlaylistData(
            playlist.Id,
            name.Length > UserDataRules.MaxPlaylistNameLength ? name[..UserDataRules.MaxPlaylistNameLength] : name,
            description is { Length: > UserDataRules.MaxPlaylistDescriptionLength } ? description[..UserDataRules.MaxPlaylistDescriptionLength] : description,
            playlist.TrackIds.Where(id => UserDataRules.ValidateId(id) == null).Take(UserDataRules.MaxPlaylistTracks).ToList(),
            playlist.CreatedAt,
            playlist.ModifiedAt);
    }

    /// <summary>Points playlist entries at the local copy of a track that also exists on the server.</summary>
    private async Task UpdatePlaylistsWithAliasesAsync(Dictionary<string, string> aliasedTrackIds)
    {
        if (aliasedTrackIds.Count == 0) return;

        // Server playlists keep the server's IDs (other devices resolve them); GetPlaylistTracks follows the aliases.
        foreach (var playlist in _playlists.Where(p => !p.IsServer))
        {
            // Copy-on-write, like every other playlist change: readers may be enumerating TrackIds right now.
            lock (_playlistLock)
            {
                if (!playlist.TrackIds.Any(aliasedTrackIds.ContainsKey)) continue;

                playlist.TrackIds = playlist.TrackIds
                    .Select(id => aliasedTrackIds.GetValueOrDefault(id, id))
                    .Distinct()
                    .ToList();
                playlist.ModifiedAt = DateTime.UtcNow;
            }

            await _repository.SavePlaylistAsync(playlist);
        }
    }

    /// <param name="serverOwnsUserData">The server's favourites and play counts were just applied to its tracks: do not overwrite them with the cached ones.</param>
    private async Task ReplaceTracksCoreAsync(List<Track> tracks, bool serverOwnsUserData = false)
    {
        var previous = _snapshot.TrackById;
        foreach (var track in tracks)
        {
            if (previous.TryGetValue(track.Id, out var old) && !ReferenceEquals(old, track))
            {
                if (!(serverOwnsUserData && !track.IsLocal))
                {
                    track.IsFavorite = old.IsFavorite;
                    track.PlayCount = old.PlayCount;
                    track.LastPlayed = old.LastPlayed;
                }
                track.DateAdded = old.DateAdded;
                track.IsPlaying = old.IsPlaying; // the list keeps highlighting the track that is still playing
            }
        }

        await _repository.ReplaceAllTracksAsync(tracks);
        _snapshot = LibrarySnapshot.Build(tracks);
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>False while the favourites, play count and playlists of this track live on a server that cannot be reached.</summary>
    private bool CanChangeUserData(Track track) => track.IsLocal || UserDataMode != UserDataMode.ServerUnavailable;

    public async Task ToggleFavoriteAsync(string trackId)
    {
        var track = GetTrack(trackId);
        if (track == null || !CanChangeUserData(track)) return;

        track.IsFavorite = !track.IsFavorite;
        await _repository.UpdateTrackFavoriteAsync(track.Id, track.IsFavorite);
        FavoriteChanged?.Invoke(this, track);
        if (!track.IsLocal && UserDataMode == UserDataMode.Server) FavoriteToggled?.Invoke(this, track);
    }

    /// <summary>Sets a favourite without telling the server, e.g. to undo a change the server did not take.</summary>
    public async Task SetFavoriteAsync(string trackId, bool isFavorite)
    {
        var track = GetTrack(trackId);
        if (track == null || track.IsFavorite == isFavorite) return;

        track.IsFavorite = isFavorite;
        await _repository.UpdateTrackFavoriteAsync(track.Id, track.IsFavorite);
        FavoriteChanged?.Invoke(this, track);
    }

    public async Task RecordPlayAsync(string trackId)
    {
        var track = GetTrack(trackId);
        if (track == null || !CanChangeUserData(track)) return;

        track.PlayCount++;
        track.LastPlayed = DateTime.UtcNow;
        await _repository.IncrementPlayCountAsync(track.Id);
        if (!track.IsLocal && UserDataMode == UserDataMode.Server) PlayRecorded?.Invoke(this, track);
    }

    public async Task<Playlist> CreatePlaylistAsync(string name, string? description = null)
    {
        var playlist = new Playlist
        {
            Id = Guid.NewGuid().ToString("N"),
            Name = string.IsNullOrWhiteSpace(name) ? Localizer.Get("PlaylistNew") : name.Trim(),
            Description = description,
            CreatedAt = DateTime.UtcNow,
            ModifiedAt = DateTime.UtcNow,
            IsServer = UserDataMode == UserDataMode.Server
        };

        await _repository.SavePlaylistAsync(playlist);
        lock (_playlistLock)
        {
            _playlists = _playlists.Append(playlist)
                .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }

        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
        if (playlist.IsServer) PlaylistEdited?.Invoke(this, playlist);
        return playlist;
    }

    public Task AddTrackToPlaylistAsync(string playlistId, string trackId) =>
        UpdatePlaylistAsync(playlistId, ids => ids.Contains(trackId) ? null : ids.Append(trackId).ToList());

    public Task RemoveTrackFromPlaylistAsync(string playlistId, string trackId) =>
        UpdatePlaylistAsync(playlistId, ids => ids.Contains(trackId) ? ids.Where(id => id != trackId).ToList() : null);

    private async Task UpdatePlaylistAsync(string playlistId, Func<List<string>, List<string>?> change)
    {
        Playlist? playlist;
        lock (_playlistLock)
        {
            playlist = _playlists.FirstOrDefault(p => p.Id == playlistId);
            if (playlist != null && !CanChangePlaylist(playlist)) return;
            var updated = playlist == null ? null : change(playlist.TrackIds);
            if (updated == null) return;

            playlist!.TrackIds = updated;
            playlist.ModifiedAt = DateTime.UtcNow;
        }

        await _repository.SavePlaylistAsync(playlist);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
        if (playlist.IsServer && UserDataMode == UserDataMode.Server) PlaylistEdited?.Invoke(this, playlist);
    }

    /// <summary>A playlist of the server account cannot be changed while the server cannot be reached.</summary>
    private bool CanChangePlaylist(Playlist playlist) => !playlist.IsServer || UserDataMode != UserDataMode.ServerUnavailable;

    public async Task RenamePlaylistAsync(string playlistId, string newName)
    {
        if (string.IsNullOrWhiteSpace(newName)) return;
        Playlist? playlist;
        lock (_playlistLock)
        {
            playlist = _playlists.FirstOrDefault(p => p.Id == playlistId);
            if (playlist == null || !CanChangePlaylist(playlist)) return;
            playlist.Name = newName.Trim();
            playlist.ModifiedAt = DateTime.UtcNow;
        }

        await _repository.SavePlaylistAsync(playlist);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
        if (playlist.IsServer && UserDataMode == UserDataMode.Server) PlaylistEdited?.Invoke(this, playlist);
    }

    public async Task DeletePlaylistAsync(string playlistId)
    {
        Playlist? removed;
        lock (_playlistLock)
        {
            removed = _playlists.FirstOrDefault(p => p.Id == playlistId);
            if (removed == null || !CanChangePlaylist(removed)) return;
            _playlists = _playlists.Where(p => p.Id != playlistId).ToList();
        }

        await _repository.DeletePlaylistAsync(playlistId);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
        if (removed.IsServer && UserDataMode == UserDataMode.Server) PlaylistRemoved?.Invoke(this, playlistId);
    }

    public IEnumerable<Track> Search(string query)
    {
        var tracks = _snapshot.Tracks;
        if (string.IsNullOrWhiteSpace(query)) return tracks;

        var q = query.Trim();
        return tracks.Where(t =>
            t.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            t.Artist.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            t.Album.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            (t.AlbumArtist?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false) ||
            (t.Genre?.Contains(q, StringComparison.OrdinalIgnoreCase) ?? false));
    }

    public Track? GetTrack(string trackId) =>
        _snapshot.TrackById.GetValueOrDefault(trackId);

    public Album? GetAlbum(string albumId) =>
        _snapshot.Albums.FirstOrDefault(a => a.Id == albumId);

    public Album? GetAlbumForTrack(Track track) =>
        _snapshot.Albums.FirstOrDefault(a => a.Id == LibrarySnapshot.AlbumIdFor(track));

    public Artist? GetArtist(string artistId) =>
        _snapshot.Artists.FirstOrDefault(a => a.Id == artistId);

    public Artist? GetArtistByName(string name)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrWhiteSpace(trimmed)) return null;

        var existing = _snapshot.Artists.FirstOrDefault(a => a.Name.Equals(trimmed, StringComparison.OrdinalIgnoreCase));
        if (existing != null) return existing;

        var matchingTracks = _snapshot.Tracks.Where(t => t.Artist.Equals(trimmed, StringComparison.OrdinalIgnoreCase)).ToList();
        if (matchingTracks.Count == 0) return null;

        return new Artist
        {
            Id = LibrarySnapshot.StableId(trimmed.ToUpperInvariant()),
            Name = trimmed,
            TrackCount = matchingTracks.Count,
            AlbumCount = 0,
            Tracks = matchingTracks
        };
    }

    public Playlist? GetPlaylist(string playlistId) =>
        _playlists.FirstOrDefault(p => p.Id == playlistId);

    public IReadOnlyList<Track> GetPlaylistTracks(Playlist playlist)
    {
        var byId = _snapshot.TrackById;
        var aliases = _serverAliases;
        return playlist.TrackIds
            .Select(id => byId.GetValueOrDefault(id) ?? (aliases.TryGetValue(id, out var local) ? byId.GetValueOrDefault(local) : null))
            .OfType<Track>()
            .ToList();
    }

    /// <summary>Immutable view of the library; replaced wholesale so readers never need a lock or a copy.</summary>
    private sealed class LibrarySnapshot
    {
        public static readonly LibrarySnapshot Empty = Build(Array.Empty<Track>());

        public required IReadOnlyList<Track> Tracks { get; init; }
        public required IReadOnlyDictionary<string, Track> TrackById { get; init; }
        public required IReadOnlyList<Album> Albums { get; init; }
        public required IReadOnlyList<Artist> Artists { get; init; }
        public required IReadOnlyList<string> Genres { get; init; }

        public static string AlbumIdFor(Track track) => track.AlbumId;

        internal static string StableId(string key) => Track.StableId(key);

        public static LibrarySnapshot Build(IEnumerable<Track> source)
        {
            var tracks = source
                .GroupBy(t => t.Id)
                .Select(g => g.First())
                .OrderBy(t => t.Artist, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(t => t.Album, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(t => t.DiscNumber ?? 1)
                .ThenBy(t => t.TrackNumber ?? int.MaxValue)
                .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            // Consolidate multi-artist albums where explicit AlbumArtist tag is missing or incomplete.
            // Only apply when tracks share a non-empty directory on disk and do not have colliding track numbers.
            // What is inferred here is kept apart from what the tags say (AlbumArtistInferred), recomputed on every
            // build and never stored, so a value inferred from an earlier set of files cannot outlive them.
            static string? Tagged(Track t) => t.AlbumArtistInferred ? null : t.AlbumArtist;
            var inferred = new Dictionary<Track, string>();

            var multiArtistGroups = tracks
                .Where(t => !string.IsNullOrWhiteSpace(t.Album) &&
                            !string.IsNullOrWhiteSpace(t.FilePath) &&
                            !t.Album.Equals(MetadataScanner.UnknownAlbum, StringComparison.OrdinalIgnoreCase) &&
                            !t.Album.Equals("Unknown Album", StringComparison.OrdinalIgnoreCase))
                .GroupBy(t => (
                    Album: t.Album.Trim(),
                    Dir: Path.GetDirectoryName(t.FilePath)?.ToLowerInvariant() ?? string.Empty
                ))
                .Where(g => !string.IsNullOrEmpty(g.Key.Dir));

            foreach (var group in multiArtistGroups)
            {
                var groupTracks = group.ToList();
                if (groupTracks.Count < 2) continue;

                // Don't merge if distinct tracks collide on (Disc, TrackNumber) where TrackNumber > 0
                bool hasTrackNumberCollisions = groupTracks
                    .Where(t => t.TrackNumber.HasValue && t.TrackNumber > 0)
                    .GroupBy(t => (t.DiscNumber ?? 1, t.TrackNumber!.Value))
                    .Any(tg => tg.Count() > 1);

                if (hasTrackNumberCollisions) continue;

                var explicitAlbumArtist = groupTracks.Select(Tagged).FirstOrDefault(a => !string.IsNullOrWhiteSpace(a));
                if (!string.IsNullOrWhiteSpace(explicitAlbumArtist))
                {
                    foreach (var t in groupTracks.Where(t => string.IsNullOrWhiteSpace(Tagged(t))))
                    {
                        inferred[t] = explicitAlbumArtist;
                    }
                    continue;
                }

                var distinctArtists = groupTracks.Select(t => t.Artist).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                if (distinctArtists.Count > 1)
                {
                    var topGroup = groupTracks.GroupBy(t => t.Artist, StringComparer.OrdinalIgnoreCase)
                        .OrderByDescending(g => g.Count())
                        .First();

                    var resolvedArtist = (topGroup.Count() * 2 > groupTracks.Count)
                        ? topGroup.Key
                        : "Various Artists";

                    foreach (var t in groupTracks)
                    {
                        inferred[t] = resolvedArtist;
                    }
                }
            }

            foreach (var t in tracks)
            {
                if (inferred.TryGetValue(t, out var value))
                {
                    t.AlbumArtist = value;
                    t.AlbumArtistInferred = true;
                }
                else if (t.AlbumArtistInferred)
                {
                    // The files this was inferred from changed: back to what the tag says.
                    t.AlbumArtist = null;
                    t.AlbumArtistInferred = false;
                }
            }

            var albums = tracks
                .GroupBy(AlbumIdFor)
                .Select(g =>
                {
                    var ordered = g.OrderBy(t => t.DiscNumber ?? 1)
                        .ThenBy(t => t.TrackNumber ?? int.MaxValue)
                        .ThenBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase)
                        .ToList();
                    var first = ordered[0];
                    var hiRes = ordered.FirstOrDefault(t => t.Format.IsHiRes);

                    var formats = ordered.Select(t => t.Format).ToList();
                    var hasHiRes = formats.Any(f => f.IsHiRes);
                    var quality = QualitySummary.Of(formats)!; // an album always has at least one track
                    var badge = quality.IsMixed ? "MIXED HQ" : formats[0].DisplayBadge;

                    return new Album
                    {
                        Id = g.Key,
                        Title = first.Album,
                        Artist = first.EffectiveAlbumArtist,
                        Year = ordered.Select(t => t.Year).FirstOrDefault(y => y.HasValue),
                        Genre = ordered.Select(t => t.Genre).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)),
                        CoverArtPath = ordered.FirstOrDefault(t => !string.IsNullOrEmpty(t.CoverArtPath))?.CoverArtPath,
                        TrackCount = ordered.Count,
                        TotalDuration = TimeSpan.FromSeconds(ordered.Sum(t => t.Duration.TotalSeconds)),
                        IsHiRes = hasHiRes,
                        FormatBadge = badge,
                        Tier = quality.Tier,
                        TagSpec = quality.Spec,
                        Tracks = ordered
                    };
                })
                .OrderBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            var albumsByArtist = albums.ToLookup(a => a.Artist, StringComparer.OrdinalIgnoreCase);
            var tracksByArtist = tracks.ToLookup(t => t.Artist, StringComparer.OrdinalIgnoreCase);

            // In the Artists view, only show primary Album Artists (who have an album/release).
            // Guest performers and one-off compilation artists do not pollute the main Artists tab.
            var artistNames = albums.Select(a => a.Artist).Distinct(StringComparer.OrdinalIgnoreCase);

            var artists = artistNames
                .Select(name =>
                {
                    var artistAlbums = albumsByArtist[name]
                        .OrderByDescending(a => a.Year ?? int.MinValue)
                        .ThenBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
                        .ToList();
                    var artistTracks = artistAlbums.SelectMany(a => a.Tracks)
                        .Concat(tracksByArtist[name])
                        .DistinctBy(t => t.Id)
                        .OrderBy(t => t.Album, StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(t => t.DiscNumber ?? 1)
                        .ThenBy(t => t.TrackNumber ?? int.MaxValue)
                        .ToList();
                    return new Artist
                    {
                        Id = StableId(name.ToUpperInvariant()),
                        Name = name,
                        AlbumCount = artistAlbums.Count,
                        TrackCount = artistTracks.Count,
                        PicturePath = artistAlbums.FirstOrDefault(a => !string.IsNullOrEmpty(a.CoverArtPath))?.CoverArtPath,
                        Albums = artistAlbums,
                        Tracks = artistTracks
                    };
                })
                .OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            var genres = tracks.Where(t => !string.IsNullOrWhiteSpace(t.Genre))
                .Select(t => t.Genre!)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(g => g, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            return new LibrarySnapshot
            {
                Tracks = tracks,
                TrackById = tracks.ToDictionary(t => t.Id),
                Albums = albums,
                Artists = artists,
                Genres = genres
            };
        }
    }
}
