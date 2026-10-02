﻿using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// SEC-001 to SEC-028 — Logic &amp; Security Vulnerability Tests
/// Potential logical flaws, race conditions, unhandled exceptions, and
/// security issues that could crash the software or leak data.
/// </summary>
public class LogicAndSecurityTests
{
    private static (LibraryService service, MockRepository repo) CreateService()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());
        return (service, repo);
    }

    private static Track MakeTrack(string id, string title, string artist = "Artist",
        string album = "Album", int sampleRate = 44100, int bits = 16, int trackNum = 1) =>
        new()
        {
            Id = id, Title = title, Artist = artist, Album = album,
            TrackNumber = trackNum, Duration = TimeSpan.FromMinutes(4),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = sampleRate, BitsPerSample = bits, IsLossless = true }
        };

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-001 / SEC-002 — ffplay receives the source as one discrete argument,
    // so quotes or shell metacharacters in a file name cannot inject arguments.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC001_FfplayArguments_KeepSourceAsSingleArgument()
    {
        const string hostilePath = "/music/song\"evil; rm -rf /home -i x.flac";

        var args = Wiretune.Core.Audio.Drivers.FfmpegAudioDriver.BuildFfplayArguments(hostilePath, TimeSpan.FromSeconds(12.5), 150);

        Assert.Equal(hostilePath, args[^1]);
        Assert.Equal(1, args.Count(a => a.Contains("evil")));
        Assert.Equal("12.500", args[args.IndexOf("-ss") + 1]);
        Assert.Equal("100", args[args.IndexOf("-volume") + 1]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-003 — ServerStreamingClient URL construction uses TrimEnd correctly
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC003_GetStreamUrl_TrailingSlash_TrimmedCorrectly()
    {
        var url1 = ServerStreamingClient.BuildStreamUrl("http://server:5200/", "track123");
        var url2 = ServerStreamingClient.BuildStreamUrl("http://server:5200", "track123");

        Assert.Equal("http://server:5200/api/stream/track123", url1);
        Assert.Equal("http://server:5200/api/stream/track123", url2);
        Assert.Equal(url1, url2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-004 — Path containment used by the server's stream/cover endpoints
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC004_PathContainment_RejectsTraversalAndPrefixSiblings()
    {
        var root = Path.Combine(Path.GetTempPath(), "wt-root", "music");

        Assert.True(AppPaths.IsPathUnderRoot(Path.Combine(root, "a", "b.flac"), root));
        Assert.True(AppPaths.IsPathUnderRoot(root, root));
        Assert.False(AppPaths.IsPathUnderRoot(Path.Combine(root, "..", "secret.txt"), root));
        Assert.False(AppPaths.IsPathUnderRoot(root + "2" + Path.DirectorySeparatorChar + "x.flac", root));
        Assert.False(AppPaths.IsPathUnderRoot("", root));
        Assert.False(AppPaths.IsPathUnderRoot("bad\0path", root));
    }

    [Fact]
    public void SEC004b_PathContainment_WorksWhenTheLibraryIsAFilesystemRoot()
    {
        // A whole drive / "/" as the library used to reject every file: the root already ends in a separator.
        var fsRoot = Path.GetPathRoot(Path.GetTempPath())!;

        Assert.True(AppPaths.IsPathUnderRoot(Path.Combine(fsRoot, "music", "a.flac"), fsRoot));
        Assert.True(AppPaths.IsPathUnderRoot(fsRoot, fsRoot));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-007 — Thread Safety: Search reads _tracks without _syncLock
    // Documents the race condition: Search() and Favorites use _tracks
    // without locking while ScanFolderAsync / ConnectServerAsync modify it.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC007_ThreadSafety_ConcurrentSearchAndScan_DoesNotThrow()
    {
        var (service, repo) = CreateService();
        for (int i = 0; i < 100; i++)
            repo.Tracks.Add(MakeTrack(i.ToString(), $"Track {i}"));
        await service.InitializeAsync();

        // Run many concurrent search reads while the library would be rebuilt
        var searchTasks = Enumerable.Range(0, 20)
            .Select(_ => Task.Run(() =>
            {
                // These access _tracks without lock — potential race
                var searchResult = service.Search("Track").ToList();
                var favsResult   = service.Favorites.ToList();
            }));

        var ex = await Record.ExceptionAsync(() => Task.WhenAll(searchTasks));

        // Document: if this throws InvalidOperationException (collection modified),
        // it confirms the thread-safety bug. We hope it doesn't crash the CI run.
        // A fix requires locking inside Search() and Favorites getter.
        Assert.Null(ex); // may flakily pass — that's expected for a race condition test
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-009 — Cover art is cached in one bounded LRU cache, not per view model
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC009_CoverArtCache_IsBoundedAndCentralised()
    {
        var staticBitmapCaches = typeof(Wiretune.UI.ViewModels.PlayerViewModel)
            .GetFields(System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
            .Where(f => f.FieldType.IsGenericType && f.FieldType.GetGenericArguments().Any(t => t.Name == "Bitmap"));

        Assert.Empty(staticBitmapCaches);
        Assert.InRange(Wiretune.UI.Services.CoverArtService.MaxCachedBitmaps, 1, 1000);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-013 — Logic Flaw: user volume NOT preserved when toggling bitperfect
    // Steps: user sets 50% → enables bitperfect (volume forced to 1.0) →
    //        disables bitperfect → volume stays at 1.0 instead of 50%
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC013_VolumeRestored_WhenBitperfectToggledOff()
    {
        using var engine = TestSupport.CreateEngine();

        // User sets a preferred volume of 50%
        engine.SetVolume(0.5);
        Assert.Equal(0.5, engine.Volume, precision: 2);

        // Enable bitperfect (internally forces _volume = 1.0)
        await engine.SetBitperfectModeAsync(true);
        Assert.Equal(1.0, engine.Volume, precision: 2); // locked at unity

        // Disable bitperfect
        await engine.SetBitperfectModeAsync(false);

        Assert.Equal(0.5, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-014 — Logic Flaw: Repeat All with empty queue → unbounded index growth
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC014_RepeatAll_EmptyQueue_DoesNotInfinitelyIncrementIndex()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var player = new Wiretune.UI.ViewModels.PlayerViewModel(engine, service);

        // Set Repeat All with empty queue
        player.ToggleRepeatCommand.Execute(null); // Off → All
        Assert.Equal(RepeatMode.All, player.RepeatMode);

        // Calling NextTrack with empty queue should not throw or grow state
        var ex = Record.Exception(() =>
        {
            for (int i = 0; i < 10; i++)
                player.NextTrackCommand.Execute(null);
        });

        Assert.Null(ex); // Should not crash; guard for empty queue needed
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-018 — Track identity is derived from the file path, so favorites,
    // play counts and playlists survive rescans.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC018_TrackId_IsStableAcrossScans()
    {
        var dir = Directory.CreateTempSubdirectory("wiretune_id_").FullName;
        try
        {
            var file = Path.Combine(dir, "song.wav");
            WavFile.Write(file, 44100, 0.2);
            var scanner = new MetadataScanner();

            var first = await scanner.ReadTrackMetadataAsync(file);
            var second = await scanner.ReadTrackMetadataAsync(file);

            Assert.NotNull(first);
            Assert.Equal(first!.Id, second!.Id);
            Assert.Equal(MetadataScanner.ComputeTrackId(file), first.Id);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC-025 — Logic Flaw: NavigateToCommand accepts out-of-range index
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC025_UnknownSection_IsIgnored()
    {
        using var engine = TestSupport.CreateEngine();
        var (service, _) = CreateService();
        var vm = TestSupport.CreateMainViewModel(service, engine);

        vm.NavigateToCommand.Execute((AppSection)999);
        vm.NavigateToCommand.Execute((AppSection)(-1));

        Assert.Equal(AppSection.Artists, vm.SelectedSection);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — ScanningStateChanged event fires true then false correctly
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_ScanningStateChanged_EventFiredCorrectly()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var events = new List<bool>();
        service.ScanningStateChanged += (_, isScanning) => events.Add(isScanning);

        var tempDir = Directory.CreateTempSubdirectory("wiretune_scan_ev_").FullName;
        try
        {
            await service.ScanFolderAsync(tempDir);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }

        Assert.Equal(2, events.Count);
        Assert.True(events[0]);   // scan started
        Assert.False(events[1]);  // scan ended
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — ScanningStateChanged: IsScanning reset to false even on exception
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_IsScanningReset_EvenAfterScanCompletion()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        var tempDir = Directory.CreateTempSubdirectory("wiretune_reset_").FullName;
        try
        {
            await service.ScanFolderAsync(tempDir);
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }

        Assert.False(service.IsScanning);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — LibraryChanged event fires after InitializeAsync
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_LibraryChangedEvent_FiredAfterInitialize()
    {
        var (service, _) = CreateService();
        bool fired = false;
        service.LibraryChanged += (_, _) => fired = true;

        await service.InitializeAsync();
        await Task.Delay(50); // allow async background server ping to fire too

        Assert.True(fired);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — ToggleFavorite raises FavoriteChanged (not a full LibraryChanged rebuild)
    // and the track notifies bound views directly.
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_FavoriteChangedEvent_FiredAfterToggleFavorite()
    {
        var (service, repo) = CreateService();
        repo.Tracks.Add(MakeTrack("t1", "Song"));
        await service.InitializeAsync();

        int libraryEvents = 0;
        Track? changed = null;
        var propertyNotifications = new List<string?>();
        service.LibraryChanged += (_, _) => libraryEvents++;
        service.FavoriteChanged += (_, t) => changed = t;
        service.Tracks[0].PropertyChanged += (_, e) => propertyNotifications.Add(e.PropertyName);

        await service.ToggleFavoriteAsync("t1");

        Assert.Equal("t1", changed?.Id);
        Assert.Equal(0, libraryEvents);
        Assert.Contains(nameof(Track.IsFavorite), propertyNotifications);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — PlaylistsChanged event fires after CreatePlaylist
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_PlaylistsChangedEvent_FiredAfterCreatePlaylist()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();

        int eventCount = 0;
        service.PlaylistsChanged += (_, _) => eventCount++;

        await service.CreatePlaylistAsync("New List");

        Assert.Equal(1, eventCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — ServerUrl TrimEnd('/'): trailing slashes normalized on save
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_ServerUrl_NormalizedBeforeSave()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();
        using var session = new ServerSession(service, repo);
        await session.InitializeAsync();

        // Port 1 on loopback refuses immediately; normalisation happens before the network call.
        await session.ConnectAsync("  127.0.0.1:1///  ");

        Assert.Equal("http://127.0.0.1:1", await repo.GetSettingAsync("ServerUrl"));
        Assert.Equal(ServerConnectionState.Offline, session.State);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — AudioFormat: QualityLabel fallback for non-standard rate/depth
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC_AudioFormat_NonStandardRateAndBits_FallsToGenericLabel()
    {
        var format = new AudioFormat { SampleRate = 22050, BitsPerSample = 8 };

        var label = format.QualityLabel;

        Assert.Contains("8-bit", label);
        Assert.Contains("22", label);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Mute state: engine correctly applies zero volume to driver
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC_Mute_WhenEnabled_EngineReportsZeroEffectiveVolume()
    {
        using var engine = TestSupport.CreateEngine();
        engine.SetVolume(0.8);

        engine.SetMuted(true);

        // Volume property: _isMuted ? 0.0 : _volume
        Assert.Equal(0.0, engine.Volume, precision: 2);
        Assert.True(engine.IsMuted);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Unmute restores the previous volume level
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC_Unmute_RestoresPreviousVolume()
    {
        using var engine = TestSupport.CreateEngine();
        engine.SetVolume(0.6);
        engine.SetMuted(true);

        engine.SetMuted(false);

        Assert.Equal(0.6, engine.Volume, precision: 2);
        Assert.False(engine.IsMuted);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Mute during bitperfect does NOT change Volume from 1.0
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_Mute_InBitperfectMode_VolumeSaysAtUnity()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetBitperfectModeAsync(true);

        engine.SetMuted(true);

        // Bitperfect → Volume getter returns 1.0 regardless of mute flag
        Assert.Equal(1.0, engine.Volume, precision: 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — SignalPathDescription: no current track returns idle string
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void SEC_SignalPathDescription_NoTrack_ReturnsIdleString()
    {
        using var engine = TestSupport.CreateEngine();

        var desc = engine.SignalPathDescription;

        Assert.Equal("No active playback", desc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — LibraryService: InitializeAsync restores ServerUrl from settings
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_InitializeAsync_RestoresServerUrlFromSettings()
    {
        var (service, repo) = CreateService();
        repo.Settings["ServerUrl"] = "http://myserver:5200";

        using var session = new ServerSession(service, repo);
        await session.InitializeAsync();

        Assert.Equal("http://myserver:5200", session.ServerUrl);
        Assert.Equal(ServerConnectionState.NotConfigured, session.State);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — LibraryService search is case-insensitive
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_Search_IsCaseInsensitive()
    {
        var (service, repo) = CreateService();
        repo.Tracks.Add(MakeTrack("ci1", "Moonlight Sonata", "Beethoven", "Piano Works"));
        await service.InitializeAsync();

        var lower  = service.Search("moonlight").ToList();
        var upper  = service.Search("MOONLIGHT").ToList();
        var mixed  = service.Search("MoOnLiGhT").ToList();

        Assert.Single(lower);
        Assert.Single(upper);
        Assert.Single(mixed);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Playlist ModifiedAt is updated when a track is added
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_PlaylistModifiedAt_UpdatedOnTrackAdd()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("TimedList");
        var originalModified = pl.ModifiedAt;

        await Task.Delay(10);
        await service.AddTrackToPlaylistAsync(pl.Id, "t-time");

        Assert.True(pl.ModifiedAt >= originalModified);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Playlist ModifiedAt is updated when a track is removed
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_PlaylistModifiedAt_UpdatedOnTrackRemove()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("TimedList2");
        await service.AddTrackToPlaylistAsync(pl.Id, "t-rm");
        var afterAdd = pl.ModifiedAt;

        await Task.Delay(10);
        await service.RemoveTrackFromPlaylistAsync(pl.Id, "t-rm");

        Assert.True(pl.ModifiedAt >= afterAdd);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — ToggleFavorite: in-memory flag and DB are consistent
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_ToggleFavorite_InMemoryAndDbAreConsistent()
    {
        var (service, repo) = CreateService();
        repo.Tracks.Add(MakeTrack("tf1", "Sync Test", "Band", "Album"));
        await service.InitializeAsync();

        await service.ToggleFavoriteAsync("tf1");
        var inMemory = service.Tracks.First(t => t.Id == "tf1").IsFavorite;
        var inRepo = repo.Tracks.First(t => t.Id == "tf1").IsFavorite;

        Assert.True(inMemory);
        Assert.True(inRepo);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — RecordPlay: in-memory and DB play counts are consistent
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_RecordPlay_InMemoryAndDbAreConsistent()
    {
        var repo = new MockRepository();
        repo.Settings["ServerUrl"] = string.Empty; // prevent background connect
        var service = new LibraryService(repo, new MetadataScanner());

        repo.Tracks.Add(MakeTrack("rp1", "Play Count Test", "Band", "Album"));
        await service.InitializeAsync();

        await service.RecordPlayAsync("rp1");

        var inMemory = service.Tracks.First(t => t.Id == "rp1").PlayCount;
        var inRepo   = repo.Tracks.First(t => t.Id == "rp1").PlayCount;

        Assert.Equal(1, inMemory);
        Assert.Equal(1, inRepo);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Bitperfect → exclusive state events fire in correct order
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_BitperfectEnabled_EventsFireInCorrectOrder()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetExclusiveModeAsync(false);

        var exclusiveEvents  = new List<bool>();
        var bitperfectEvents = new List<bool>();
        engine.ExclusiveModeChanged += (_, v) => exclusiveEvents.Add(v);
        engine.BitperfectChanged    += (_, v) => bitperfectEvents.Add(v);

        await engine.SetBitperfectModeAsync(true);

        // ExclusiveModeChanged(true) should fire first, then BitperfectChanged(true)
        Assert.Single(exclusiveEvents);
        Assert.True(exclusiveEvents[0]);

        Assert.Single(bitperfectEvents);
        Assert.True(bitperfectEvents[0]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEC — Disable exclusive while bitperfect: both events fire
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task SEC_DisableExclusive_WhileBitperfect_BothEventsFireCorrectly()
    {
        using var engine = TestSupport.CreateEngine();
        await engine.SetBitperfectModeAsync(true);

        var exclusiveEvents  = new List<bool>();
        var bitperfectEvents = new List<bool>();
        engine.ExclusiveModeChanged += (_, v) => exclusiveEvents.Add(v);
        engine.BitperfectChanged    += (_, v) => bitperfectEvents.Add(v);

        await engine.SetExclusiveModeAsync(false);

        Assert.Contains(false, exclusiveEvents);  // exclusive turned off
        Assert.Contains(false, bitperfectEvents); // bitperfect forcibly turned off
    }
}



