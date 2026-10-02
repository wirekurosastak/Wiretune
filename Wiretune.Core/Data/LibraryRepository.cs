using System.Globalization;
using System.Text.Json;
using Dapper;
using Wiretune.Core.Models;

namespace Wiretune.Core.Data;

public class LibraryRepository
{
    private readonly DatabaseManager _dbManager;

    public LibraryRepository(DatabaseManager? dbManager = null)
    {
        _dbManager = dbManager ?? new DatabaseManager();
    }

    public virtual Task InitializeAsync() => Task.Run(_dbManager.InitializeSchema);

    public virtual async Task<List<Track>> GetAllTracksAsync()
    {
        using var connection = _dbManager.CreateConnection();
        var rows = await connection.QueryAsync("SELECT * FROM tracks");

        var list = new List<Track>();
        foreach (var r in rows)
        {
            list.Add(new Track
            {
                Id = (string)r.id,
                Title = (string)r.title,
                Artist = (string)r.artist,
                Album = (string)r.album,
                AlbumArtist = (string?)r.album_artist,
                TrackNumber = ToNullableInt(r.track_number),
                TrackCount = ToNullableInt(r.track_count),
                DiscNumber = ToNullableInt(r.disc_number),
                Year = ToNullableInt(r.year),
                Genre = (string?)r.genre,
                Duration = TimeSpan.FromSeconds(Convert.ToDouble(r.duration_seconds)),
                FileSizeBytes = Convert.ToInt64(r.file_size_bytes),
                FileModifiedUtc = ParseDate((string?)r.file_modified_utc),
                FilePath = (string)r.file_path,
                StreamUrl = (string?)r.stream_url,
                HasCoverArt = Convert.ToInt32(r.has_cover_art) == 1,
                CoverArtPath = (string?)r.cover_art_path,
                Format = new AudioFormat
                {
                    Codec = (string)r.codec,
                    SampleRate = Convert.ToInt32(r.sample_rate),
                    BitsPerSample = Convert.ToInt32(r.bits_per_sample),
                    Channels = Convert.ToInt32(r.channels),
                    BitrateKbps = Convert.ToInt32(r.bitrate_kbps),
                    IsLossless = Convert.ToInt32(r.is_lossless) == 1
                },
                IsFavorite = Convert.ToInt32(r.is_favorite) == 1,
                PlayCount = Convert.ToInt32(r.play_count),
                LastPlayed = ParseDate((string?)r.last_played),
                DateAdded = ParseDate((string?)r.date_added) ?? DateTime.UtcNow
            });
        }
        return list;
    }

