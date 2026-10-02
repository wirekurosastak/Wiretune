namespace Wiretune.Core.Models;

/// <summary>Play statistics of one track for one account.</summary>
public record TrackPlayStats(string TrackId, int PlayCount, DateTime? LastPlayed);

/// <summary>A playlist as the server stores it for one account.</summary>
public record PlaylistData(
    string Id,
    string Name,
    string? Description,
    List<string> TrackIds,
    DateTime CreatedAt,
    DateTime ModifiedAt
);

/// <summary>Body of <c>PUT /api/me/playlists/{id}</c>: the whole playlist, replacing what the server holds.</summary>
public record PlaylistUpdate(string Name, string? Description, List<string> TrackIds);

/// <summary>
/// Everything the server keeps for one account besides the account itself: favourites, play statistics and
/// playlists. Sent by <c>GET /api/me/data</c> and, for the one-time hand-over of a player's old local data, accepted by
/// <c>POST /api/me/data/import</c>.
/// </summary>
public record UserDataSnapshot(
    List<string> Favorites,
    List<TrackPlayStats> Plays,
    List<PlaylistData> Playlists
);

/// <summary>Limits the server enforces on per-account data (they also bound what one import may add).</summary>
public static class UserDataRules
{
    public const int MaxIdLength = 128;
    public const int MaxPlaylistNameLength = 200;
    public const int MaxPlaylistDescriptionLength = 1_000;
    public const int MaxPlaylistTracks = 20_000;
    public const int MaxPlaylists = 500;
    public const int MaxFavorites = 100_000;
    public const int MaxTrackStats = 100_000;

    /// <summary>Returns null when <paramref name="id"/> is acceptable as a track or playlist ID, otherwise the reason.</summary>
    public static string? ValidateId(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return "The ID must not be empty.";
        if (id.Length > MaxIdLength) return $"The ID must be at most {MaxIdLength} characters.";
        return id.Any(char.IsControl) ? "The ID must not contain control characters." : null;
    }
}
