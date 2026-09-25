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

    public Task InitializeAsync()
    {
        return Task.Run(() => _dbManager.InitializeSchema());
    }

    public async Task<List<Track>> GetAllTracksAsync()
    {
        using var connection = _dbManager.CreateConnection();
        const string sql = "SELECT * FROM tracks ORDER BY artist, album, disc_number, track_number, title";
        var rows = await connection.QueryAsync(sql);

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
                TrackNumber = r.track_number != null ? (int?)Convert.ToInt32(r.track_number) : null,
                TrackCount = r.track_count != null ? (int?)Convert.ToInt32(r.track_count) : null,
                DiscNumber = r.disc_number != null ? (int?)Convert.ToInt32(r.disc_number) : null,
                Year = r.year != null ? (int?)Convert.ToInt32(r.year) : null,
                Genre = (string?)r.genre,
                Duration = TimeSpan.FromSeconds(Convert.ToDouble(r.duration_seconds)),
                FileSizeBytes = Convert.ToInt64(r.file_size_bytes),
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
                LastPlayed = r.last_played != null ? DateTime.Parse((string)r.last_played) : null,
                DateAdded = DateTime.Parse((string)r.date_added)
            });
        }
        return list;
    }

    public async Task SaveTracksBatchAsync(IEnumerable<Track> tracks)
    {
        using var connection = _dbManager.CreateConnection();
        using var transaction = connection.BeginTransaction();

        const string insertSql = """
            INSERT OR REPLACE INTO tracks (
                id, title, artist, album, album_artist, track_number, track_count, disc_number,
                year, genre, duration_seconds, file_size_bytes, file_path, stream_url,
                has_cover_art, cover_art_path, codec, sample_rate, bits_per_sample, channels,
                bitrate_kbps, is_lossless, is_favorite, play_count, last_played, date_added
            ) VALUES (
                @Id, @Title, @Artist, @Album, @AlbumArtist, @TrackNumber, @TrackCount, @DiscNumber,
                @Year, @Genre, @DurationSeconds, @FileSizeBytes, @FilePath, @StreamUrl,
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
            t.FilePath,
            t.StreamUrl,
            HasCoverArt = t.HasCoverArt ? 1 : 0,
            t.CoverArtPath,
            Codec = t.Format.Codec,
            SampleRate = t.Format.SampleRate,
            BitsPerSample = t.Format.BitsPerSample,
            Channels = t.Format.Channels,
            BitrateKbps = t.Format.BitrateKbps,
            IsLossless = t.Format.IsLossless ? 1 : 0,
            IsFavorite = t.IsFavorite ? 1 : 0,
            t.PlayCount,
            LastPlayed = t.LastPlayed?.ToString("O"),
            DateAdded = t.DateAdded.ToString("O")
        });

        await connection.ExecuteAsync(insertSql, parameters, transaction);
        transaction.Commit();
    }

    public async Task ClearTracksAsync()
    {
        using var connection = _dbManager.CreateConnection();
        await connection.ExecuteAsync("DELETE FROM tracks");
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
        await connection.ExecuteAsync("""
            UPDATE tracks 
            SET play_count = play_count + 1, last_played = @Now 
            WHERE id = @Id
        """, new { Now = DateTime.UtcNow.ToString("O"), Id = trackId });
    }

    public async Task<List<Playlist>> GetAllPlaylistsAsync()
    {
        using var connection = _dbManager.CreateConnection();
        const string sql = "SELECT * FROM playlists ORDER BY name";
        var rows = await connection.QueryAsync(sql);

        var list = new List<Playlist>();
        foreach (var r in rows)
        {
            var trackIds = JsonSerializer.Deserialize<List<string>>((string)r.track_ids_json) ?? new();
            list.Add(new Playlist
            {
                Id = (string)r.id,
                Name = (string)r.name,
                Description = (string?)r.description,
                CreatedAt = DateTime.Parse((string)r.created_at),
                ModifiedAt = DateTime.Parse((string)r.modified_at),
                TrackIds = trackIds
            });
        }
        return list;
    }

    public async Task SavePlaylistAsync(Playlist playlist)
    {
        using var connection = _dbManager.CreateConnection();
        const string sql = """
            INSERT OR REPLACE INTO playlists (id, name, description, track_ids_json, created_at, modified_at)
            VALUES (@Id, @Name, @Description, @TrackIdsJson, @CreatedAt, @ModifiedAt)
        """;

        await connection.ExecuteAsync(sql, new
        {
            playlist.Id,
            playlist.Name,
            playlist.Description,
            TrackIdsJson = JsonSerializer.Serialize(playlist.TrackIds),
            CreatedAt = playlist.CreatedAt.ToString("O"),
            ModifiedAt = playlist.ModifiedAt.ToString("O")
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
        const string sql = "INSERT OR REPLACE INTO settings (key, value) VALUES (@Key, @Value)";
        await connection.ExecuteAsync(sql, new { Key = key, Value = value });
    }
}