    /// <summary>
    /// Makes the table hold exactly <paramref name="tracks"/>. Rows that are gone are deleted and the others are
    /// inserted or updated in place, and a row whose values did not change is not written at all: a rescan or a refresh
    /// of an unchanged library leaves the database file as it is instead of rewriting every track.
    /// </summary>
    public virtual async Task ReplaceAllTracksAsync(IEnumerable<Track> tracks)
    {
        // The table is unique on both id and path; of tracks that share one of them the last one wins.
        var byId = new Dictionary<string, Track>(StringComparer.Ordinal);
        foreach (var t in tracks) byId[t.Id] = t;
        var byPath = new Dictionary<string, Track>(StringComparer.Ordinal);
        foreach (var t in byId.Values) byPath[t.FilePath] = t;
        var wanted = byPath.Values.ToDictionary(t => t.Id, StringComparer.Ordinal);

        using var connection = _dbManager.CreateConnection();
        using var transaction = connection.BeginTransaction();

        // A stored row stays only if the same track is wanted at the same path. Every other row goes (and a track
        // whose path changed is inserted again), so no insert below can run into the unique path of an old row.
        var obsolete = new List<object>();
        foreach (var row in await connection.QueryAsync("SELECT id, file_path FROM tracks", transaction: transaction))
        {
            var id = (string)row.id;
            var path = (string)row.file_path;
            if (!wanted.TryGetValue(id, out var track) || !string.Equals(track.FilePath, path, StringComparison.Ordinal))
            {
                obsolete.Add(new { Id = id });
            }
        }
        if (obsolete.Count > 0) await connection.ExecuteAsync("DELETE FROM tracks WHERE id = @Id", obsolete, transaction);

        const string upsertSql = """
            INSERT INTO tracks (
                id, title, artist, album, album_artist, track_number, track_count, disc_number,
                year, genre, duration_seconds, file_size_bytes, file_modified_utc, file_path, stream_url,
                has_cover_art, cover_art_path, codec, sample_rate, bits_per_sample, channels,
                bitrate_kbps, is_lossless, is_favorite, play_count, last_played, date_added
            ) VALUES (
                @Id, @Title, @Artist, @Album, @AlbumArtist, @TrackNumber, @TrackCount, @DiscNumber,
                @Year, @Genre, @DurationSeconds, @FileSizeBytes, @FileModifiedUtc, @FilePath, @StreamUrl,
                @HasCoverArt, @CoverArtPath, @Codec, @SampleRate, @BitsPerSample, @Channels,
                @BitrateKbps, @IsLossless, @IsFavorite, @PlayCount, @LastPlayed, @DateAdded
            )
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, artist = excluded.artist, album = excluded.album,
                album_artist = excluded.album_artist, track_number = excluded.track_number,
                track_count = excluded.track_count, disc_number = excluded.disc_number, year = excluded.year,
                genre = excluded.genre, duration_seconds = excluded.duration_seconds,
                file_size_bytes = excluded.file_size_bytes, file_modified_utc = excluded.file_modified_utc,
                stream_url = excluded.stream_url, has_cover_art = excluded.has_cover_art,
                cover_art_path = excluded.cover_art_path, codec = excluded.codec, sample_rate = excluded.sample_rate,
                bits_per_sample = excluded.bits_per_sample, channels = excluded.channels,
                bitrate_kbps = excluded.bitrate_kbps, is_lossless = excluded.is_lossless,
                is_favorite = excluded.is_favorite, play_count = excluded.play_count,
                last_played = excluded.last_played, date_added = excluded.date_added
            WHERE title IS NOT excluded.title OR artist IS NOT excluded.artist OR album IS NOT excluded.album
               OR album_artist IS NOT excluded.album_artist OR track_number IS NOT excluded.track_number
               OR track_count IS NOT excluded.track_count OR disc_number IS NOT excluded.disc_number
               OR year IS NOT excluded.year OR genre IS NOT excluded.genre
               OR duration_seconds IS NOT excluded.duration_seconds OR file_size_bytes IS NOT excluded.file_size_bytes
               OR file_modified_utc IS NOT excluded.file_modified_utc OR stream_url IS NOT excluded.stream_url
               OR has_cover_art IS NOT excluded.has_cover_art OR cover_art_path IS NOT excluded.cover_art_path
               OR codec IS NOT excluded.codec OR sample_rate IS NOT excluded.sample_rate
               OR bits_per_sample IS NOT excluded.bits_per_sample OR channels IS NOT excluded.channels
               OR bitrate_kbps IS NOT excluded.bitrate_kbps OR is_lossless IS NOT excluded.is_lossless
               OR is_favorite IS NOT excluded.is_favorite OR play_count IS NOT excluded.play_count
               OR last_played IS NOT excluded.last_played OR date_added IS NOT excluded.date_added
            """;

        var parameters = byPath.Values.Select(t => new
        {
            t.Id,
            t.Title,
            t.Artist,
            t.Album,
            AlbumArtist = t.AlbumArtistInferred ? null : t.AlbumArtist, // only what the file's tag says
            t.TrackNumber,
            t.TrackCount,
            t.DiscNumber,
            t.Year,
            t.Genre,
            DurationSeconds = t.Duration.TotalSeconds,
            t.FileSizeBytes,
            FileModifiedUtc = FormatDate(t.FileModifiedUtc),
            t.FilePath,
            t.StreamUrl,
            HasCoverArt = t.HasCoverArt ? 1 : 0,
            t.CoverArtPath,
            t.Format.Codec,
            t.Format.SampleRate,
            t.Format.BitsPerSample,
            t.Format.Channels,
            t.Format.BitrateKbps,
            IsLossless = t.Format.IsLossless ? 1 : 0,
            IsFavorite = t.IsFavorite ? 1 : 0,
            t.PlayCount,
            LastPlayed = FormatDate(t.LastPlayed),
            DateAdded = FormatDate(t.DateAdded)
        });

        await connection.ExecuteAsync(upsertSql, parameters, transaction);
        transaction.Commit();
    }

