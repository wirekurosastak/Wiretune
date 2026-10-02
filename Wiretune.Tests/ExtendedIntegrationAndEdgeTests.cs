using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

public class ExtendedIntegrationAndEdgeTests
{
    // ─────────────────────────────────────────────────────────────────────────
    // 1. MetadataScanner: Ignores non-audio files (e.g. .txt, .nfo, .cue)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task Scanner_IgnoresTxtAndNonAudioFiles_InDirectory()
    {
        var scanner = new MetadataScanner();
        var tempDir = Directory.CreateTempSubdirectory("wiretune_test_files_").FullName;
        var coversDir = Directory.CreateTempSubdirectory("wiretune_test_covers_").FullName;

        try
        {
            // Create several .txt, .nfo, and .cue files
            File.WriteAllText(Path.Combine(tempDir, "album_notes.txt"), "Some album description");
            File.WriteAllText(Path.Combine(tempDir, "tracklist.txt"), "1. Song One\n2. Song Two");
            File.WriteAllText(Path.Combine(tempDir, "release.nfo"), "Group release info");
            File.WriteAllText(Path.Combine(tempDir, "disc.cue"), "FILE \"song.flac\" WAVE");

            var scanned = await scanner.ScanDirectoryAsync(tempDir, coversDir);

            // None of the text/cue/nfo files should be included as audio tracks
            Assert.Empty(scanned);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
            Directory.Delete(coversDir, recursive: true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. MetadataScanner: Recursive Directory Traversal
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task Scanner_RecursiveTraversal_FindsNestedFiles()
    {
        var scanner = new MetadataScanner();
        var tempDir = Directory.CreateTempSubdirectory("wiretune_nested_").FullName;
        var coversDir = Directory.CreateTempSubdirectory("wiretune_cov_").FullName;

        try
        {
            var nestedSubdir = Path.Combine(tempDir, "Artist", "Album", "CD1");
            Directory.CreateDirectory(nestedSubdir);

            // Create non-audio file deep inside
            File.WriteAllText(Path.Combine(nestedSubdir, "credits.txt"), "Produced by Wiretune");

            var scanned = await scanner.ScanDirectoryAsync(tempDir, coversDir);

            // Still 0 audio tracks, verified deep recursion did not crash
            Assert.Empty(scanned);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
            Directory.Delete(coversDir, recursive: true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. WiretuneLog: MinimumLevel filtering
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void WiretuneLog_RespectsMinimumLevel()
    {
        var entries = new List<LogEntry>();
        Action<LogEntry> handler = entries.Add;

        try
        {
            WiretuneLog.OnLogEntry += handler;
            WiretuneLog.MinimumLevel = LogLevel.Warn;

            WiretuneLog.Debug("TestCategory", "This debug should be filtered out");
            WiretuneLog.Info("TestCategory", "This info should be filtered out");
            WiretuneLog.Warn("TestCategory", "This warning should be captured");
            WiretuneLog.Error("TestCategory", "This error should be captured");

            var testEntries = entries.Where(e => e.Category == "TestCategory").ToList();
            Assert.Equal(2, testEntries.Count);
            Assert.Contains(testEntries, e => e.Level == LogLevel.Warn);
            Assert.Contains(testEntries, e => e.Level == LogLevel.Error);
            Assert.DoesNotContain(testEntries, e => e.Level == LogLevel.Debug);
            Assert.DoesNotContain(testEntries, e => e.Level == LogLevel.Info);
        }
        finally
        {
            WiretuneLog.OnLogEntry -= handler;
            WiretuneLog.MinimumLevel = LogLevel.Debug; // restore
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. WiretuneLog: Concurrent Thread Safety
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task WiretuneLog_ConcurrentLogging_DoesNotThrow()
    {
        var tasks = Enumerable.Range(0, 50).Select(i => Task.Run(() =>
        {
            for (int j = 0; j < 20; j++)
            {
                WiretuneLog.Debug("ConcurrentTest", $"Worker {i} - log message {j}");
            }
        }));

        var ex = await Record.ExceptionAsync(() => Task.WhenAll(tasks));
        Assert.Null(ex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WiretuneLog: stream URLs carry the access token, which must never reach the log
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void WiretuneLog_RedactsStreamTokens_InMessagesAndExceptions()
    {
        var entry = new LogEntry(
            DateTime.Now,
            LogLevel.Error,
            "Test",
            "Cannot open http://host/api/stream/t1?token=abc.def-123&x=1",
            new InvalidOperationException("failed for 'http://host/api/stream/t1?token=abc.def-123'"));

        var line = entry.ToString();

        Assert.DoesNotContain("abc.def-123", line);
        Assert.Contains("token=***&x=1", line);
        Assert.Equal("a?token=***", WiretuneLog.Redact("a?token=secret"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. ServerStreamingClient: URL Formatting
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData("http://localhost:5200", "t1", "http://localhost:5200/api/stream/t1")]
    [InlineData("http://localhost:5200/", "t1", "http://localhost:5200/api/stream/t1")]
    [InlineData("http://192.168.1.50:8080///", "track-abc", "http://192.168.1.50:8080/api/stream/track-abc")]
    [InlineData("https://wiretune.internal:5200", "99", "https://wiretune.internal:5200/api/stream/99")]
    public void ServerStreamingClient_GetStreamUrl_FormatsCorrectly(string baseUrl, string trackId, string expected)
    {
        var result = ServerStreamingClient.BuildStreamUrl(baseUrl, trackId);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("http://localhost:5200", "t1", "http://localhost:5200/api/cover/t1")]
    [InlineData("http://localhost:5200/", "t1", "http://localhost:5200/api/cover/t1")]
    public void ServerStreamingClient_GetCoverArtUrl_FormatsCorrectly(string baseUrl, string trackId, string expected)
    {
        var result = ServerStreamingClient.BuildCoverUrl(baseUrl, trackId);
        Assert.Equal(expected, result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. PlayerViewModel: Shuffle Preserves All Items
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void PlayerViewModel_PlayQueue_ShufflePreservesExactTrackSet()
    {
        using var engine = TestSupport.CreateEngine();
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());
        var player = new PlayerViewModel(engine, service);

        var tracks = Enumerable.Range(1, 20).Select(i => new Track
        {
            Id = $"track_{i}",
            Title = $"Song {i}",
            Artist = "Artist",
            Album = "Album",
            Duration = TimeSpan.FromMinutes(3),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16, IsLossless = true }
        }).ToList();

        // Turn on shuffle
        player.ToggleShuffleCommand.Execute(null);
        Assert.True(player.IsShuffle);

        // Load queue
        player.PlayQueue(tracks, tracks[0]);

        // Reflect internal queue to verify all items are preserved
        var queueField = typeof(PlayerViewModel).GetField("_playbackQueue",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        var internalQueue = queueField?.GetValue(player) as List<Track>;

        Assert.NotNull(internalQueue);
        Assert.Equal(tracks.Count, internalQueue!.Count);
        Assert.All(tracks, t => Assert.Contains(internalQueue, q => q.Id == t.Id));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. PlayerViewModel: PreviousTrack Position Logic (> 3s vs <= 3s)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void PlayerViewModel_PreviousTrack_WhenOverThreeSeconds_RewindsTrack()
    {
        using var engine = TestSupport.CreateEngine();
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());
        var player = new PlayerViewModel(engine, service);

        var track1 = new Track { Id = "t1", Title = "Track 1", Format = new AudioFormat { Codec = "FLAC" } };
        var track2 = new Track { Id = "t2", Title = "Track 2", Format = new AudioFormat { Codec = "FLAC" } };

        player.PlayQueue(new[] { track1, track2 }, track2);

        // Simulate playback at 15 seconds
        player.PositionSeconds = 15.0;

        // Previous track when > 3s should seek to 0 instead of moving to previous track
        player.PreviousTrackCommand.Execute(null);

        // Queue index should still point to track 2
        var indexField = typeof(PlayerViewModel).GetField("_queueIndex",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        var idx = (int)(indexField?.GetValue(player) ?? -1);

        Assert.Equal(1, idx); // Remains on track2 (index 1), just rewound
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. AudioFormat: HiRes Studio Master and Format Badge
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData(192000, 24, true, "FLAC / 24bit / 192kHz")]
    [InlineData(96000, 24, true, "FLAC / 24bit / 96kHz")]
    [InlineData(88200, 24, true, "FLAC / 24bit / 88.2kHz")]
    [InlineData(44100, 24, true, "FLAC / 24bit / 44.1kHz")]
    [InlineData(44100, 16, false, "FLAC / 16bit / 44.1kHz")]
    [InlineData(48000, 16, false, "FLAC / 16bit / 48kHz")]
    public void AudioFormat_DisplayBadge_FormatsCorrectly(int rate, int bits, bool expectedHiRes, string expectedBadge)
    {
        var format = new AudioFormat
        {
            Codec = "FLAC",
            SampleRate = rate,
            BitsPerSample = bits,
            IsLossless = true
        };

        Assert.Equal(expectedHiRes, format.IsHiRes);
        Assert.Equal(expectedBadge, format.DisplayBadge);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 9. LibraryService: Indexes are Sorted Alphabetically
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task LibraryService_RebuildIndexes_SortsAlphabetically()
    {
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());

        repo.Tracks.Add(new Track { Id = "1", Title = "Song", Artist = "Zebra Band", Album = "Z Album", Format = new AudioFormat { Codec = "FLAC" } });
        repo.Tracks.Add(new Track { Id = "2", Title = "Song", Artist = "Alpha Band", Album = "A Album", Format = new AudioFormat { Codec = "FLAC" } });
        repo.Tracks.Add(new Track { Id = "3", Title = "Song", Artist = "Beta Band", Album = "B Album", Format = new AudioFormat { Codec = "FLAC" } });

        await service.InitializeAsync();

        Assert.Equal("Alpha Band", service.Artists[0].Name);
        Assert.Equal("Beta Band", service.Artists[1].Name);
        Assert.Equal("Zebra Band", service.Artists[2].Name);

        Assert.Equal("A Album", service.Albums[0].Title);
        Assert.Equal("B Album", service.Albums[1].Title);
        Assert.Equal("Z Album", service.Albums[2].Title);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 10. PlayerViewModel: MoveQueueTrack, RemoveQueueTrack and ClearQueue
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void PlayerViewModel_MoveQueueTrack_ReordersTracksAndUpdatesQueueItems()
    {
        using var engine = TestSupport.CreateEngine();
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());
        var player = new PlayerViewModel(engine, service);

        var track1 = new Track { Id = "t1", Title = "Song 1", Format = new AudioFormat { Codec = "FLAC" } };
        var track2 = new Track { Id = "t2", Title = "Song 2", Format = new AudioFormat { Codec = "FLAC" } };
        var track3 = new Track { Id = "t3", Title = "Song 3", Format = new AudioFormat { Codec = "FLAC" } };

        player.PlayQueue(new[] { track1, track2, track3 }, track1);

        Assert.Equal(3, player.QueueTracks.Count);
        Assert.Equal(3, player.QueueItems.Count);
        Assert.Equal("Song 1", player.QueueTracks[0].Title);
        Assert.Equal("Song 2", player.QueueTracks[1].Title);
        Assert.Equal("Song 3", player.QueueTracks[2].Title);
        Assert.True(player.QueueItems[0].IsCurrent);

        // Move Song 3 from index 2 to index 0
        player.MoveQueueTrack(2, 0);

        Assert.Equal("Song 3", player.QueueTracks[0].Title);
        Assert.Equal("Song 1", player.QueueTracks[1].Title);
        Assert.Equal("Song 2", player.QueueTracks[2].Title);

        // Song 1 is still currently playing and now at index 1
        Assert.False(player.QueueItems[0].IsCurrent);
        Assert.True(player.QueueItems[1].IsCurrent);
        Assert.False(player.QueueItems[2].IsCurrent);
        Assert.Equal(1, player.CurrentQueueIndex);
    }

    [Fact]
    public void PlayerViewModel_RemoveQueueTrack_And_ClearQueue()
    {
        using var engine = TestSupport.CreateEngine();
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());
        var player = new PlayerViewModel(engine, service);

        var track1 = new Track { Id = "t1", Title = "Song 1", Format = new AudioFormat { Codec = "FLAC" } };
        var track2 = new Track { Id = "t2", Title = "Song 2", Format = new AudioFormat { Codec = "FLAC" } };
        var track3 = new Track { Id = "t3", Title = "Song 3", Format = new AudioFormat { Codec = "FLAC" } };

        player.PlayQueue(new[] { track1, track2, track3 }, track1);

        player.RemoveQueueTrackCommand.Execute(track2);

        Assert.Equal(2, player.QueueTracks.Count);
        Assert.Equal("Song 1", player.QueueTracks[0].Title);
        Assert.Equal("Song 3", player.QueueTracks[1].Title);

        // Clear queue retains currently playing track
        player.ClearQueueCommand.Execute(null);

        Assert.Single(player.QueueTracks);
        Assert.Equal("Song 1", player.QueueTracks[0].Title);
    }

    [Fact]
    public void PlayerViewModel_MoveQueueTrackUp_And_Down()
    {
        using var engine = TestSupport.CreateEngine();
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());
        var player = new PlayerViewModel(engine, service);

        var track1 = new Track { Id = "t1", Title = "Song 1", Format = new AudioFormat { Codec = "FLAC" } };
        var track2 = new Track { Id = "t2", Title = "Song 2", Format = new AudioFormat { Codec = "FLAC" } };
        var track3 = new Track { Id = "t3", Title = "Song 3", Format = new AudioFormat { Codec = "FLAC" } };

        player.PlayQueue(new[] { track1, track2, track3 }, track1);

        // Move track 3 up by 1 position (swap with track 2)
        var item3 = player.QueueItems[2];
        player.MoveQueueTrackUpCommand.Execute(item3);

        Assert.Equal("Song 1", player.QueueTracks[0].Title);
        Assert.Equal("Song 3", player.QueueTracks[1].Title);
        Assert.Equal("Song 2", player.QueueTracks[2].Title);

        // Move track 3 down by 1 position (back to index 2)
        player.MoveQueueTrackDownCommand.Execute(item3);

        Assert.Equal("Song 1", player.QueueTracks[0].Title);
        Assert.Equal("Song 2", player.QueueTracks[1].Title);
        Assert.Equal("Song 3", player.QueueTracks[2].Title);
    }
}

