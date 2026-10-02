using System.Data;
using System.Globalization;
using System.Text.Json;
using Dapper;
using Wiretune.Core.Data;
using Wiretune.Core.Models;

namespace Wiretune.Server;

/// <summary>
/// Favourites, play statistics and playlists of each account. They live in the server's database, next to the account
/// itself, so they follow the person to every device and survive both a restart of the server and a sign-out of a player.
/// Every method takes the account ID from the validated token; nothing here can reach another account's rows.
/// </summary>
public class UserDataService
{
    private readonly DatabaseManager _db;

    public UserDataService(DatabaseManager db)
    {
        _db = db;
        _db.InitializeSchema();
    }

    public async Task<UserDataSnapshot> GetAsync(string userId)
    {
        using var conn = _db.CreateConnection();
        return await ReadAsync(conn, userId);
    }

    /// <returns>False when the account is at its favourites limit and nothing was added.</returns>
    public async Task<bool> SetFavoriteAsync(string userId, string trackId, bool favorite)
    {
        using var conn = _db.CreateConnection();

        if (!favorite)
        {
            await conn.ExecuteAsync(
                "DELETE FROM user_favorites WHERE user_id = @userId AND track_id = @trackId",
                new { userId, trackId });
            return true;
        }

        await conn.ExecuteAsync(FavoriteInsertSql, new { userId, trackId, now = Iso(DateTime.UtcNow), max = UserDataRules.MaxFavorites });
        return await conn.ExecuteScalarAsync<long>(
            "SELECT EXISTS (SELECT 1 FROM user_favorites WHERE user_id = @userId AND track_id = @trackId)",
            new { userId, trackId }) != 0;
    }

    /// <summary>Counts one more play of a track. Returns null when the account is at its statistics limit.</summary>
    public async Task<TrackPlayStats?> RecordPlayAsync(string userId, string trackId)
    {
        using var conn = _db.CreateConnection();
        var parameters = new { userId, trackId, now = Iso(DateTime.UtcNow), max = UserDataRules.MaxTrackStats };

        // Update first: the common case is a track that already has a row, and it needs no count.
        var updated = await conn.ExecuteAsync("""
            UPDATE user_plays
            SET play_count = CASE WHEN play_count < 2147483647 THEN play_count + 1 ELSE play_count END, last_played = @now
            WHERE user_id = @userId AND track_id = @trackId
            """, parameters);

        if (updated == 0)
        {
            var inserted = await conn.ExecuteAsync("""
                INSERT OR IGNORE INTO user_plays (user_id, track_id, play_count, last_played)
                SELECT @userId, @trackId, 1, @now
                WHERE (SELECT COUNT(*) FROM user_plays WHERE user_id = @userId) < @max
                """, parameters);

            // Nothing inserted and nothing updated: either the limit is reached or another request created the row just now.
            if (inserted == 0)
            {
                updated = await conn.ExecuteAsync("""
                    UPDATE user_plays
                    SET play_count = CASE WHEN play_count < 2147483647 THEN play_count + 1 ELSE play_count END, last_played = @now
                    WHERE user_id = @userId AND track_id = @trackId
                    """, parameters);
                if (updated == 0) return null;
            }
        }

        var row = await conn.QueryFirstAsync<PlayRow>(
            "SELECT track_id, play_count, last_played FROM user_plays WHERE user_id = @userId AND track_id = @trackId",
            new { userId, trackId });
        return row.ToStats();
    }

    /// <summary>
    /// Creates the playlist or replaces its name, description and tracks. Returns null when it is new and the account is
    /// at its playlist limit. The caller has validated the input with <see cref="ValidatePlaylist"/>.
    /// </summary>
    public async Task<PlaylistData?> SavePlaylistAsync(string userId, string playlistId, PlaylistUpdate update)
    {
        using var conn = _db.CreateConnection();
        var parameters = new
        {
            userId,
            playlistId,
            name = update.Name.Trim(),
            description = string.IsNullOrWhiteSpace(update.Description) ? null : update.Description.Trim(),
            tracks = JsonSerializer.Serialize(update.TrackIds ?? new List<string>()),
            now = Iso(DateTime.UtcNow),
            max = UserDataRules.MaxPlaylists
        };

        const string updateSql = """
            UPDATE user_playlists
            SET name = @name, description = @description, track_ids_json = @tracks, modified_at = @now
            WHERE user_id = @userId AND id = @playlistId
            """;

        if (await conn.ExecuteAsync(updateSql, parameters) == 0)
        {
            var inserted = await conn.ExecuteAsync("""
                INSERT OR IGNORE INTO user_playlists (user_id, id, name, description, track_ids_json, created_at, modified_at)
                SELECT @userId, @playlistId, @name, @description, @tracks, @now, @now
                WHERE (SELECT COUNT(*) FROM user_playlists WHERE user_id = @userId) < @max
                """, parameters);

            // Not inserted and not updatable: the account is at its limit (or the row appeared in between and we retry once).
            if (inserted == 0 && await conn.ExecuteAsync(updateSql, parameters) == 0) return null;
        }

        var row = await conn.QueryFirstAsync<PlaylistRow>(
            "SELECT id, name, description, track_ids_json, created_at, modified_at FROM user_playlists WHERE user_id = @userId AND id = @playlistId",
            new { userId, playlistId });
        return row.ToData();
    }

