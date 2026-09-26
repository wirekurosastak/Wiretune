using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

/// <summary>
/// In-memory music library (tracks, derived albums/artists/genres, favorites, playlists) backed by
/// an <see cref="Repositories.ILibraryRepository"/>. Shared by the server and the clients; it has no
/// knowledge of networking.
/// </summary>
public interface ILibraryService
{
    IReadOnlyList<Track> Tracks { get; }
    IReadOnlyList<Album> Albums { get; }
    IReadOnlyList<Artist> Artists { get; }
    IReadOnlyList<Playlist> Playlists { get; }
    IReadOnlyList<Track> Favorites { get; }
    IReadOnlyList<string> Genres { get; }

    bool IsScanning { get; }
    string LibraryPath { get; }

    /// <summary>The set of tracks (and therefore albums/artists/genres) changed.</summary>
    event EventHandler? LibraryChanged;
    event EventHandler? PlaylistsChanged;
    event EventHandler<Track>? FavoriteChanged;
    event EventHandler<bool>? ScanningStateChanged;

    Task InitializeAsync(CancellationToken ct = default);

    /// <summary>Scans a folder and replaces the library with its contents. Returns false if a scan was already running or the folder does not exist.</summary>
    Task<bool> ScanFolderAsync(string folderPath, IProgress<ScanProgressReport>? progress = null, CancellationToken ct = default);

    /// <summary>Replaces the library with externally provided tracks (e.g. fetched from a server), keeping favorites and play counts of tracks that remain.</summary>
    Task ReplaceTracksAsync(IEnumerable<Track> tracks, CancellationToken ct = default);

    /// <summary>Merges server tracks into the library, preserving local tracks and preferring local tracks when duplicates exist.</summary>
    Task MergeServerTracksAsync(IEnumerable<Track> serverTracks, CancellationToken ct = default);

    /// <summary>Removes all server tracks from the library, retaining only local tracks.</summary>
    Task RemoveServerTracksAsync(CancellationToken ct = default);

    Task ToggleFavoriteAsync(string trackId);
    Task RecordPlayAsync(string trackId);
    Task<Playlist> CreatePlaylistAsync(string name, string? description = null);
    Task AddTrackToPlaylistAsync(string playlistId, string trackId);
    Task RemoveTrackFromPlaylistAsync(string playlistId, string trackId);
    Task DeletePlaylistAsync(string playlistId);

    IEnumerable<Track> Search(string query);
    Track? GetTrack(string trackId);
    Album? GetAlbum(string albumId);
    Album? GetAlbumForTrack(Track track);
    Artist? GetArtist(string artistId);
    Artist? GetArtistByName(string name);
    Playlist? GetPlaylist(string playlistId);
    IReadOnlyList<Track> GetPlaylistTracks(Playlist playlist);
}
