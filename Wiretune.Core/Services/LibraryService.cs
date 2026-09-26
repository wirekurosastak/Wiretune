using System.Security.Cryptography;
using System.Text;
using Wiretune.Core.Models;
using Wiretune.Core.Repositories;

namespace Wiretune.Core.Services;

public class LibraryService : ILibraryService
{
    private readonly ILibraryRepository _repository;
    private readonly IMetadataScanner _scanner;
    private readonly string _coverCacheDirectory;
    private readonly object _playlistLock = new();
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private volatile LibrarySnapshot _snapshot = LibrarySnapshot.Empty;
    private volatile IReadOnlyList<Playlist> _playlists = Array.Empty<Playlist>();
    private volatile bool _isScanning;

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

    public LibraryService(ILibraryRepository repository, IMetadataScanner scanner, string? coverCacheDirectory = null)
    {
        _repository = repository;
        _scanner = scanner;
        _coverCacheDirectory = coverCacheDirectory ?? Path.Combine(AppPaths.GetDataDirectory(), "Covers");
    }

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
            await ReplaceTracksCoreAsync(scanned);
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

    public Task ReplaceTracksAsync(IEnumerable<Track> tracks, CancellationToken ct = default) =>
        ReplaceTracksCoreAsync(tracks.ToList());

    private async Task ReplaceTracksCoreAsync(List<Track> tracks)
    {
        var previous = _snapshot.TrackById;
        foreach (var track in tracks)
        {
            if (previous.TryGetValue(track.Id, out var old) && !ReferenceEquals(old, track))
            {
                track.IsFavorite = old.IsFavorite;
                track.PlayCount = old.PlayCount;
                track.LastPlayed = old.LastPlayed;
                track.DateAdded = old.DateAdded;
            }
        }

        await _repository.ReplaceAllTracksAsync(tracks);
        _snapshot = LibrarySnapshot.Build(tracks);
        LibraryChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task ToggleFavoriteAsync(string trackId)
    {
        var track = GetTrack(trackId);
        if (track == null) return;

        track.IsFavorite = !track.IsFavorite;
        await _repository.UpdateTrackFavoriteAsync(track.Id, track.IsFavorite);
        FavoriteChanged?.Invoke(this, track);
    }

    public async Task RecordPlayAsync(string trackId)
    {
        var track = GetTrack(trackId);
        if (track == null) return;

        track.PlayCount++;
        track.LastPlayed = DateTime.UtcNow;
        await _repository.IncrementPlayCountAsync(track.Id);
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

        await _repository.SavePlaylistAsync(playlist);
        lock (_playlistLock)
        {
            _playlists = _playlists.Append(playlist)
                .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }

        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
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
            var updated = playlist == null ? null : change(playlist.TrackIds);
            if (updated == null) return;

            playlist!.TrackIds = updated;
            playlist.ModifiedAt = DateTime.UtcNow;
        }

        await _repository.SavePlaylistAsync(playlist);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task DeletePlaylistAsync(string playlistId)
    {
        lock (_playlistLock)
        {
            if (_playlists.All(p => p.Id != playlistId)) return;
            _playlists = _playlists.Where(p => p.Id != playlistId).ToList();
        }

        await _repository.DeletePlaylistAsync(playlistId);
        PlaylistsChanged?.Invoke(this, EventArgs.Empty);
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

    public Artist? GetArtistByName(string name) =>
        _snapshot.Artists.FirstOrDefault(a => a.Name.Equals(name?.Trim(), StringComparison.OrdinalIgnoreCase));

    public Playlist? GetPlaylist(string playlistId) =>
        _playlists.FirstOrDefault(p => p.Id == playlistId);

    public IReadOnlyList<Track> GetPlaylistTracks(Playlist playlist)
    {
        var byId = _snapshot.TrackById;
        return playlist.TrackIds
            .Select(id => byId.GetValueOrDefault(id))
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

        public static string AlbumIdFor(Track track) =>
            StableId($"{track.Album.ToUpperInvariant()}\u001f{track.EffectiveAlbumArtist.ToUpperInvariant()}");

        private static string StableId(string key) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..16];

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
                        IsHiRes = hiRes != null,
                        FormatBadge = (hiRes ?? first).Format.DisplayBadge,
                        Tracks = ordered
                    };
                })
                .OrderBy(a => a.Title, StringComparer.CurrentCultureIgnoreCase)
                .ToList();

            var albumsByArtist = albums.ToLookup(a => a.Artist, StringComparer.OrdinalIgnoreCase);
            var tracksByArtist = tracks.ToLookup(t => t.Artist, StringComparer.OrdinalIgnoreCase);
            var artistNames = tracks.Select(t => t.Artist)
                .Concat(albums.Select(a => a.Artist))
                .Distinct(StringComparer.OrdinalIgnoreCase);

            var artists = artistNames
                .Select(name =>
                {
                    var artistAlbums = albumsByArtist[name].ToList();
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
