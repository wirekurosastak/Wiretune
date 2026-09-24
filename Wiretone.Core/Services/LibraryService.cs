using Wiretone.Core.Models;
using Wiretone.Core.Repositories;

namespace Wiretone.Core.Services;

public class LibraryService : ILibraryService
{
    private readonly ILibraryRepository _repository;
    private readonly IMetadataScanner _scanner;
    private readonly ServerStreamingClient _streamingClient = new();
    private readonly List<Track> _tracks = new();
    private readonly List<Album> _albums = new();
    private readonly List<Artist> _artists = new();
    private readonly List<Playlist> _playlists = new();
    private readonly List<string> _genres = new();
    private readonly object _syncLock = new();

    public IReadOnlyList<Track> Tracks => _tracks;
    public IReadOnlyList<Album> Albums => _albums;
    public IReadOnlyList<Artist> Artists => _artists;
    public IReadOnlyList<Playlist> Playlists => _playlists;
    public IReadOnlyList<Track> Favorites => _tracks.Where(t => t.IsFavorite).ToList();
    public IReadOnlyList<string> Genres => _genres;

    public bool IsScanning { get; private set; }
    public string LibraryPath { get; set; } = string.Empty;
    public string ServerUrl { get; set; } = "http://localhost:5200";
    public bool IsServerConnected { get; private set; }
    public string? ServerStatusMessage { get; private set; }

    public event EventHandler? LibraryChanged;
    public event EventHandler<bool>? ScanningStateChanged;
    public event EventHandler<string?>? ServerStatusChanged;

    public LibraryService(ILibraryRepository repository, IMetadataScanner scanner)
    {
        _repository = repository;
        _scanner = scanner;
    }