    public virtual async Task UpdateTrackFavoriteAsync(string trackId, bool isFavorite)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("UPDATE tracks SET is_favorite = @Fav WHERE id = @Id",
            new { Fav = isFavorite ? 1 : 0, Id = trackId });
    }

    /// <summary>Writes favourite, play count and last-played of the given tracks in one transaction.</summary>
    public virtual async Task UpdateTracksUserDataAsync(IEnumerable<Track> tracks)
    {
        using var connection = _dbManager.CreateConnection();
        using var transaction = connection.BeginTransaction();

        await connection.ExecuteAsync(
            "UPDATE tracks SET is_favorite = @IsFavorite, play_count = @PlayCount, last_played = @LastPlayed WHERE id = @Id",
            tracks.Select(t => new
            {
                t.Id,
                IsFavorite = t.IsFavorite ? 1 : 0,
                t.PlayCount,
                LastPlayed = FormatDate(t.LastPlayed)
            }),
            transaction);
        transaction.Commit();
    }

    public virtual async Task IncrementPlayCountAsync(string trackId)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync(
            "UPDATE tracks SET play_count = play_count + 1, last_played = @Now WHERE id = @Id",
            new { Now = FormatDate(DateTime.UtcNow), Id = trackId });
    }

    public virtual async Task<List<Playlist>> GetAllPlaylistsAsync()
    {
        using var connection = _dbManager.CreateConnection();
        var rows = await connection.QueryAsync("SELECT * FROM playlists ORDER BY name");

        var list = new List<Playlist>();
        foreach (var r in rows)
        {
            List<string> trackIds;
            try
            {
                trackIds = JsonSerializer.Deserialize<List<string>>((string)r.track_ids_json) ?? new();
            }
            catch (JsonException)
            {
                trackIds = new();
            }

            list.Add(new Playlist
            {
                Id = (string)r.id,
                Name = (string)r.name,
                Description = (string?)r.description,
                CreatedAt = ParseDate((string?)r.created_at) ?? DateTime.UtcNow,
                ModifiedAt = ParseDate((string?)r.modified_at) ?? DateTime.UtcNow,
                IsServer = Convert.ToInt32(r.is_server) == 1,
                TrackIds = trackIds
            });
        }
        return list;
    }

    public virtual async Task SavePlaylistAsync(Playlist playlist)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("""
            INSERT OR REPLACE INTO playlists (id, name, description, track_ids_json, created_at, modified_at, is_server)
            VALUES (@Id, @Name, @Description, @TrackIdsJson, @CreatedAt, @ModifiedAt, @IsServer)
            """,
            new
            {
                playlist.Id,
                playlist.Name,
                playlist.Description,
                IsServer = playlist.IsServer ? 1 : 0,
                TrackIdsJson = JsonSerializer.Serialize(playlist.TrackIds),
                CreatedAt = FormatDate(playlist.CreatedAt),
                ModifiedAt = FormatDate(playlist.ModifiedAt)
            });
    }

    public virtual async Task DeletePlaylistAsync(string playlistId)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("DELETE FROM playlists WHERE id = @Id", new { Id = playlistId });
    }

    /// <summary>Removes the cached copies of server playlists (on sign-out); playlists made on this device stay.</summary>
    public virtual async Task DeleteServerPlaylistsAsync()
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("DELETE FROM playlists WHERE is_server = 1");
    }

    public virtual async Task<string?> GetSettingAsync(string key, string? defaultValue = null)
    {
        using var connection = _dbManager.CreateConnection();
        var val = await connection.QuerySingleOrDefaultAsync<string?>(
            "SELECT value FROM settings WHERE key = @Key", new { Key = key });
        return val ?? defaultValue;
    }

    public virtual async Task SetSettingAsync(string key, string value)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (@Key, @Value)",
            new { Key = key, Value = value });
    }

    /// <summary>
    /// Returns the stored value, first storing the one <paramref name="createValue"/> makes when there is none. If two
    /// processes race on a new database, the value stored first wins and both return it.
    /// </summary>
    public async Task<string> GetOrAddSettingAsync(string key, Func<string> createValue)
    {
        using var connection = _dbManager.CreateConnection();
        var existing = await connection.QueryFirstOrDefaultAsync<string>("SELECT value FROM settings WHERE key = @Key", new { Key = key });
        if (!string.IsNullOrEmpty(existing)) return existing;

        await connection.ExecuteAsync("INSERT OR IGNORE INTO settings (key, value) VALUES (@Key, @Value)", new { Key = key, Value = createValue() });
        return await connection.QueryFirstAsync<string>("SELECT value FROM settings WHERE key = @Key", new { Key = key });
    }

    private static int? ToNullableInt(object? value) => value == null ? null : Convert.ToInt32(value);

    private static string? FormatDate(DateTime? value) =>
        value?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    private static DateTime? ParseDate(string? value) =>
        DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed
            : null;
}



