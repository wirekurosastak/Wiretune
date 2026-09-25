using Microsoft.Data.Sqlite;

namespace Wiretune.Data;

public class DatabaseManager
{
    private readonly string _connectionString;

    public DatabaseManager(string? customDbPath = null)
    {
        var dbPath = customDbPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Wiretune",
            "wiretune.db");

        var dir = Path.GetDirectoryName(dbPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        _connectionString = $"Data Source={dbPath}";
    }

    public SqliteConnection CreateConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var cmd = connection.CreateCommand();
        cmd.CommandText = "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;";
        cmd.ExecuteNonQuery();
        return connection;
    }

    public void InitializeSchema()
    {
        using var connection = CreateConnection();
        using var cmd = connection.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                album_artist TEXT,
                track_number INTEGER,
                track_count INTEGER,
                disc_number INTEGER,
                year INTEGER,
                genre TEXT,
                duration_seconds REAL NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                file_path TEXT NOT NULL UNIQUE,
                stream_url TEXT,
                has_cover_art INTEGER NOT NULL,
                cover_art_path TEXT,
                codec TEXT NOT NULL,
                sample_rate INTEGER NOT NULL,
                bits_per_sample INTEGER NOT NULL,
                channels INTEGER NOT NULL,
                bitrate_kbps INTEGER NOT NULL,
                is_lossless INTEGER NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                play_count INTEGER NOT NULL DEFAULT 0,
                last_played TEXT,
                date_added TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
            CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
            CREATE INDEX IF NOT EXISTS idx_tracks_favorite ON tracks(is_favorite);

            CREATE TABLE IF NOT EXISTS playlists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                track_ids_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                modified_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL UNIQUE COLLATE NOCASE,
                password_hash TEXT NOT NULL,
                display_name TEXT,
                is_admin INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                last_login TEXT
            );
        """;
        cmd.ExecuteNonQuery();
    }
}