    public async Task<bool> DeletePlaylistAsync(string userId, string playlistId)
    {
        using var conn = _db.CreateConnection();
        return await conn.ExecuteAsync(
            "DELETE FROM user_playlists WHERE user_id = @userId AND id = @playlistId",
            new { userId, playlistId }) > 0;
    }

    /// <summary>
    /// One-time hand-over of what a player stored on the device before the server kept this data. It is a union:
    /// favourites are added, play counts only ever rise, and a playlist the account already has is left as the server has it.
    /// The caller has validated the input with <see cref="ValidateImport"/>.
    /// </summary>
    public async Task<UserDataSnapshot> ImportAsync(string userId, UserDataSnapshot data)
    {
        using var conn = _db.CreateConnection();
        using (var transaction = conn.BeginTransaction())
        {
            var now = Iso(DateTime.UtcNow);

            foreach (var trackId in (data.Favorites ?? new List<string>()).Distinct(StringComparer.Ordinal))
            {
                await conn.ExecuteAsync(FavoriteInsertSql,
                    new { userId, trackId, now, max = UserDataRules.MaxFavorites }, transaction);
            }

            foreach (var stats in (data.Plays ?? new List<TrackPlayStats>()).Where(s => s.PlayCount > 0 || s.LastPlayed != null))
            {
                var parameters = new
                {
                    userId,
                    trackId = stats.TrackId,
                    playCount = Math.Max(0, stats.PlayCount),
                    lastPlayed = stats.LastPlayed == null ? null : Iso(stats.LastPlayed.Value),
                    max = UserDataRules.MaxTrackStats
                };

                // A row the account already has is raised (never lowered), also when the account is at its limit;
                // only a new row has to fit under it.
                var updated = await conn.ExecuteAsync("""
                    UPDATE user_plays
                    SET play_count = MAX(play_count, @playCount),
                        last_played = CASE
                            WHEN last_played IS NULL THEN @lastPlayed
                            WHEN @lastPlayed IS NOT NULL AND @lastPlayed > last_played THEN @lastPlayed
                            ELSE last_played END
                    WHERE user_id = @userId AND track_id = @trackId
                    """, parameters, transaction);

                if (updated == 0)
                {
                    await conn.ExecuteAsync("""
                        INSERT OR IGNORE INTO user_plays (user_id, track_id, play_count, last_played)
                        SELECT @userId, @trackId, @playCount, @lastPlayed
                        WHERE (SELECT COUNT(*) FROM user_plays WHERE user_id = @userId) < @max
                        """, parameters, transaction);
                }
            }

            foreach (var playlist in (data.Playlists ?? new List<PlaylistData>()).DistinctBy(p => p.Id, StringComparer.Ordinal))
            {
                await conn.ExecuteAsync("""
                    INSERT OR IGNORE INTO user_playlists (user_id, id, name, description, track_ids_json, created_at, modified_at)
                    SELECT @userId, @id, @name, @description, @tracks, @createdAt, @modifiedAt
                    WHERE (SELECT COUNT(*) FROM user_playlists WHERE user_id = @userId) < @max
                    """,
                    new
                    {
                        userId,
                        id = playlist.Id,
                        name = playlist.Name.Trim(),
                        description = string.IsNullOrWhiteSpace(playlist.Description) ? null : playlist.Description.Trim(),
                        tracks = JsonSerializer.Serialize(playlist.TrackIds ?? new List<string>()),
                        createdAt = Iso(playlist.CreatedAt),
                        modifiedAt = Iso(playlist.ModifiedAt),
                        max = UserDataRules.MaxPlaylists
                    }, transaction);
            }

            transaction.Commit();
        }

        return await ReadAsync(conn, userId);
    }

    /// <summary>Returns null when the playlist may be stored, otherwise the reason it may not.</summary>
    public static string? ValidatePlaylist(string playlistId, PlaylistUpdate? update)
    {
        if (UserDataRules.ValidateId(playlistId) is { } idError) return idError;
        if (update == null) return "The playlist is missing.";
        return ValidatePlaylistFields(update.Name, update.Description, update.TrackIds);
    }

