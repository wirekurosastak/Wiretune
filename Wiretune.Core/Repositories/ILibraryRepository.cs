using Wiretune.Core.Models;

namespace Wiretune.Core.Repositories;

public interface ILibraryRepository
{
    Task InitializeAsync();
    Task<List<Track>> GetAllTracksAsync();

    /// <summary>Atomically replaces every stored track with <paramref name="tracks"/>.</summary>
    Task ReplaceAllTracksAsync(IEnumerable<Track> tracks);

    Task UpdateTrackFavoriteAsync(string trackId, bool isFavorite);
    Task IncrementPlayCountAsync(string trackId);
    Task<List<Playlist>> GetAllPlaylistsAsync();
    Task SavePlaylistAsync(Playlist playlist);
    Task DeletePlaylistAsync(string playlistId);
    Task<string?> GetSettingAsync(string key, string? defaultValue = null);
    Task SetSettingAsync(string key, string value);
}
