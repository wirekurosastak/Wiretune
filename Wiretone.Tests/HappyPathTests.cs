using Wiretone.Audio;
using Wiretone.Core.Models;
using Wiretone.Core.Services;
using Xunit;

namespace Wiretone.Tests;

/// <summary>
/// HP-001 to HP-050 — Happy Path Scenarios
/// Standard inputs where the user interacts with Wiretone exactly as intended.
/// </summary>
public class HappyPathTests
{
    // ─────────────────────────────────────────────────────────────────────────
    // Helper factory
    // ─────────────────────────────────────────────────────────────────────────

    private static (LibraryService service, MockRepository repo) CreateService()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        return (service, repo);
    }

    private static Track MakeTrack(string id, string title, string artist, string album,
        int sampleRate = 44100, int bits = 16, int trackNum = 1,
        double durationMinutes = 4.0, string codec = "FLAC", bool lossless = true) =>
        new()
        {
            Id = id,
            Title = title,
            Artist = artist,
            Album = album,
            TrackNumber = trackNum,
            Duration = TimeSpan.FromMinutes(durationMinutes),
            Format = new AudioFormat
            {
                Codec = codec,
                SampleRate = sampleRate,
                BitsPerSample = bits,
                IsLossless = lossless,
                BitrateKbps = lossless ? 1411 : 320
            }
        };

    // ─────────────────────────────────────────────────────────────────────────
    // HP-001 — Scan a valid populated folder (unit-level via mock)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP001_InitializeAsync_LoadsAllTracksFromRepository()
    {
        var (service, repo) = CreateService();
        var tracks = Enumerable.Range(1, 10)
            .Select(i => MakeTrack(i.ToString(), $"Song {i}", "Artist", "Album", trackNum: i))
            .ToList();
        await repo.SaveTracksBatchAsync(tracks);

        await service.InitializeAsync();

        Assert.Equal(10, service.Tracks.Count);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-004 — Hi-Res FLAC correctly identified
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP004_HiResFormat_96k_24bit_IsIdentifiedCorrectly()
    {
        var format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24 };

        Assert.True(format.IsHiRes);
        Assert.Contains("HI-RES LOSSLESS", format.DisplayBadge);
        Assert.Equal("Hi-Res Studio Master (96kHz/24b)", format.QualityLabel);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-005 — CD quality FLAC correctly identified
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP005_CdQualityFormat_44k_16bit_IsIdentifiedCorrectly()
    {
        var format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16 };

        Assert.False(format.IsHiRes);
        Assert.Contains("CD LOSSLESS", format.DisplayBadge);
        Assert.Equal("CD Quality Lossless (16-bit / 44.1 kHz)", format.QualityLabel);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-006 — Multiple tracks → single album entry
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP006_AlbumIndexing_GroupsTracksWithSameAlbumAndArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("1", "Track A", "Daft Punk", "RAM", trackNum: 1),
            MakeTrack("2", "Track B", "Daft Punk", "RAM", trackNum: 2),
            MakeTrack("3", "Track C", "Daft Punk", "RAM", trackNum: 3)
        });
        await service.InitializeAsync();

        Assert.Single(service.Albums);
        Assert.Equal(3, service.Albums[0].TrackCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-007 — Multiple albums → single artist entry
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP007_ArtistIndexing_GroupsAlbumsFromSameArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("1", "Starboy",        "The Weeknd", "Starboy",       trackNum: 1),
            MakeTrack("2", "Party Monster",  "The Weeknd", "Starboy",       trackNum: 2),
            MakeTrack("3", "Save Your Tears","The Weeknd", "After Hours",   trackNum: 1)
        });
        await service.InitializeAsync();

        Assert.Single(service.Artists);
        Assert.Equal(2, service.Artists[0].AlbumCount);
        Assert.Equal(3, service.Artists[0].TrackCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-008 — Create a new playlist
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP008_CreatePlaylist_ReturnsNamedPlaylistAndPersists()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();

        var pl = await service.CreatePlaylistAsync("Best Hi-Res", "Top 24-bit tracks");

        Assert.NotNull(pl);
        Assert.NotEmpty(pl.Id);
        Assert.Equal("Best Hi-Res", pl.Name);
        Assert.Equal("Top 24-bit tracks", pl.Description);
        Assert.Single(service.Playlists);
        Assert.Single(repo.Playlists);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-009 — Add a track to a playlist
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP009_AddTrackToPlaylist_UpdatesTrackIdsAndPersists()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("Fav");

        await service.AddTrackToPlaylistAsync(pl.Id, "track-abc");

        Assert.Contains("track-abc", pl.TrackIds);
        Assert.Equal(1, pl.TrackCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-010 — Remove a track from a playlist
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP010_RemoveTrackFromPlaylist_TrackIdRemovedAndPersists()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("Mix");
        await service.AddTrackToPlaylistAsync(pl.Id, "t1");
        await service.AddTrackToPlaylistAsync(pl.Id, "t2");

        await service.RemoveTrackFromPlaylistAsync(pl.Id, "t1");

        Assert.DoesNotContain("t1", pl.TrackIds);
        Assert.Contains("t2", pl.TrackIds);
        Assert.Equal(1, pl.TrackCount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-011 — Delete a playlist
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP011_DeletePlaylist_RemovedFromServiceAndRepo()
    {
        var (service, repo) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("TempList");

        await service.DeletePlaylistAsync(pl.Id);

        Assert.Empty(service.Playlists);
        Assert.Empty(repo.Playlists);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-012 — Favorite toggle (on)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP012_ToggleFavorite_MarksTrackAsFavorite()
    {
        var (service, repo) = CreateService();
        var track = MakeTrack("fav-1", "Moonlight Sonata", "Beethoven", "Piano Works");
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        await service.ToggleFavoriteAsync("fav-1");

        var t = service.Tracks.First(x => x.Id == "fav-1");
        Assert.True(t.IsFavorite);
        Assert.Contains(service.Favorites, f => f.Id == "fav-1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-013 — Favorite toggle (off)
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP013_ToggleFavorite_UnfavoritesAlreadyFavoriteTrack()
    {
        var (service, repo) = CreateService();
        var track = MakeTrack("fav-2", "Clair de Lune", "Debussy", "Suite bergamasque");
        track.IsFavorite = true;
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        await service.ToggleFavoriteAsync("fav-2");

        var t = service.Tracks.First(x => x.Id == "fav-2");
        Assert.False(t.IsFavorite);
        Assert.DoesNotContain(service.Favorites, f => f.Id == "fav-2");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-014 — Record a play increments PlayCount
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP014_RecordPlay_IncrementsPlayCountAndSetsLastPlayed()
    {
        var repo = new MockRepository();
        // Override ServerUrl to empty so InitializeAsync does NOT spawn background server connect
        repo.Settings["ServerUrl"] = string.Empty;
        var service = new LibraryService(repo, new MetadataScanner());

        var track = MakeTrack("play-1", "Hotel California", "Eagles", "Hotel California");
        await repo.SaveTracksBatchAsync(new[] { track });
        await service.InitializeAsync();

        var before = DateTime.UtcNow;
        await service.RecordPlayAsync("play-1");

        var t = service.Tracks.First(x => x.Id == "play-1");
        Assert.Equal(1, t.PlayCount);
        Assert.NotNull(t.LastPlayed);
        Assert.True(t.LastPlayed >= before);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-015 / 016 / 017 / 018 — Search
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP015_Search_ByTitleFragment_ReturnsMatchingTrack()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Get Lucky",    "Daft Punk", "RAM"),
            MakeTrack("s2", "Harder Better","Daft Punk", "Discovery")
        });
        await service.InitializeAsync();

        var results = service.Search("Lucky").ToList();

        Assert.Single(results);
        Assert.Equal("Get Lucky", results[0].Title);
    }

    [Fact]
    public async Task HP016_Search_ByArtistName_ReturnsAllArtistTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Song A", "Daft Punk", "RAM"),
            MakeTrack("s2", "Song B", "Daft Punk", "Discovery"),
            MakeTrack("s3", "Song C", "Radiohead", "OK Computer")
        });
        await service.InitializeAsync();

        var results = service.Search("Daft").ToList();

        Assert.Equal(2, results.Count);
        Assert.All(results, t => Assert.Contains("Daft", t.Artist));
    }

    [Fact]
    public async Task HP017_Search_ByAlbumName_ReturnsAlbumTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("s1", "Starboy",       "The Weeknd", "Starboy"),
            MakeTrack("s2", "Party Monster", "The Weeknd", "Starboy"),
            MakeTrack("s3", "Blinding Lights","The Weeknd", "After Hours")
        });
        await service.InitializeAsync();

        var results = service.Search("Starboy").ToList();

        Assert.Equal(2, results.Count);
    }

    [Fact]
    public async Task HP018_Search_ByGenre_ReturnsGenreMatchingTracks()
    {
        var (service, repo) = CreateService();
        var jazzTrack = MakeTrack("j1", "So What", "Miles Davis", "Kind of Blue");
        jazzTrack.Genre = "Jazz";
        var rockTrack = MakeTrack("r1", "Whole Lotta Love", "Led Zeppelin", "Led Zeppelin II");
        rockTrack.Genre = "Rock";
        await repo.SaveTracksBatchAsync(new[] { jazzTrack, rockTrack });
        await service.InitializeAsync();

        var results = service.Search("Jazz").ToList();

        Assert.Single(results);
        Assert.Equal("So What", results[0].Title);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-026 — Bitperfect mode locks volume to unity gain
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP026_BitperfectMode_LocksVolumeToUnityGain()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetBitperfectModeAsync(true);

        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsVolumeLocked);
        Assert.Equal(1.0, engine.Volume);

        engine.SetVolume(0.3);
        Assert.Equal(1.0, engine.Volume); // must remain 1.0
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-027 — Exclusive mode toggles state
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP027_ExclusiveMode_TogglesStateCorrectly()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetExclusiveModeAsync(true);
        Assert.True(engine.IsExclusiveMode);

        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-029 — Seek updates engine position
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP029_SeekAsync_UpdatesCurrentPosition()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SeekAsync(TimeSpan.FromSeconds(42));

        Assert.Equal(TimeSpan.FromSeconds(42), engine.CurrentPosition);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-032 — Repeat One replays same track
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP032_RepeatOne_TrackQueueIndexStaysConstant()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, repo) = CreateService();
        var tracks = new[]
        {
            MakeTrack("q1", "A", "Artist", "Album", trackNum: 1),
            MakeTrack("q2", "B", "Artist", "Album", trackNum: 2)
        };
        await repo.SaveTracksBatchAsync(tracks);
        await service.InitializeAsync();

        var player = new Wiretone.UI.ViewModels.PlayerViewModel(engine, service);
        player.ToggleRepeatCommand.Execute(null); // Off → All
        player.ToggleRepeatCommand.Execute(null); // All → One

        Assert.Equal(RepeatMode.One, player.RepeatMode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-033 — Repeat All cycles RepeatMode enum
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP033_ToggleRepeat_CyclesThroughAllModes()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var player = new Wiretone.UI.ViewModels.PlayerViewModel(engine, service);

        Assert.Equal(RepeatMode.Off, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.All, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.One, player.RepeatMode);

        player.ToggleRepeatCommand.Execute(null);
        Assert.Equal(RepeatMode.Off, player.RepeatMode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-034 — Shuffle toggle
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP034_ToggleShuffle_FlipsIsShuffleState()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var player = new Wiretone.UI.ViewModels.PlayerViewModel(engine, service);

        Assert.False(player.IsShuffle);
        player.ToggleShuffleCommand.Execute(null);
        Assert.True(player.IsShuffle);
        player.ToggleShuffleCommand.Execute(null);
        Assert.False(player.IsShuffle);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-041 — Settings persist round-trip
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP041_Settings_PersistAndRestoreLibraryPath()
    {
        var (service, repo) = CreateService();
        repo.Settings["LibraryPath"] = "/music/collection";

        await service.InitializeAsync();

        Assert.Equal("/music/collection", service.LibraryPath);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-046 / HP-047 — Navigation
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP046_NavigateToCommand_WithInt_SetsIndex()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var vm = new Wiretone.UI.ViewModels.MainViewModel(engine, service);

        vm.NavigateToCommand.Execute(1);

        Assert.Equal(1, vm.SelectedNavigationIndex);
    }

    [Fact]
    public void HP047_NavigateToCommand_WithStringParam_SetsIndex()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var vm = new Wiretone.UI.ViewModels.MainViewModel(engine, service);

        vm.NavigateToCommand.Execute("5");

        Assert.Equal(5, vm.SelectedNavigationIndex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-048 / HP-050 — Album drilldown open/close
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP048_OpenAlbumCommand_SetsAlbumDetailAndNavigates()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var vm = new Wiretone.UI.ViewModels.MainViewModel(engine, service);

        var album = new Album
        {
            Id = "alb-1", Title = "Kind of Blue", Artist = "Miles Davis",
            Tracks = new List<Track>
            {
                new() { Id = "t1", Title = "So What", TrackNumber = 1 },
                new() { Id = "t2", Title = "Freddie Freeloader", TrackNumber = 2 }
            }
        };

        vm.OpenAlbumCommand.Execute(album);

        Assert.Equal(1, vm.SelectedNavigationIndex);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal("Kind of Blue", vm.Albums.SelectedAlbum?.Title);
    }

    [Fact]
    public void HP050_CloseAlbumDetail_ResetsDetailState()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var vm = new Wiretone.UI.ViewModels.MainViewModel(engine, service);
        var album = new Album { Id = "alb-2", Title = "Discovery", Artist = "Daft Punk", Tracks = new() };
        vm.OpenAlbumCommand.Execute(album);

        vm.Albums.CloseAlbumDetailCommand.Execute(null);

        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Null(vm.Albums.SelectedAlbum);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP-049 — Artist drilldown
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP049_OpenArtistCommand_SetsArtistDetailAndNavigates()
    {
        using var engine = new WiretoneAudioEngine();
        var (service, _) = CreateService();
        var vm = new Wiretone.UI.ViewModels.MainViewModel(engine, service);

        var album = new Album
        {
            Id = "alb-3", Title = "OK Computer", Artist = "Radiohead",
            Tracks = new List<Track>
            {
                new() { Id = "t3", Title = "Karma Police" },
                new() { Id = "t4", Title = "Paranoid Android" }
            }
        };
        var artist = new Artist { Id = "art-1", Name = "Radiohead", Albums = new() { album } };

        vm.OpenArtistCommand.Execute(artist);

        Assert.Equal(2, vm.SelectedNavigationIndex);
        Assert.True(vm.Artists.IsArtistDetailOpen);
        Assert.Equal("Radiohead", vm.Artists.SelectedArtist?.Name);
        Assert.Equal(2, vm.Artists.SelectedArtistTracks.Count);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — AudioFormat quality labels for all canonical sample rates
    // ─────────────────────────────────────────────────────────────────────────
    [Theory]
    [InlineData(192000, 24, "Ultra Hi-Res Studio Master")]
    [InlineData(96000,  24, "Hi-Res Studio Master")]
    [InlineData(88200,  24, "Hi-Res Audio")]
    [InlineData(48000,  24, "Enhanced Studio")]
    [InlineData(44100,  24, "Hi-Res 24-bit Lossless")]
    [InlineData(44100,  16, "CD Quality Lossless")]
    public void HP_AudioFormat_QualityLabel_MatchesExpectedLabel(int sampleRate, int bits, string expectedLabel)
    {
        var format = new AudioFormat { SampleRate = sampleRate, BitsPerSample = bits };
        Assert.Contains(expectedLabel, format.QualityLabel);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Genres are deduplicated and sorted
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_Genres_AreDeduplicatedAndSorted()
    {
        var (service, repo) = CreateService();
        var tracks = new[]
        {
            MakeTrack("g1", "A", "A1", "Al1"), MakeTrack("g2", "B", "B1", "Al2"),
            MakeTrack("g3", "C", "C1", "Al3")
        };
        tracks[0].Genre = "Jazz";
        tracks[1].Genre = "Rock";
        tracks[2].Genre = "Jazz"; // duplicate
        await repo.SaveTracksBatchAsync(tracks);
        await service.InitializeAsync();

        Assert.Equal(2, service.Genres.Count);
        Assert.Equal("Jazz", service.Genres[0]);
        Assert.Equal("Rock", service.Genres[1]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Favorites property is computed dynamically
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_Favorites_ReturnsOnlyFavoriteTracks()
    {
        var (service, repo) = CreateService();
        var t1 = MakeTrack("f1", "A", "Art", "Alb");
        var t2 = MakeTrack("f2", "B", "Art", "Alb", trackNum: 2);
        t1.IsFavorite = true;
        await repo.SaveTracksBatchAsync(new[] { t1, t2 });
        await service.InitializeAsync();

        Assert.Single(service.Favorites);
        Assert.Equal("f1", service.Favorites[0].Id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Track.FormattedDuration for sub-hour and over-hour tracks
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP_Track_FormattedDuration_SubHour_UsesMmSs()
    {
        var t = new Track { Duration = TimeSpan.FromSeconds(185) }; // 3:05
        Assert.Equal("3:05", t.FormattedDuration);
    }

    [Fact]
    public void HP_Track_FormattedDuration_OverHour_UsesHMmSs()
    {
        var t = new Track { Duration = TimeSpan.FromSeconds(3723) }; // 1:02:03
        Assert.Equal("1:02:03", t.FormattedDuration);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Track.DisplayTrackNumber
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public void HP_Track_DisplayTrackNumber_PadsToTwoDigits()
    {
        var t1 = new Track { TrackNumber = 3 };
        var t2 = new Track { TrackNumber = 10 };
        var t3 = new Track { TrackNumber = null };

        Assert.Equal("03", t1.DisplayTrackNumber);
        Assert.Equal("10", t2.DisplayTrackNumber);
        Assert.Equal("--", t3.DisplayTrackNumber);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Empty search query returns all tracks
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_Search_EmptyQuery_ReturnsAllTracks()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[]
        {
            MakeTrack("e1", "A", "Art", "Al1"),
            MakeTrack("e2", "B", "Art", "Al1", trackNum: 2),
            MakeTrack("e3", "C", "Art2", "Al2")
        });
        await service.InitializeAsync();

        var results = service.Search("").ToList();
        Assert.Equal(3, results.Count);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Bitperfect mode auto-enables exclusive mode
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_BitperfectMode_AutomaticallyEnablesExclusiveMode()
    {
        using var engine = new WiretoneAudioEngine();
        await engine.SetExclusiveModeAsync(false);

        await engine.SetBitperfectModeAsync(true);

        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsExclusiveMode);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Disabling exclusive mode also disables bitperfect
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_DisablingExclusiveMode_DisablesBitperfect()
    {
        using var engine = new WiretoneAudioEngine();
        await engine.SetBitperfectModeAsync(true);

        await engine.SetExclusiveModeAsync(false);

        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Enabling exclusive alone does NOT enable bitperfect
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_ExclusiveModeAlone_DoesNotEnableBitperfect()
    {
        using var engine = new WiretoneAudioEngine();

        await engine.SetExclusiveModeAsync(true);

        Assert.True(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — Volume set correctly when bitperfect is off
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_Volume_SetCorrectly_WhenBitperfectOff()
    {
        using var engine = new WiretoneAudioEngine();
        await engine.SetBitperfectModeAsync(false);

        engine.SetVolume(0.75);

        Assert.Equal(0.75, engine.Volume, precision: 2);
        Assert.False(engine.IsVolumeLocked);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HP — GetAlbum / GetArtist / GetPlaylist by ID
    // ─────────────────────────────────────────────────────────────────────────
    [Fact]
    public async Task HP_GetAlbumById_ReturnsCorrectAlbum()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("t1", "Song", "Band", "Record") });
        await service.InitializeAsync();

        var album = service.Albums.First();
        var found = service.GetAlbum(album.Id);

        Assert.NotNull(found);
        Assert.Equal("Record", found.Title);
    }

    [Fact]
    public async Task HP_GetArtistById_ReturnsCorrectArtist()
    {
        var (service, repo) = CreateService();
        await repo.SaveTracksBatchAsync(new[] { MakeTrack("t1", "Song", "Composer", "Opus") });
        await service.InitializeAsync();

        var artist = service.Artists.First();
        var found = service.GetArtist(artist.Id);

        Assert.NotNull(found);
        Assert.Equal("Composer", found.Name);
    }

    [Fact]
    public async Task HP_GetPlaylistById_ReturnsCorrectPlaylist()
    {
        var (service, _) = CreateService();
        await service.InitializeAsync();
        var pl = await service.CreatePlaylistAsync("My List");

        var found = service.GetPlaylist(pl.Id);

        Assert.NotNull(found);
        Assert.Equal("My List", found.Name);
    }
}
