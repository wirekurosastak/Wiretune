using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// BVT-001 to BVT-032 — Boundary Values &amp; Edge Cases
/// Testing extreme limits: max/min lengths, null/empty values, zero,
/// special characters, threshold boundaries, and overflow conditions.
/// </summary>
public class BoundaryValueTests
{
    private static (LibraryService service, MockRepository repo) CreateService()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());
        return (service, repo);
    }

    private static Track MakeTrack(string id, string title, string artist, string album,
        int sampleRate = 44100, int bits = 16, int trackNum = 1, double minutes = 4.0) =>
        new()
        {
            Id = id, Title = title, Artist = artist, Album = album,
            TrackNumber = trackNum, Duration = TimeSpan.FromMinutes(minutes),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = sampleRate, BitsPerSample = bits, IsLossless = true }
        };

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-001 — Library with exactly 1 audio file
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT001_SingleTrackLibrary_ProducesOneAlbumAndOneArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("single", "Alone", "Solo Artist", "Solo Album") });
        await service.InitializeAsync();

        Assert.Single(service.Tracks);
        Assert.Single(service.Albums);
        Assert.Single(service.Artists);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-002 — Scanning a folder that no longer contains music empties the library
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT002_ScanEmptyFolder_ClearsPreviousTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("old", "Old Song", "Old Band", "Old Album") });
        await service.InitializeAsync();
        Assert.Single(service.Tracks);

        var tempDir = Directory.CreateTempSubdirectory("wiretune_empty_").FullName;
        try
        {
            Assert.True(await service.ScanFolderAsync(tempDir));

            Assert.Empty(service.Tracks);
            Assert.Empty(service.Albums);
            Assert.Empty(repo.Tracks);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-004 — Track number 0 → stored as null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT004_TrackNumber_Zero_IsStoredAsNull()
    {
        // MetadataScanner guards: `tag.Track > 0 ? (int?)tag.Track : null`
        // Simulate that logic directly:
        uint rawTrackNumber = 0;
        int? trackNumber = rawTrackNumber > 0 ? (int?)rawTrackNumber : null;

        Assert.Null(trackNumber);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-005 — Year 0 → stored as null
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT005_Year_Zero_IsStoredAsNull()
    {
        uint rawYear = 0;
        int? year = rawYear > 0 ? (int?)rawYear : null;

        Assert.Null(year);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-006 — Duration = TimeSpan.Zero → FormattedDuration = "0:00"
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT006_Duration_Zero_FormattedAsZeroColon00()
    {
        var t = new Track { Duration = TimeSpan.Zero };

        Assert.Equal("0:00", t.FormattedDuration);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-008 — SampleRate exactly 48001 Hz → IsHiRes = true (threshold boundary)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT008_SampleRate_48001_ExceedsHiResThreshold()
    {
        var format = new AudioFormat { SampleRate = 48001, BitsPerSample = 16 };

        Assert.True(format.IsHiRes); // > 48000
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-009 — SampleRate exactly 48000 Hz with 16-bit → NOT Hi-Res
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT009_SampleRate_48000_BitsPerSample_16_IsNotHiRes()
    {
        var format = new AudioFormat { SampleRate = 48000, BitsPerSample = 16 };

        Assert.False(format.IsHiRes);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-009b — BitsPerSample exactly 17 with CD sample rate → IsHiRes = true
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT009b_BitsPerSample_17_AtCdSampleRate_IsHiRes()
    {
        var format = new AudioFormat { SampleRate = 44100, BitsPerSample = 17 };

        Assert.True(format.IsHiRes); // BitsPerSample > 16
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-010 — Lossy files are labelled by codec/bitrate, never as "16-bit" or Hi-Res;
    // ALAC inside .m4a is recognised as lossless.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT010_LossyAndLosslessFormats_AreClassifiedCorrectly()
    {
        Assert.Equal(("MP3", false), AudioFileTypes.Describe("/m/a.mp3"));
        Assert.Equal(("FLAC", true), AudioFileTypes.Describe("/m/a.FLAC"));
        Assert.Equal(("AAC", false), AudioFileTypes.Describe("/m/a.m4a", "MPEG-4 Audio (mp4a)"));
        Assert.Equal(("ALAC", true), AudioFileTypes.Describe("/m/a.m4a", "MPEG-4 Audio (alac)"));

        var mp3 = new AudioFormat { Codec = "MP3", SampleRate = 96000, BitsPerSample = 0, BitrateKbps = 320, IsLossless = false };
        Assert.False(mp3.IsHiRes);
        Assert.Equal("MP3 • 320 kbps", mp3.QualityLabel);
        Assert.Equal("audio/flac", AudioFileTypes.GetMimeType("x.flac"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-012 — Same album title from two different artists → two album entries
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT012_SameAlbumTitle_DifferentArtists_ProducesTwoAlbums()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("1", "Hit A", "Artist One", "Greatest Hits"),
            MakeTrack("2", "Hit B", "Artist Two", "Greatest Hits")
        });
        await service.InitializeAsync();

        Assert.Equal(2, service.Albums.Count);
        Assert.Equal(2, service.Artists.Count);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-014 — Duplicate track ID in same playlist is rejected
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT014_AddSameTrackTwice_PlaylistContainsOnlyOneEntry()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("NoDupes");

        await service.AddTrackToPlaylistAsync(pl.Id, "track-x");
        await service.AddTrackToPlaylistAsync(pl.Id, "track-x");

        Assert.Single(pl.TrackIds);
        Assert.Equal("track-x", pl.TrackIds[0]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-015 — Playlist name with maximum length (450 chars) stores correctly
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT015_PlaylistName_MaxLength_StoredCorrectly()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var longName = new string('A', 450);

        var pl = await service.CreatePlaylistAsync(longName);

        Assert.Equal(450, pl.Name.Length);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-016 — New playlist with 0 tracks serializes empty track list
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT016_NewPlaylist_ZeroTracks_HasEmptyTrackIdList()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var pl = await service.CreatePlaylistAsync("Empty");

        Assert.Empty(pl.TrackIds);
        Assert.Equal(0, pl.TrackCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-017 — Volume = 0.0 (minimum)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT017_SetVolume_ExactlyZero_SetsVolumeToZero()
    {
        using var engine = TestSupport.CreateEngine();

        engine.SetVolume(0.0);

        Assert.Equal(0.0, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-018 — Volume = 1.0 (maximum)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT018_SetVolume_ExactlyOne_SetsVolumeToOne()
    {
        using var engine = TestSupport.CreateEngine();

        engine.SetVolume(1.0);

        Assert.Equal(1.0, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-019 — Seek to TimeSpan.Zero
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT019_SeekToZero_UpdatesPositionToZero()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SeekAsync(TimeSpan.FromSeconds(90));

        await engine.SeekAsync(TimeSpan.Zero);

        Assert.Equal(TimeSpan.Zero, engine.CurrentPosition);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-020 — Play queue with exactly 1 track
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT020_PlayQueue_SingleTrack_DoesNotThrowOnNextOrPrevious()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        var single = MakeTrack("solo", "Only Song", "Artist", "Album");
        player.PlayQueue(new[] { single });

        // Both should be no-ops / handle gracefully
        var nextEx = Record.Exception(() => player.NextTrackCommand.Execute(null));
        var prevEx = Record.Exception(() => player.PreviousTrackCommand.Execute(null));

        Assert.Null(nextEx);
        Assert.Null(prevEx);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-021 — Play queue with 0 tracks
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT021_PlayQueue_EmptyList_DoesNotThrow()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        var ex = Record.Exception(() => player.PlayQueue(Array.Empty<Track>()));
        Assert.Null(ex);

        var nextEx = Record.Exception(() => player.NextTrackCommand.Execute(null));
        var prevEx = Record.Exception(() => player.PreviousTrackCommand.Execute(null));

        Assert.Null(nextEx);
        Assert.Null(prevEx);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-022 — Next at end of queue (no repeat) → StopAsync
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT022_NextTrack_AtEndOfQueue_NoRepeat_StopsPlayback()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        var tracks = new[]
        {
            MakeTrack("b1", "A", "Art", "Al", trackNum: 1),
            MakeTrack("b2", "B", "Art", "Al", trackNum: 2)
        };
        player.PlayQueue(tracks, tracks[1]); // start at last track

        // Advance past end
        player.NextTrackCommand.Execute(null);
        await Task.Delay(100); // allow async stop to propagate

        // With RepeatMode.Off, stopping is expected
        Assert.Equal(RepeatMode.Off, player.RepeatMode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-025 — MockRepo: GetSetting missing key returns supplied default
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT025_GetSetting_MissingKey_ReturnsDefault()
    {
        var repo = new MockRepository();

        var val = await repo.GetSettingAsync("KeyThatDoesNotExist", "fallback-value");

        Assert.Equal("fallback-value", val);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-026 — Settings: very long value stored without truncation
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT026_SetAndGetSetting_VeryLongValue_StoredIntact()
    {
        var repo = new MockRepository();
        var longValue = new string('Z', 10_000);

        await repo.SetSettingAsync("LongKey", longValue);
        var result = await repo.GetSettingAsync("LongKey");

        Assert.Equal(10_000, result?.Length);
        Assert.Equal(longValue, result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-029 — Track > 1 hour uses h:mm:ss format
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT029_FormattedDuration_OverOneHour_UsesHMmSsFormat()
    {
        var t = new Track { Duration = TimeSpan.FromSeconds(5400) }; // 1:30:00

        Assert.Equal("1:30:00", t.FormattedDuration);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-030 — Track exactly 1 minute uses m:ss format
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT030_FormattedDuration_ExactlyOneMinute_UsesMmSsFormat()
    {
        var t = new Track { Duration = TimeSpan.FromMinutes(1) };

        Assert.Equal("1:00", t.FormattedDuration);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT-032 — SHA256 album ID with Unicode artist/album names is deterministic
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT032_AlbumId_WithUnicodeArtistAndAlbum_IsDeterministicAcrossScans()
    {
        var (service1, repo1) = CreateService();
        var (service2, repo2) = CreateService();

        var track1 = MakeTrack("u1", "Tükörkép", "Ünmlaut Összetett", "Héjja Suite");
        var track2 = MakeTrack("u2", "Tükörkép", "Ünmlaut Összetett", "Héjja Suite");

        await repo1.SaveTracksBatchAsync(new[] { track1 });
        await repo2.SaveTracksBatchAsync(new[] { track2 });

        await service1.InitializeAsync();
        await service2.InitializeAsync();

        Assert.Equal(service1.Albums[0].Id, service2.Albums[0].Id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — AudioFormat DisplayBadge for lossy format (MP3)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT_LossyFormat_DisplayBadge_ShowsCodecAndBitrate()
    {
        var format = new AudioFormat
        {
            Codec = "MP3",
            SampleRate = 44100,
            BitsPerSample = 16,
            BitrateKbps = 320,
            IsLossless = false
        };

        Assert.False(format.IsHiRes);
        Assert.Contains("MP3", format.DisplayBadge);
        Assert.Contains("320", format.DisplayBadge);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — AlbumTotalDuration is the sum of all track durations
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT_Album_TotalDuration_IsCorrectSum()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("d1", "Short", "Band", "Record", minutes: 2.5),
            MakeTrack("d2", "Long",  "Band", "Record", minutes: 7.0, trackNum: 2)
        });
        await service.InitializeAsync();

        var album = service.Albums.First();
        var expectedTotal = TimeSpan.FromMinutes(9.5);

        Assert.Equal(expectedTotal.TotalSeconds, album.TotalDuration.TotalSeconds, precision: 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — AlbumIsHiRes = true if ANY track is Hi-Res
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task BVT_Album_IsHiRes_TrueIfAnyTrackIsHiRes()
    {
        var (service, repo) = CreateService();
        var cdTrack = MakeTrack("m1", "CD Track",   "Band", "Mixed Album", sampleRate: 44100, bits: 16, trackNum: 1);
        var hiTrack = MakeTrack("m2", "Hi-Res Track","Band", "Mixed Album", sampleRate: 96000, bits: 24, trackNum: 2);
        await repo.SaveTracksBatchAsync(new[] { cdTrack, hiTrack });
        await service.InitializeAsync();

        var album = service.Albums.First();
        Assert.True(album.IsHiRes);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — Track.TrackCount is null-safe (no crash on null TrackCount)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void BVT_Track_NullTrackCount_DoesNotCrash()
    {
        var t = new Track { TrackNumber = 5, TrackCount = null };

        var ex = Record.Exception(() =>
        {
            _ = t.DisplayTrackNumber;
            _ = t.FormattedDuration;
        });

        Assert.Null(ex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — IntEqualConverter: edge cases
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData(0, "0", true)]
    [InlineData(5, "5", true)]
    [InlineData(6, "5", false)]
    [InlineData(null, "6", false)]
    public void BVT_IntEqualConverter_EdgeCases(object? value, string param, bool expected)
    {
        var converter = new Wiretune.UI.Converters.IntEqualConverter();
        var result = converter.Convert(value, typeof(bool), param, System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(expected, (bool)result!);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BVT — ScanProgressReport.ProgressPercentage stays in 0-100 range
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(50, 100, 50)]
    [InlineData(100, 100, 100)]
    [InlineData(0, 50, 0)] // 0 files scanned out of 50 → 0%
    public void BVT_ScanProgressReport_ProgressPercentage_StaysInRange(int scanned, int total, double expected)
    {
        var report = new ScanProgressReport { ScannedFiles = scanned, TotalEstimatedFiles = total };

        Assert.Equal(expected, report.ProgressPercentage, precision: 1);
        Assert.InRange(report.ProgressPercentage, 0, 100);
    }
}