    public async Task InitializeAsync(CancellationToken ct = default)
    {
        await _repository.InitializeAsync();
        LibraryPath = await _repository.GetSettingAsync("LibraryPath", string.Empty) ?? string.Empty;
        ServerUrl = await _repository.GetSettingAsync("ServerUrl", "http://localhost:5200") ?? "http://localhost:5200";

        var storedTracks = await _repository.GetAllTracksAsync();
        var storedPlaylists = await _repository.GetAllPlaylistsAsync();

        lock (_syncLock)
        {
            _tracks.Clear();
            _tracks.AddRange(storedTracks);
            _playlists.Clear();
            _playlists.AddRange(storedPlaylists);
            RebuildIndexes();
        }

        WiretoneLog.Info("LibraryService", $"Initialized with {_tracks.Count} tracks, {_albums.Count} albums, {_artists.Count} artists, {_playlists.Count} playlists. ServerUrl='{ServerUrl}'");
        LibraryChanged?.Invoke(this, EventArgs.Empty);

        // Always verify server connection if ServerUrl is configured
        if (!string.IsNullOrWhiteSpace(ServerUrl))
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await ConnectServerAsync(ServerUrl, CancellationToken.None);
                }
                catch (Exception ex)
                {
                    IsServerConnected = false;
                    ServerStatusMessage = $"A WiretoneLibrary szerver ({ServerUrl}) nem érhető el: {ex.Message}";
                    ServerStatusChanged?.Invoke(this, ServerStatusMessage);
                }
            });
        }
    }

    public async Task ScanFolderAsync(string folderPath, IProgress<ScanProgressReport>? progress = null, CancellationToken ct = default)
    {
        if (IsScanning || string.IsNullOrWhiteSpace(folderPath) || !Directory.Exists(folderPath)) return;

        try
        {
            IsScanning = true;
            ScanningStateChanged?.Invoke(this, true);

            LibraryPath = folderPath;
            await _repository.SetSettingAsync("LibraryPath", folderPath);
            WiretoneLog.Info("LibraryService", $"Starting scan of '{folderPath}'...");

            var cacheDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Wiretone",
                "Covers");

            var scanned = await _scanner.ScanDirectoryAsync(folderPath, cacheDir, progress, ct);
            WiretoneLog.Info("LibraryService", $"Scan found {scanned.Count} audio tracks.");

            if (!ct.IsCancellationRequested && scanned.Count > 0)
            {
                // Preserve favorites and play counts for matching files
                var existingMap = _tracks.ToDictionary(t => t.FilePath, t => t);
                foreach (var st in scanned)
                {
                    if (existingMap.TryGetValue(st.FilePath, out var existing))
                    {
                        st.IsFavorite = existing.IsFavorite;
                        st.PlayCount = existing.PlayCount;
                        st.LastPlayed = existing.LastPlayed;
                    }
                }

                await _repository.ClearTracksAsync();
                await _repository.SaveTracksBatchAsync(scanned);

                lock (_syncLock)
                {
                    _tracks.Clear();
                    _tracks.AddRange(scanned);
                    RebuildIndexes();
                }

                WiretoneLog.Info("LibraryService", $"Indexed {_albums.Count} albums, {_artists.Count} artists from {scanned.Count} tracks.");
                LibraryChanged?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (Exception ex)
        {
            WiretoneLog.Error("LibraryService", $"Error during scan: {ex.Message}", ex);
            throw;
        }
        finally
        {
            IsScanning = false;
            ScanningStateChanged?.Invoke(this, false);
        }
    }

    public async Task ConnectServerAsync(string serverUrl, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(serverUrl)) return;
        ServerUrl = serverUrl.TrimEnd('/');
        await _repository.SetSettingAsync("ServerUrl", ServerUrl);
        WiretoneLog.Info("LibraryService", $"Connecting to server: '{ServerUrl}'");

        try
        {
            var isOnline = await _streamingClient.PingServerAsync(ServerUrl, ct);
            IsServerConnected = isOnline;

            if (isOnline)
            {
                ServerStatusMessage = $"Csatlakozva a WiretoneLibrary szerverhez ({ServerUrl})";
                ServerStatusChanged?.Invoke(this, ServerStatusMessage);
                WiretoneLog.Info("LibraryService", $"Server '{ServerUrl}' is ONLINE. Fetching tracks...");

                var serverTracks = await _streamingClient.FetchTracksAsync(ServerUrl, ct);
                WiretoneLog.Info("LibraryService", $"Fetched {serverTracks.Count} tracks from server.");
                if (serverTracks.Count > 0)
                {
                    try
                    {
                        await _repository.ClearTracksAsync();
                        await _repository.SaveTracksBatchAsync(serverTracks);
                    }
                    catch
                    {
                        // Cache write is optional
                    }

                    lock (_syncLock)
                    {
                        _tracks.Clear();
                        _tracks.AddRange(serverTracks);
                        RebuildIndexes();
                    }
                }
                else
                {
                    // Server has 0 indexed tracks, trigger server-side scan!
                    WiretoneLog.Info("LibraryService", "Server has 0 indexed tracks, triggering remote scan...");
                    await _streamingClient.TriggerScanAsync(ServerUrl, null, ct);
                }
            }
            else
            {
                IsServerConnected = false;
                ServerStatusMessage = $"A WiretoneLibrary szerver ({ServerUrl}) nem érhető el. Ellenőrizd a szervergépet!";
                ServerStatusChanged?.Invoke(this, ServerStatusMessage);
                WiretoneLog.Warn("LibraryService", $"Server '{ServerUrl}' is OFFLINE.");
            }
        }
        catch (Exception ex)
        {
            IsServerConnected = false;
            ServerStatusMessage = $"Nem sikerült kapcsolódni a szerverhez ({ServerUrl}): {ex.Message}";
            ServerStatusChanged?.Invoke(this, ServerStatusMessage);
            WiretoneLog.Error("LibraryService", $"Failed to connect to server '{ServerUrl}': {ex.Message}", ex);
        }

        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task ToggleFavoriteAsync(string trackId)
    {
        Track? track;
        lock (_syncLock)
        {
            track = _tracks.FirstOrDefault(t => t.Id == trackId);
            if (track != null)
            {
                track.IsFavorite = !track.IsFavorite;
            }
        }

        if (track != null)
        {
            await _repository.UpdateTrackFavoriteAsync(track.Id, track.IsFavorite);
            LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task<Playlist> CreatePlaylistAsync(string name, string? description = null)
    {
        var playlist = new Playlist
        {
            Id = Guid.NewGuid().ToString("N"),
            Name = string.IsNullOrWhiteSpace(name) ? "Új lejátszási lista" : name.Trim(),
            Description = description,
            CreatedAt = DateTime.UtcNow,
            ModifiedAt = DateTime.UtcNow
        };

        lock (_syncLock)
        {
            _playlists.Add(playlist);
        }

        await _repository.SavePlaylistAsync(playlist);
        LibraryChanged?.Invoke(this, EventArgs.Empty);
        return playlist;
    }

    public async Task AddTrackToPlaylistAsync(string playlistId, string trackId)
    {
        Playlist? playlist;
        lock (_syncLock)
        {
            playlist = _playlists.FirstOrDefault(p => p.Id == playlistId);
            if (playlist != null && !playlist.TrackIds.Contains(trackId))
            {
                playlist.TrackIds.Add(trackId);
                playlist.ModifiedAt = DateTime.UtcNow;
            }
        }

        if (playlist != null)
        {
            await _repository.SavePlaylistAsync(playlist);
            LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task RemoveTrackFromPlaylistAsync(string playlistId, string trackId)
    {
        Playlist? playlist;
        lock (_syncLock)
        {
            playlist = _playlists.FirstOrDefault(p => p.Id == playlistId);
            if (playlist != null)
            {
                playlist.TrackIds.Remove(trackId);
                playlist.ModifiedAt = DateTime.UtcNow;
            }
        }

        if (playlist != null)
        {
            await _repository.SavePlaylistAsync(playlist);
            LibraryChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task DeletePlaylistAsync(string playlistId)
    {
        lock (_syncLock)
        {
            _playlists.RemoveAll(p => p.Id == playlistId);
        }

        await _repository.DeletePlaylistAsync(playlistId);
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task RecordPlayAsync(string trackId)
    {
        Track? track;
        lock (_syncLock)
        {
            track = _tracks.FirstOrDefault(t => t.Id == trackId);
            if (track != null)
            {
                track.PlayCount++;
                track.LastPlayed = DateTime.UtcNow;
            }
        }

        if (track != null)
        {
            await _repository.IncrementPlayCountAsync(track.Id);
        }
    }

    public IEnumerable<Track> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return _tracks;

        var q = query.Trim();
        return _tracks.Where(t =>
            t.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            t.Artist.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            t.Album.Contains(q, StringComparison.OrdinalIgnoreCase) ||
            (t.Genre != null && t.Genre.Contains(q, StringComparison.OrdinalIgnoreCase)));
    }

    public Album? GetAlbum(string albumId) => _albums.FirstOrDefault(a => a.Id == albumId);
    public Artist? GetArtist(string artistId) => _artists.FirstOrDefault(a => a.Id == artistId);
    public Playlist? GetPlaylist(string playlistId) => _playlists.FirstOrDefault(p => p.Id == playlistId);

    private void RebuildIndexes()
    {
        _albums.Clear();
        _artists.Clear();
        _genres.Clear();

        // Build Albums
        var albumGroups = _tracks.GroupBy(t => (t.Album, t.Artist));
        foreach (var grp in albumGroups)
        {
            var orderedTracks = grp.OrderBy(t => t.DiscNumber ?? 1)
                                   .ThenBy(t => t.TrackNumber ?? 999)
                                   .ToList();

            var first = orderedTracks[0];
            var album = new Album
            {
                Id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
                    System.Text.Encoding.UTF8.GetBytes($"{first.Album}_{first.Artist}")))[..16],
                Title = first.Album,
                Artist = first.Artist,
                Year = first.Year,
                Genre = first.Genre,
                CoverArtPath = orderedTracks.FirstOrDefault(t => !string.IsNullOrEmpty(t.CoverArtPath))?.CoverArtPath,
                TrackCount = orderedTracks.Count,
                TotalDuration = TimeSpan.FromSeconds(orderedTracks.Sum(t => t.Duration.TotalSeconds)),
                IsHiRes = orderedTracks.Any(t => t.Format.IsHiRes),
                FormatBadge = orderedTracks.Any(t => t.Format.IsHiRes)
                    ? orderedTracks.First(t => t.Format.IsHiRes).Format.DisplayBadge
                    : first.Format.DisplayBadge,
                Tracks = orderedTracks
            };
            _albums.Add(album);
        }

        // Build Artists
        var artistGroups = _tracks.GroupBy(t => t.Artist);
        foreach (var grp in artistGroups)
        {
            var artistName = grp.Key;
            var artistAlbums = _albums.Where(a => a.Artist.Equals(artistName, StringComparison.OrdinalIgnoreCase)).ToList();
            var artist = new Artist
            {
                Id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
                    System.Text.Encoding.UTF8.GetBytes(artistName)))[..16],
                Name = artistName,
                AlbumCount = artistAlbums.Count,
                TrackCount = grp.Count(),
                PicturePath = artistAlbums.FirstOrDefault(a => !string.IsNullOrEmpty(a.CoverArtPath))?.CoverArtPath,
                Albums = artistAlbums
            };
            _artists.Add(artist);
        }

        _albums.Sort((a, b) => string.Compare(a.Title, b.Title, StringComparison.CurrentCultureIgnoreCase));
        _artists.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));

        // Build Genres
        var genres = _tracks.Where(t => !string.IsNullOrWhiteSpace(t.Genre))
                            .Select(t => t.Genre!)
                            .Distinct(StringComparer.OrdinalIgnoreCase)
                            .OrderBy(g => g);
        _genres.AddRange(genres);
    }
}
