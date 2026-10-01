﻿using Avalonia.Media;
using Microsoft.Data.Sqlite;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.Core.Data;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>Regression tests for behaviour fixed during the full-stack review.</summary>
public class RefactorRegressionTests
{
    private static (LibraryService Service, MockRepository Repo) CreateService()
    {
        var repo = new MockRepository();
        return (new LibraryService(repo, new MetadataScanner(), Path.Combine(Path.GetTempPath(), "wiretune-test-covers")), repo);
    }

    // ── Library indexing ──

    [Fact]
    public async Task CompilationAlbum_IsGroupedUnderAlbumArtist_AndTrackArtistsKeepTheirTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            TestSupport.MakeTrack("1", "Song X", artist: "Artist X", album: "Hits 2024", albumArtist: "Various Artists", trackNumber: 1),
            TestSupport.MakeTrack("2", "Song Y", artist: "Artist Y", album: "Hits 2024", albumArtist: "Various Artists", trackNumber: 2),
            TestSupport.MakeTrack("3", "Solo", artist: "Artist X", album: "Own Album")
        });
        await service.InitializeAsync();

        var compilation = Assert.Single(service.Albums, a => a.Title == "Hits 2024");
        Assert.Equal("Various Artists", compilation.Artist);
        Assert.Equal(new[] { "1", "2" }, compilation.Tracks.Select(t => t.Id));

        var various = service.GetArtistByName("various artists");
        Assert.NotNull(various);
        Assert.Single(various!.Albums);
        Assert.Equal(2, various.TrackCount);

        var artistX = service.GetArtistByName("Artist X")!;
        Assert.Equal(new[] { "Own Album" }, artistX.Albums.Select(a => a.Title));
        Assert.Equal(new[] { "1", "3" }, artistX.Tracks.Select(t => t.Id).OrderBy(id => id));
        Assert.Same(compilation, service.GetAlbumForTrack(service.GetTrack("2")!));
    }

    [Fact]
    public async Task ArtistAndAlbumGrouping_IsCaseInsensitive()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            TestSupport.MakeTrack("1", "A", artist: "The Band", album: "Record"),
            TestSupport.MakeTrack("2", "B", artist: "THE BAND", album: "record")
        });
        await service.InitializeAsync();

        Assert.Single(service.Artists);
        Assert.Single(service.Albums);
        Assert.Equal(2, service.Artists[0].TrackCount);
    }

    [Fact]
    public async Task ReplaceTracks_PreservesFavoritesAndPlayCounts()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { TestSupport.MakeTrack("keep", "Keep"), TestSupport.MakeTrack("drop", "Drop") });
        await service.InitializeAsync();
        await service.ToggleFavoriteAsync("keep");
        await service.RecordPlayAsync("keep");

        await service.ReplaceTracksAsync(new[] { TestSupport.MakeTrack("keep", "Keep (remastered)"), TestSupport.MakeTrack("new", "New") });

        var kept = service.GetTrack("keep")!;
        Assert.True(kept.IsFavorite);
        Assert.Equal(1, kept.PlayCount);
        Assert.Equal("Keep (remastered)", kept.Title);
        Assert.Null(service.GetTrack("drop"));
        Assert.Equal(1, repo.ReplaceCalls);
        Assert.Equal(2, repo.Tracks.Count);
    }

    [Fact]
    public async Task IncrementalScan_ReusesUnchangedFiles_AndRereadsModifiedOnes()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_scan_").FullName;
        try
        {
            var a = Path.Combine(dir, "a.wav");
            var b = Path.Combine(dir, "b.wav");
            WavFile.Write(a, 44100, 0.2);
            WavFile.Write(b, 44100, 0.2);

            var (service, _) = CreateService();
            await service.InitializeAsync();
            Assert.True(await service.ScanFolderAsync(dir));
            var firstA = service.Tracks.Single(t => t.FilePath == Path.GetFullPath(a));
            var firstB = service.Tracks.Single(t => t.FilePath == Path.GetFullPath(b));
            Assert.NotNull(firstA.FileModifiedUtc);

            WavFile.Write(b, 96000, 0.3);
            File.SetLastWriteTimeUtc(b, DateTime.UtcNow.AddMinutes(1));
            Assert.True(await service.ScanFolderAsync(dir));

            Assert.Same(firstA, service.GetTrack(firstA.Id));
            var rescannedB = service.GetTrack(firstB.Id)!;
            Assert.NotSame(firstB, rescannedB);
            Assert.Equal(96000, rescannedB.Format.SampleRate);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task ConcurrentScans_OnlyOneRuns()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_concurrent_").FullName;
        try
        {
            for (var i = 0; i < 20; i++) WavFile.Write(Path.Combine(dir, $"{i}.wav"), 44100, 0.05);
            var (service, _) = CreateService();
            await service.InitializeAsync();

            var results = await Task.WhenAll(service.ScanFolderAsync(dir), service.ScanFolderAsync(dir), service.ScanFolderAsync(dir));

            Assert.Equal(1, results.Count(r => r));
            Assert.Equal(20, service.Tracks.Count);
            Assert.False(service.IsScanning);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task PlaylistTrackIds_AreCopyOnWrite_AndMissingTracksAreSkipped()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { TestSupport.MakeTrack("t1", "One") });
        await service.InitializeAsync();
        var playlist = await service.CreatePlaylistAsync("Mix");

        var before = playlist.TrackIds;
        await service.AddTrackToPlaylistAsync(playlist.Id, "t1");
        await service.AddTrackToPlaylistAsync(playlist.Id, "ghost");

        Assert.Empty(before);
        Assert.Equal(new[] { "t1", "ghost" }, playlist.TrackIds);
        Assert.Equal(new[] { "t1" }, service.GetPlaylistTracks(playlist).Select(t => t.Id));
    }

    // ── Audio engine ──

    [Fact]
    public async Task Engine_RefusesExclusiveAndBitperfect_OnSharedOnlyDevice()
    {
        using var engine = TestSupport.CreateEngine(null, TestSupport.SharedOnlyDevice);
        var failures = new List<string>();
        engine.PlaybackFailed += (_, m) => failures.Add(m);

        await engine.SetBitperfectModeAsync(true);
        await engine.SetExclusiveModeAsync(true);

        Assert.False(engine.IsBitperfect);
        Assert.False(engine.IsExclusiveMode);
        Assert.Equal(2, failures.Count);
    }

    [Fact]
    public async Task Engine_AppendsStreamTokenAtPlayback_WithoutMutatingTheTrack()
    {
        var driver = new FakeAudioDriver();
        using var engine = TestSupport.CreateEngine(driver);
        var track = TestSupport.MakeTrack("s1", "Remote");
        track.StreamUrl = "http://server:5200/api/stream/s1";

        engine.SetStreamAuthorization("abc def");
        await engine.PlayTrackAsync(track);

        Assert.Equal("http://server:5200/api/stream/s1?token=abc%20def", driver.LastSource);
        Assert.Equal("http://server:5200/api/stream/s1", track.StreamUrl);

        engine.SetStreamAuthorization(null);
        await engine.PlayTrackAsync(track);
        Assert.Equal(track.StreamUrl, driver.LastSource);
    }

    [Fact]
    public async Task Engine_ReportsFailure_WhenTrackHasNoSource()
    {
        var driver = new FakeAudioDriver();
        using var engine = TestSupport.CreateEngine(driver);
        string? failure = null;
        engine.PlaybackFailed += (_, m) => failure = m;

        await engine.PlayTrackAsync(new Track { Title = "Ghost", FilePath = "" });

        Assert.NotNull(failure);
        Assert.Equal(0, driver.PlayCalls);
    }

    [Fact]
    public void Engine_Dispose_IsIdempotent()
    {
        var engine = TestSupport.CreateEngine();
        engine.Dispose();
        engine.Dispose();
    }

    // ── Player queue ──

    [Fact]
    public void Shuffle_StartingFromTrack_PlaysItFirst_AndStillPlaysEveryTrack()
    {
        var (service, _) = CreateService();
        using var engine = TestSupport.CreateEngine();
        var player = new PlayerViewModel(engine, service);
        var tracks = Enumerable.Range(1, 8).Select(i => TestSupport.MakeTrack($"t{i}", $"Track {i}")).ToList();

        player.IsShuffle = true;
        player.PlayQueue(tracks, tracks[5]);

        var played = new List<Track> { engine.CurrentTrack! };
        for (var i = 1; i < tracks.Count; i++)
        {
            player.NextTrack();
            played.Add(engine.CurrentTrack!);
        }

        Assert.Same(tracks[5], played[0]);
        Assert.Equal(tracks.Select(t => t.Id).OrderBy(x => x), played.Select(t => t.Id).OrderBy(x => x));
    }

    [Fact]
    public void TurningShuffleOff_MidQueue_ContinuesInOriginalOrderAfterCurrentTrack()
    {
        var (service, _) = CreateService();
        using var engine = TestSupport.CreateEngine();
        var player = new PlayerViewModel(engine, service);
        var tracks = Enumerable.Range(1, 5).Select(i => TestSupport.MakeTrack($"t{i}", $"Track {i}")).ToList();

        player.PlayQueue(tracks, tracks[1]);
        player.IsShuffle = true;
        player.IsShuffle = false;
        player.NextTrack();

        Assert.Same(tracks[2], engine.CurrentTrack);
    }

    // ── Persistence ──

    [Fact]
    public async Task Database_MigratesVersion1Schema_AndRoundTripsFileTimestamps()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_db_").FullName;
        var dbPath = Path.Combine(dir, "legacy.db");
        try
        {
            await using (var legacy = new SqliteConnection($"Data Source={dbPath}"))
            {
                await legacy.OpenAsync();
                var cmd = legacy.CreateCommand();
                cmd.CommandText = """
                    CREATE TABLE tracks (id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL,
                        album_artist TEXT, track_number INTEGER, track_count INTEGER, disc_number INTEGER, year INTEGER, genre TEXT,
                        duration_seconds REAL NOT NULL, file_size_bytes INTEGER NOT NULL, file_path TEXT NOT NULL UNIQUE, stream_url TEXT,
                        has_cover_art INTEGER NOT NULL, cover_art_path TEXT, codec TEXT NOT NULL, sample_rate INTEGER NOT NULL,
                        bits_per_sample INTEGER NOT NULL, channels INTEGER NOT NULL, bitrate_kbps INTEGER NOT NULL, is_lossless INTEGER NOT NULL,
                        is_favorite INTEGER NOT NULL DEFAULT 0, play_count INTEGER NOT NULL DEFAULT 0, last_played TEXT, date_added TEXT NOT NULL);
                    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    INSERT INTO tracks VALUES ('old','Old','A','B',NULL,1,NULL,NULL,NULL,NULL,60,100,'/m/old.flac',NULL,0,NULL,'FLAC',44100,16,2,900,1,1,3,NULL,'2024-01-01T00:00:00.0000000Z');
                    """;
                await cmd.ExecuteNonQueryAsync();
            }
            SqliteConnection.ClearAllPools();

            var repo = new LibraryRepository(new DatabaseManager(dbPath));
            await repo.InitializeAsync();

            var migrated = Assert.Single(await repo.GetAllTracksAsync());
            Assert.True(migrated.IsFavorite);
            Assert.Equal(3, migrated.PlayCount);
            Assert.Null(migrated.FileModifiedUtc);

            var stamp = new DateTime(2025, 5, 6, 7, 8, 9, DateTimeKind.Utc).AddTicks(1234567);
            migrated.FileModifiedUtc = stamp;
            await repo.ReplaceAllTracksAsync(new[] { migrated });

            Assert.Equal(stamp, (await repo.GetAllTracksAsync())[0].FileModifiedUtc);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(dir, recursive: true);
        }
    }

    // ── Client connection ──

    [Theory]
    [InlineData("192.168.1.10:5200", true, "http://192.168.1.10:5200")]
    [InlineData(" https://music.example.com/ ", true, "https://music.example.com")]
    [InlineData("http://host:5200///", true, "http://host:5200")]
    [InlineData("ftp://host", false, "")]
    [InlineData("", false, "")]
    [InlineData("http://", false, "")]
    public void ServerUrl_IsNormalizedOrRejected(string input, bool valid, string expected)
    {
        Assert.Equal(valid, ServerSession.TryNormalizeServerUrl(input, out var normalized));
        Assert.Equal(expected, normalized);
    }

    [Fact]
    public async Task FavoritesViewModel_ComputesTotalDuration_AndEnablesShuffle()
    {
        var (service, repo) = CreateService();
        var t1 = TestSupport.MakeTrack("1", "Fav 1", minutes: 3.5);
        t1.IsFavorite = true;
        var t2 = TestSupport.MakeTrack("2", "Fav 2", minutes: 4.5);
        t2.IsFavorite = true;
        await repo.SaveTracksBatchAsync(new[] { t1, t2 });
        await service.InitializeAsync();

        var player = new PlayerViewModel(TestSupport.CreateEngine(), service);
        var favoritesVm = new FavoritesViewModel(service, player);

        Assert.Equal(2, favoritesVm.FavoriteTracks.Count);
        Assert.False(favoritesVm.IsEmpty);
        Assert.Equal("8 min 0 s", favoritesVm.TotalFavoritesDuration);

        favoritesVm.ShuffleAll();
        Assert.True(player.IsShuffle);
        Assert.Equal(2, player.QueueTracks.Count);
    }

    [Fact]
    public async Task PlaylistsViewModel_ComputesSelectedPlaylistTotalDuration()
    {
        var (service, repo) = CreateService();
        var t1 = TestSupport.MakeTrack("1", "Track 1", minutes: 30.0);
        var t2 = TestSupport.MakeTrack("2", "Track 2", minutes: 45.0);
        await repo.SaveTracksBatchAsync(new[] { t1, t2 });
        await service.InitializeAsync();

        var playlist = await service.CreatePlaylistAsync("Chill");
        await service.AddTrackToPlaylistAsync(playlist.Id, "1");
        await service.AddTrackToPlaylistAsync(playlist.Id, "2");

        var player = new PlayerViewModel(TestSupport.CreateEngine(), service);
        var playlistsVm = new PlaylistsViewModel(service, player);

        playlistsVm.SelectedPlaylist = playlist;
        Assert.Equal("1 h 15 min", playlistsVm.SelectedPlaylistTotalDuration);
    }

    [Fact]
    public async Task PlaylistsViewModel_SetsMixedHqBadge_WhenTracksHaveMixedFormats()
    {
        var (service, repo) = CreateService();
        var t1 = TestSupport.MakeTrack("1", "Track 1", minutes: 3.0);
        t1.Format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16, IsLossless = true };
        var t2 = TestSupport.MakeTrack("2", "Track 2", minutes: 4.0);
        t2.Format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24, IsLossless = true };
        await repo.SaveTracksBatchAsync(new[] { t1, t2 });
        await service.InitializeAsync();

        var playlist = await service.CreatePlaylistAsync("HiFi Mix");
        await service.AddTrackToPlaylistAsync(playlist.Id, "1");
        await service.AddTrackToPlaylistAsync(playlist.Id, "2");

        var player = new PlayerViewModel(TestSupport.CreateEngine(), service);
        var playlistsVm = new PlaylistsViewModel(service, player);

        playlistsVm.SelectedPlaylist = playlist;
        Assert.Equal("MIXED HQ", playlistsVm.SelectedPlaylist?.FormatBadge);
    }

    [Fact]
    public async Task LibraryService_RenamePlaylist_UpdatesNameAndPersists()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();
        var playlist = await service.CreatePlaylistAsync("Original");

        await service.RenamePlaylistAsync(playlist.Id, "Renamed");

        var retrieved = service.Playlists.FirstOrDefault(p => p.Id == playlist.Id);
        Assert.NotNull(retrieved);
        Assert.Equal("Renamed", retrieved.Name);
    }

    [Fact]
    public async Task PlaylistsViewModel_RenameWorkflow_WorksCorrectly()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();
        var playlist = await service.CreatePlaylistAsync("Initial Name");

        var player = new PlayerViewModel(TestSupport.CreateEngine(), service);
        var vm = new PlaylistsViewModel(service, player)
        {
            SelectedPlaylist = playlist
        };

        // Start rename
        vm.StartRenameCommand.Execute(null);
        Assert.True(vm.IsEditingName);
        Assert.Equal("Initial Name", vm.EditingPlaylistName);

        // Cancel rename
        vm.EditingPlaylistName = "Cancelled Name";
        vm.CancelRenameCommand.Execute(null);
        Assert.False(vm.IsEditingName);
        Assert.Equal("Initial Name", vm.SelectedPlaylist.Name);

        // Rename confirmed with valid name
        vm.StartRenameCommand.Execute(null);
        vm.EditingPlaylistName = "New Favorite Name";
        vm.ConfirmRenamePlaylistCommand.Execute(null);
        Assert.False(vm.IsEditingName);
        Assert.Equal("New Favorite Name", vm.SelectedPlaylist.Name);
    }

    [Fact]
    public async Task SearchResultsViewModel_BestMatch_SetsAppropriateTypeLabelsAndBrushes()
    {
        var (service, repo) = CreateService();
        var track = TestSupport.MakeTrack("t1", "Starboy");
        track.Artist = "The Weeknd";
        track.Album = "Starboy";
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        var player = new PlayerViewModel(TestSupport.CreateEngine(), service);
        var searchVm = new SearchResultsViewModel(service, player, _ => { }, _ => { }, _ => { });

        // Search for artist
        searchVm.UpdateQuery("The Weeknd");
        Assert.NotNull(searchVm.BestMatch);
        Assert.Equal("ARTIST", searchVm.BestMatch.TypeLabel);
        Assert.Equal("#ffff6b6b", (searchVm.BestMatch.TypeBrush as ISolidColorBrush)?.Color.ToString());

        // Search for album
        searchVm.UpdateQuery("Starboy");
        Assert.NotNull(searchVm.BestMatch);
        // Could match album or track; verify type label matches its assigned brush color
        if (searchVm.BestMatch.TypeLabel == "ALBUM")
            Assert.Equal("#ffd05ce3", (searchVm.BestMatch.TypeBrush as ISolidColorBrush)?.Color.ToString());
        else if (searchVm.BestMatch.TypeLabel == "SZÁM")
            Assert.Equal("#ff67c8e0", (searchVm.BestMatch.TypeBrush as ISolidColorBrush)?.Color.ToString());
    }
}





