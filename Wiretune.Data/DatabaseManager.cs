using Microsoft.Data.Sqlite;
using Wiretune.Core.Services;

namespace Wiretune.Data;

public class DatabaseManager
{
    private const int SchemaVersion = 2;

    private readonly string _connectionString;
    private readonly object _schemaLock = new();
    private bool _schemaReady;

    public string DatabasePath { get; }

    public DatabaseManager(string? customDbPath = null)
    {
        DatabasePath = Path.GetFullPath(customDbPath ?? Path.Combine(AppPaths.GetDataDirectory(), "wiretune.db"));

        var dir = Path.GetDirectoryName(DatabasePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate
        }.ToString();
    }

    public SqliteConnection CreateConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();
        using var cmd = connection.CreateCommand();
        cmd.CommandText = "PRAGMA busy_timeout = 5000; PRAGMA synchronous = NORMAL;";
        cmd.ExecuteNonQuery();
        return connection;
    }

    /// <summary>Creates or migrates the schema. Safe to call repeatedly and from multiple threads.</summary>
    public void InitializeSchema()
    {
        lock (_schemaLock)
        {
            if (_schemaReady) return;

            using var connection = CreateConnection();
            Execute(connection, "PRAGMA journal_mode = WAL;");

            var version = Convert.ToInt32(Scalar(connection, "PRAGMA user_version;"));
            using var transaction = connection.BeginTransaction();

            if (version < 1)
            {
                Execute(connection, """
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
                    """);
            }

            if (version < 2 && !ColumnExists(connection, "tracks", "file_modified_utc"))
            {
                Execute(connection, "ALTER TABLE tracks ADD COLUMN file_modified_utc TEXT;");
            }

            Execute(connection, $"PRAGMA user_version = {SchemaVersion};");
            transaction.Commit();
            _schemaReady = true;
        }
    }

    private static bool ColumnExists(SqliteConnection connection, string table, string column)
    {
        using var cmd = connection.CreateCommand();
        cmd.CommandText = $"PRAGMA table_info({table});";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var cmd = connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static object? Scalar(SqliteConnection connection, string sql)
    {
        using var cmd = connection.CreateCommand();
        cmd.CommandText = sql;
        return cmd.ExecuteScalar();
    }
}