    /// <summary>Returns null when the whole import may be stored, otherwise the reason it may not (nothing is stored then).</summary>
    public static string? ValidateImport(UserDataSnapshot? data)
    {
        if (data == null) return "The data is missing.";

        var favorites = data.Favorites ?? new List<string>();
        if (favorites.Count > UserDataRules.MaxFavorites) return $"At most {UserDataRules.MaxFavorites} favourites can be imported.";
        foreach (var id in favorites)
        {
            if (UserDataRules.ValidateId(id) is { } error) return $"Favourite: {error}";
        }

        var plays = data.Plays ?? new List<TrackPlayStats>();
        if (plays.Count > UserDataRules.MaxTrackStats) return $"At most {UserDataRules.MaxTrackStats} play statistics can be imported.";
        foreach (var stats in plays)
        {
            if (stats == null) return "Play statistics: an entry is empty.";
            if (UserDataRules.ValidateId(stats.TrackId) is { } error) return $"Play statistics: {error}";
        }

        var playlists = data.Playlists ?? new List<PlaylistData>();
        if (playlists.Count > UserDataRules.MaxPlaylists) return $"At most {UserDataRules.MaxPlaylists} playlists can be imported.";
        foreach (var playlist in playlists)
        {
            if (playlist == null) return "Playlists: an entry is empty.";
            if (UserDataRules.ValidateId(playlist.Id) is { } idError) return $"Playlist: {idError}";
            if (ValidatePlaylistFields(playlist.Name, playlist.Description, playlist.TrackIds) is { } error) return $"Playlist: {error}";
        }

        return null;
    }

    private static string? ValidatePlaylistFields(string? name, string? description, List<string>? trackIds)
    {
        if (string.IsNullOrWhiteSpace(name)) return "The playlist name must not be empty.";
        if (name.Trim().Length > UserDataRules.MaxPlaylistNameLength)
            return $"The playlist name must be at most {UserDataRules.MaxPlaylistNameLength} characters.";
        if (description != null && description.Trim().Length > UserDataRules.MaxPlaylistDescriptionLength)
            return $"The playlist description must be at most {UserDataRules.MaxPlaylistDescriptionLength} characters.";
        if (trackIds == null) return null;
        if (trackIds.Count > UserDataRules.MaxPlaylistTracks)
            return $"A playlist can hold at most {UserDataRules.MaxPlaylistTracks} tracks.";

        foreach (var id in trackIds)
        {
            if (UserDataRules.ValidateId(id) is { } error) return $"Playlist track: {error}";
        }
        return null;
    }

    private const string FavoriteInsertSql = """
        INSERT OR IGNORE INTO user_favorites (user_id, track_id, added_at)
        SELECT @userId, @trackId, @now
        WHERE (SELECT COUNT(*) FROM user_favorites WHERE user_id = @userId) < @max
        """;

    private static async Task<UserDataSnapshot> ReadAsync(IDbConnection conn, string userId)
    {
        var favorites = (await conn.QueryAsync<string>(
            "SELECT track_id FROM user_favorites WHERE user_id = @userId ORDER BY added_at, track_id",
            new { userId })).ToList();

        var plays = (await conn.QueryAsync<PlayRow>(
            "SELECT track_id, play_count, last_played FROM user_plays WHERE user_id = @userId",
            new { userId })).Select(r => r.ToStats()).ToList();

        var playlists = (await conn.QueryAsync<PlaylistRow>(
            "SELECT id, name, description, track_ids_json, created_at, modified_at FROM user_playlists WHERE user_id = @userId ORDER BY name COLLATE NOCASE, id",
            new { userId })).Select(r => r.ToData()).ToList();

        return new UserDataSnapshot(favorites, plays, playlists);
    }

    /// <summary>Round-trip text for a UTC timestamp; same-length UTC strings also sort in time order.</summary>
    private static string Iso(DateTime value)
    {
        var utc = value.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(value, DateTimeKind.Utc) : value.ToUniversalTime();
        return utc.ToString("O", CultureInfo.InvariantCulture);
    }

    private static DateTime ParseIso(string value) =>
        DateTime.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal);

    private sealed record PlayRow(string track_id, long play_count, string? last_played)
    {
        public TrackPlayStats ToStats() => new(
            track_id,
            (int)Math.Clamp(play_count, 0, int.MaxValue),
            last_played == null ? null : ParseIso(last_played));
    }

    private sealed record PlaylistRow(string id, string name, string? description, string track_ids_json, string created_at, string modified_at)
    {
        public PlaylistData ToData() => new(
            id,
            name,
            description,
            JsonSerializer.Deserialize<List<string>>(track_ids_json) ?? new List<string>(),
            ParseIso(created_at),
            ParseIso(modified_at));
    }
}
