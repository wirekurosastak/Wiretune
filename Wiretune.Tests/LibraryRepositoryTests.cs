using Microsoft.Data.Sqlite;
using Wiretune.Core.Data;
using Wiretune.Core.Models;
using Xunit;

namespace Wiretune.Tests;

/// <summary>The repository against a real SQLite file (the other tests use a stand-in that never runs the SQL).</summary>
public sealed class LibraryRepositoryTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("wiretune_repo_").FullName;

    private string DbPath => Path.Combine(_dir, "wiretune.db");

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private async Task<(LibraryRepository Repo, DatabaseManager Db)> OpenAsync()
    {
        var db = new DatabaseManager(DbPath);
        var repo = new LibraryRepository(db);
        await repo.InitializeAsync();
        return (repo, db);
    }

    private static Track Make(string id, string title = "Song", string? path = null) =>
        new()
        {
            Id = id,
            Title = title,
            Artist = "Artist",
            Album = "Album",
            Duration = TimeSpan.FromSeconds(200.5),
            FilePath = path ?? $"/music/{id}.flac",
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16, Channels = 2, IsLossless = true },
            DateAdded = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc)
        };

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static long Count(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }

    // ── Tracks ──

    [Fact]
    public async Task Tracks_RoundTrip_WithTheirUserData()
    {
        var (repo, _) = await OpenAsync();
        var track = Make("a");
        track.IsFavorite = true;
        track.PlayCount = 3;
        track.LastPlayed = new DateTime(2026, 5, 6, 7, 8, 9, DateTimeKind.Utc);
        track.Genre = "Jazz";
        track.TrackNumber = 4;

        await repo.ReplaceAllTracksAsync(new[] { track });
        var stored = Assert.Single(await repo.GetAllTracksAsync());

        Assert.Equal("a", stored.Id);
        Assert.Equal(TimeSpan.FromSeconds(200.5), stored.Duration);
        Assert.Equal("Jazz", stored.Genre);
        Assert.Equal(4, stored.TrackNumber);
        Assert.True(stored.IsFavorite);
        Assert.Equal(3, stored.PlayCount);
        Assert.Equal(track.LastPlayed, stored.LastPlayed);
        Assert.Equal("FLAC", stored.Format.Codec);
    }

    [Fact]
    public async Task ReplacingTheTracks_DeletesWhatIsGone_AndUpdatesWhatChanged()
    {
        var (repo, _) = await OpenAsync();
        await repo.ReplaceAllTracksAsync(new[] { Make("a"), Make("b"), Make("c") });

        var renamed = Make("b", "Renamed");
        await repo.ReplaceAllTracksAsync(new[] { Make("a"), renamed, Make("d") });

        var stored = (await repo.GetAllTracksAsync()).ToDictionary(t => t.Id);
        Assert.Equal(new[] { "a", "b", "d" }, stored.Keys.OrderBy(k => k));
        Assert.Equal("Renamed", stored["b"].Title);
    }

    [Fact]
    public async Task ReplacingTheTracks_WithTheSameLibrary_WritesNothing()
    {
        var (repo, db) = await OpenAsync();
        await repo.ReplaceAllTracksAsync(new[] { Make("a"), Make("b") });

        // A trigger records every update the table sees.
        using (var connection = db.CreateConnection())
        {
            Execute(connection, "CREATE TABLE audit (id TEXT NOT NULL)");
            Execute(connection, "CREATE TRIGGER tracks_audit AFTER UPDATE ON tracks BEGIN INSERT INTO audit VALUES (NEW.id); END");
        }

        await repo.ReplaceAllTracksAsync(new[] { Make("a"), Make("b") });
        using (var connection = db.CreateConnection())
        {
            Assert.Equal(0, Count(connection, "SELECT COUNT(*) FROM audit"));
        }

        await repo.ReplaceAllTracksAsync(new[] { Make("a"), Make("b", "Changed") });
        using (var connection = db.CreateConnection())
        {
            Assert.Equal(1, Count(connection, "SELECT COUNT(*) FROM audit WHERE id = 'b'"));
            Assert.Equal(1, Count(connection, "SELECT COUNT(*) FROM audit"));
        }
    }

    [Fact]
    public async Task ATrackWhosePathChanged_IsStoredAgain_AndTwoTracksWithOnePathKeepTheLast()
    {
        var (repo, _) = await OpenAsync();
        await repo.ReplaceAllTracksAsync(new[] { Make("a", path: "/music/old.flac"), Make("b", path: "/music/other.flac") });

        // "a" moves to the path "b" had, "b" moves away: the unique path column must not get in the way.
        await repo.ReplaceAllTracksAsync(new[] { Make("a", path: "/music/other.flac"), Make("b", path: "/music/new.flac") });
        var stored = (await repo.GetAllTracksAsync()).ToDictionary(t => t.Id);
        Assert.Equal("/music/other.flac", stored["a"].FilePath);
        Assert.Equal("/music/new.flac", stored["b"].FilePath);

        await repo.ReplaceAllTracksAsync(new[] { Make("x", path: "/music/same.flac"), Make("y", path: "/music/same.flac") });
        Assert.Equal("y", Assert.Single(await repo.GetAllTracksAsync()).Id);
    }

    [Fact]
    public async Task OnlyWhatTheTagsSay_IsStoredAsTheAlbumArtist()
    {
        var (repo, _) = await OpenAsync();
        var tagged = Make("a");
        tagged.AlbumArtist = "The Band";
        var inferred = Make("b");
        inferred.AlbumArtist = "Various Artists";
        inferred.AlbumArtistInferred = true;

        await repo.ReplaceAllTracksAsync(new[] { tagged, inferred });

        var stored = (await repo.GetAllTracksAsync()).ToDictionary(t => t.Id);
        Assert.Equal("The Band", stored["a"].AlbumArtist);
        Assert.Null(stored["b"].AlbumArtist);
    }

    [Fact]
    public async Task UserDataOfSeveralTracks_IsWrittenInOneCall()
    {
        var (repo, _) = await OpenAsync();
        await repo.ReplaceAllTracksAsync(new[] { Make("a"), Make("b") });

        var played = new DateTime(2026, 3, 4, 5, 6, 7, DateTimeKind.Utc);
        await repo.UpdateTracksUserDataAsync(new[]
        {
            new Track { Id = "a", IsFavorite = true, PlayCount = 7, LastPlayed = played },
            new Track { Id = "missing", IsFavorite = true, PlayCount = 1 }
        });

        var stored = (await repo.GetAllTracksAsync()).ToDictionary(t => t.Id);
        Assert.True(stored["a"].IsFavorite);
        Assert.Equal(7, stored["a"].PlayCount);
        Assert.Equal(played, stored["a"].LastPlayed);
        Assert.False(stored["b"].IsFavorite);
    }

    // ── Playlists and settings ──

    [Fact]
    public async Task ServerPlaylists_AreMarked_AndOnlyTheyAreRemovedOnSignOut()
    {
        var (repo, _) = await OpenAsync();
        await repo.SavePlaylistAsync(new Playlist { Id = "mine", Name = "Mine", TrackIds = new List<string> { "a" } });
        await repo.SavePlaylistAsync(new Playlist { Id = "theirs", Name = "Theirs", IsServer = true, TrackIds = new List<string> { "b", "c" } });

        var stored = (await repo.GetAllPlaylistsAsync()).ToDictionary(p => p.Id);
        Assert.False(stored["mine"].IsServer);
        Assert.True(stored["theirs"].IsServer);
        Assert.Equal(new[] { "b", "c" }, stored["theirs"].TrackIds);

        await repo.DeleteServerPlaylistsAsync();

        Assert.Equal("mine", Assert.Single(await repo.GetAllPlaylistsAsync()).Id);
    }

    [Fact]
    public async Task GetOrAddSetting_CreatesTheValueOnce_AndKeepsIt()
    {
        var (repo, _) = await OpenAsync();
        var calls = 0;

        var first = await repo.GetOrAddSettingAsync("secret", () => $"value-{++calls}");
        var second = await repo.GetOrAddSettingAsync("secret", () => $"value-{++calls}");

        Assert.Equal("value-1", first);
        Assert.Equal(first, second);
        Assert.Equal(1, calls);
        Assert.Equal(first, await repo.GetSettingAsync("secret"));
    }

    // ── Schema ──

    [Fact]
    public async Task ADatabaseOfAnOlderVersion_IsUpgradedInPlace_AndKeepsItsContent()
    {
        var (repo, db) = await OpenAsync();
        var local = Make("local", path: "/music/local.flac");
        local.FileModifiedUtc = new DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var remote = Make("remote", path: "server:remote");
        remote.StreamUrl = "http://server/api/stream/remote";
        remote.FileModifiedUtc = new DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        await repo.ReplaceAllTracksAsync(new[] { local, remote });
        await repo.SavePlaylistAsync(new Playlist { Id = "p", Name = "Kept", TrackIds = new List<string> { "local" } });

        // Turn it back into what version 2 left: no per-account tables and no is_server column.
        using (var connection = db.CreateConnection())
        {
            Execute(connection, "DROP TABLE user_favorites");
            Execute(connection, "DROP TABLE user_plays");
            Execute(connection, "DROP TABLE user_playlists");
            Execute(connection, "ALTER TABLE playlists DROP COLUMN is_server");
            Execute(connection, "PRAGMA user_version = 2");
        }
        SqliteConnection.ClearAllPools();

        var upgraded = new DatabaseManager(DbPath);
        upgraded.InitializeSchema();

        using (var connection = upgraded.CreateConnection())
        {
            Assert.Equal(4, Count(connection, "PRAGMA user_version"));
            Assert.Equal(0, Count(connection, "SELECT COUNT(*) FROM user_favorites"));
            Assert.Equal(0, Count(connection, "SELECT COUNT(*) FROM user_plays"));
            Assert.Equal(0, Count(connection, "SELECT COUNT(*) FROM user_playlists"));
            // The tags of local files are read again by the next scan; tracks of a server are replaced on refresh.
            Assert.Equal(1, Count(connection, "SELECT COUNT(*) FROM tracks WHERE file_modified_utc IS NULL AND id = 'local'"));
            Assert.Equal(1, Count(connection, "SELECT COUNT(*) FROM tracks WHERE file_modified_utc IS NOT NULL AND id = 'remote'"));
        }

        var reopened = new LibraryRepository(upgraded);
        Assert.Equal(2, (await reopened.GetAllTracksAsync()).Count);
        var playlist = Assert.Single(await reopened.GetAllPlaylistsAsync());
        Assert.Equal("Kept", playlist.Name);
        Assert.False(playlist.IsServer);
    }

    [Fact]
    public async Task InitializingTheSchemaTwice_ChangesNothing()
    {
        var (repo, db) = await OpenAsync();
        await repo.ReplaceAllTracksAsync(new[] { Make("a") });

        new DatabaseManager(DbPath).InitializeSchema();
        db.InitializeSchema();

        Assert.Single(await repo.GetAllTracksAsync());
    }
}
