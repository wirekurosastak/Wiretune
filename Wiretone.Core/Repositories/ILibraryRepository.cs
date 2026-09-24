using Wiretone.Core.Models;

namespace Wiretone.Core.Repositories;

public interface ILibraryRepository
{
    Task InitializeAsync();
    Task<List<Track>> GetAllTracksAsync();
    Task SaveTracksBatchAsync(IEnumerable<Track> tracks);
    Task ClearTracksAsync();
    Task UpdateTrackFavoriteAsync(string trackId, bool isFavorite);
    Task IncrementPlayCountAsync(string trackId);
    Task<List<Playlist>> GetAllPlaylistsAsync();
    Task SavePlaylistAsync(Playlist playlist);
    Task DeletePlaylistAsync(string playlistId);
    Task<string?> GetSettingAsync(string key, string? defaultValue = null);
    Task SetSettingAsync(string key, string value);
}
