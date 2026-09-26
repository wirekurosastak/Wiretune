using System.Globalization;
using System.Text.Json;
using Dapper;
using Wiretune.Core.Models;
using Wiretune.Core.Repositories;

namespace Wiretune.Data;

public class LibraryRepository : ILibraryRepository
{
    private readonly DatabaseManager _dbManager;

    public LibraryRepository(DatabaseManager? dbManager = null)
    {
        _dbManager = dbManager ?? new DatabaseManager();
    }

    public Task InitializeAsync() => Task.Run(_dbManager.InitializeSchema);

    public async Task<List<Track>> GetAllTracksAsync()
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

    public async Task ReplaceAllTracksAsync(IEnumerable<Track> tracks)
    {
        using var connection = _dbManager.CreateConnection();
        using var transaction = connection.BeginTransaction();

        await connection.ExecuteAsync("DELETE FROM tracks", transaction: transaction);

        const string insertSql = """
            INSERT OR REPLACE INTO tracks (
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
            """;

        var parameters = tracks.Select(t => new
        {
            t.Id,
            t.Title,
            t.Artist,
            t.Album,
            t.AlbumArtist,
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

        await connection.ExecuteAsync(insertSql, parameters, transaction);
        transaction.Commit();
    }

    public async Task UpdateTrackFavoriteAsync(string trackId, bool isFavorite)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("UPDATE tracks SET is_favorite = @Fav WHERE id = @Id",
            new { Fav = isFavorite ? 1 : 0, Id = trackId });
    }

    public async Task IncrementPlayCountAsync(string trackId)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync(
            "UPDATE tracks SET play_count = play_count + 1, last_played = @Now WHERE id = @Id",
            new { Now = FormatDate(DateTime.UtcNow), Id = trackId });
    }

    public async Task<List<Playlist>> GetAllPlaylistsAsync()
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
                TrackIds = trackIds
            });
        }
        return list;
    }

    public async Task SavePlaylistAsync(Playlist playlist)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("""
            INSERT OR REPLACE INTO playlists (id, name, description, track_ids_json, created_at, modified_at)
            VALUES (@Id, @Name, @Description, @TrackIdsJson, @CreatedAt, @ModifiedAt)
            """,
            new
            {
                playlist.Id,
                playlist.Name,
                playlist.Description,
                TrackIdsJson = JsonSerializer.Serialize(playlist.TrackIds),
                CreatedAt = FormatDate(playlist.CreatedAt),
                ModifiedAt = FormatDate(playlist.ModifiedAt)
            });
    }

    public async Task DeletePlaylistAsync(string playlistId)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("DELETE FROM playlists WHERE id = @Id", new { Id = playlistId });
    }

    public async Task<string?> GetSettingAsync(string key, string? defaultValue = null)
    {
        using var connection = _dbManager.CreateConnection();
        var val = await connection.QuerySingleOrDefaultAsync<string?>(
            "SELECT value FROM settings WHERE key = @Key", new { Key = key });
        return val ?? defaultValue;
    }

    public async Task SetSettingAsync(string key, string value)
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (@Key, @Value)",
            new { Key = key, Value = value });
    }

    private static int? ToNullableInt(object? value) => value == null ? null : Convert.ToInt32(value);

    private static string? FormatDate(DateTime? value) =>
        value?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    private static DateTime? ParseDate(string? value) =>
        DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed
            : null;
}
