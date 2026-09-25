using Wiretune.Core.Models;

namespace Wiretune.Core.Services;

public interface ILibraryService
{
    IReadOnlyList<Track> Tracks { get; }
    IReadOnlyList<Album> Albums { get; }
    IReadOnlyList<Artist> Artists { get; }
    IReadOnlyList<Playlist> Playlists { get; }
    IReadOnlyList<Track> Favorites { get; }
    IReadOnlyList<string> Genres { get; }

    bool IsScanning { get; }
    string LibraryPath { get; set; }
    string ServerUrl { get; set; }
    bool IsServerConnected { get; }
    string? ServerStatusMessage { get; }
    UserInfo? CurrentUser { get; }
    bool IsLoggedIn { get; }
    bool IsSetupRequired { get; }

    event EventHandler? LibraryChanged;
    event EventHandler<bool>? ScanningStateChanged;
    event EventHandler<string?>? ServerStatusChanged;
    event EventHandler<UserInfo?>? AuthStateChanged;

    Task InitializeAsync(CancellationToken ct = default);
    Task ScanFolderAsync(string folderPath, IProgress<ScanProgressReport>? progress = null, CancellationToken ct = default);
    Task ConnectServerAsync(string serverUrl, CancellationToken ct = default);
    Task<bool> LoginServerAsync(string username, string password, bool rememberMe = false, CancellationToken ct = default);
    Task<bool> SetupServerAdminAsync(string username, string password, string? displayName = null, CancellationToken ct = default);
    Task LogoutServerAsync();
    Task<bool> CheckServerSetupRequiredAsync(CancellationToken ct = default);
    Task ToggleFavoriteAsync(string trackId);
    Task<Playlist> CreatePlaylistAsync(string name, string? description = null);
    Task AddTrackToPlaylistAsync(string playlistId, string trackId);
    Task RemoveTrackFromPlaylistAsync(string playlistId, string trackId);
    Task DeletePlaylistAsync(string playlistId);
    Task RecordPlayAsync(string trackId);
    IEnumerable<Track> Search(string query);
    Album? GetAlbum(string albumId);
    Artist? GetArtist(string artistId);
    Playlist? GetPlaylist(string playlistId);
}
