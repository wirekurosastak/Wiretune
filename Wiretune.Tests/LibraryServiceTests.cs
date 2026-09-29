using Wiretune.Core.Models;
using Wiretune.Core.Data;
using Wiretune.Core.Services;
using Xunit;

namespace Wiretune.Tests;

public class MockRepository : LibraryRepository 
{
    public List<Track> Tracks { get; } = new();
    public List<Playlist> Playlists { get; } = new();
    public Dictionary<string, string> Settings { get; } = new();

    public override Task InitializeAsync() => Task.CompletedTask;
    public override Task<List<Track>> GetAllTracksAsync() => Task.FromResult(
        Tracks.Select(t => new Track
        {
            Id          = t.Id,
            Title       = t.Title,
            Artist      = t.Artist,
            Album       = t.Album,
            AlbumArtist = t.AlbumArtist,
            TrackNumber = t.TrackNumber,
            TrackCount  = t.TrackCount,
            DiscNumber  = t.DiscNumber,
            Year        = t.Year,
            Genre       = t.Genre,
            Duration    = t.Duration,
            FileSizeBytes = t.FileSizeBytes,
            FilePath    = t.FilePath,
            StreamUrl   = t.StreamUrl,
            HasCoverArt = t.HasCoverArt,
            CoverArtPath = t.CoverArtPath,
            Format      = t.Format,
            IsFavorite  = t.IsFavorite,
            PlayCount   = t.PlayCount,
            LastPlayed  = t.LastPlayed,
            DateAdded   = t.DateAdded
        }).ToList());
    public int ReplaceCalls { get; private set; }

    /// <summary>Test helper for seeding stored tracks.</summary>
    public Task SaveTracksBatchAsync(IEnumerable<Track> tracks)
    {
        Tracks.AddRange(tracks);
        return Task.CompletedTask;
    }
    public override Task ReplaceAllTracksAsync(IEnumerable<Track> tracks)
    {
        ReplaceCalls++;
        var list = tracks.ToList();
        Tracks.Clear();
        Tracks.AddRange(list);
        return Task.CompletedTask;
    }
    public override Task UpdateTrackFavoriteAsync(string trackId, bool isFavorite)
    {
        var tr = Tracks.FirstOrDefault(t => t.Id == trackId);
        if (tr != null) tr.IsFavorite = isFavorite;
        return Task.CompletedTask;
    }
    public override Task IncrementPlayCountAsync(string trackId)
    {
        var tr = Tracks.FirstOrDefault(t => t.Id == trackId);
        if (tr != null) tr.PlayCount++;
        return Task.CompletedTask;
    }
    public override Task<List<Playlist>> GetAllPlaylistsAsync() => Task.FromResult(new List<Playlist>(Playlists));
    public override Task SavePlaylistAsync(Playlist playlist)
    {
        Playlists.RemoveAll(p => p.Id == playlist.Id);
        Playlists.Add(playlist);
        return Task.CompletedTask;
    }
    public override Task DeletePlaylistAsync(string playlistId)
    {
        Playlists.RemoveAll(p => p.Id == playlistId);
        return Task.CompletedTask;
    }
    public override Task<string?> GetSettingAsync(string key, string? defaultValue = null)
    {
        return Task.FromResult(Settings.TryGetValue(key, out var val) ? val : defaultValue);
    }
    public override Task SetSettingAsync(string key, string value)
    {
        Settings[key] = value;
        return Task.CompletedTask;
    }
}

public class LibraryServiceTests
{
    [Fact]
    public async Task LibraryService_IndexesAlbumsAndArtistsProperly()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);

        var track1 = new Track
        {
            Id = "1",
            Title = "Starboy",
            Artist = "The Weeknd",
            Album = "Starboy",
            Duration = TimeSpan.FromMinutes(3.8),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24 }
        };

        var track2 = new Track
        {
            Id = "2",
            Title = "Party Monster",
            Artist = "The Weeknd",
            Album = "Starboy",
            Duration = TimeSpan.FromMinutes(4.1),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24 }
        };

        var track3 = new Track
        {
            Id = "3",
            Title = "Get Lucky",
            Artist = "Daft Punk",
            Album = "Random Access Memories",
            Duration = TimeSpan.FromMinutes(6.1),
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 88200, BitsPerSample = 24 }
        };

        await repo.SaveTracksBatchAsync(new[] { track1, track2, track3 });
        await service.InitializeAsync();

        Assert.Equal(3, service.Tracks.Count);
        Assert.Equal(2, service.Albums.Count);
        Assert.Equal(2, service.Artists.Count);

        var starboyAlbum = service.Albums.FirstOrDefault(a => a.Title == "Starboy");
        Assert.NotNull(starboyAlbum);
        Assert.Equal(2, starboyAlbum.TrackCount);
        Assert.True(starboyAlbum.IsHiRes);

        var searchResults = service.Search("Lucky").ToList();
        Assert.Single(searchResults);
        Assert.Equal("Get Lucky", searchResults[0].Title);
    }

    [Fact]
    public async Task Playlists_CanBeCreatedAndModified()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        await service.InitializeAsync();

        var pl = await service.CreatePlaylistAsync("Favorites Hi-Res", "Best 24-bit FLAC tracks");
        Assert.NotNull(pl);
        Assert.Equal("Favorites Hi-Res", pl.Name);

        await service.AddTrackToPlaylistAsync(pl.Id, "track_123");
        Assert.Equal(1, pl.TrackCount);

        await service.RemoveTrackFromPlaylistAsync(pl.Id, "track_123");
        Assert.Equal(0, pl.TrackCount);

        await service.DeletePlaylistAsync(pl.Id);
        Assert.Empty(service.Playlists);
    }

    [Fact]
    public void IntEqualConverter_MatchesIntAndStringCorrectly()
    {
        var converter = new Wiretune.UI.Converters.IntEqualConverter();
        var culture = System.Globalization.CultureInfo.InvariantCulture;

        // Int value and string parameter (from XAML)
        Assert.True((bool)converter.Convert(6, typeof(bool), "6", culture)!);
        Assert.True((bool)converter.Convert(0, typeof(bool), "0", culture)!);
        Assert.False((bool)converter.Convert(6, typeof(bool), "5", culture)!);
        Assert.False((bool)converter.Convert(null, typeof(bool), "6", culture)!);
    }

    [Fact]
    public void MainViewModel_NavigateToCommand_AcceptsStringAndInt()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        var audioEngine = TestSupport.CreateEngine();
        var vm = TestSupport.CreateMainViewModel(service, audioEngine);

        // Verify initial (Előadók is now index 2, first in sidebar)
        Assert.Equal(2, vm.SelectedNavigationIndex);

        // String command parameter (as passed from XAML button to Settings)
        Assert.True(vm.NavigateToCommand.CanExecute("5"));
        vm.NavigateToCommand.Execute("5");
        Assert.Equal(5, vm.SelectedNavigationIndex);

        // Int command parameter (to Albumok)
        Assert.True(vm.NavigateToCommand.CanExecute(1));
        vm.NavigateToCommand.Execute(1);
        Assert.Equal(1, vm.SelectedNavigationIndex);

        // Navigate to Számok (0)
        vm.NavigateToCommand.Execute("0");
        Assert.Equal(0, vm.SelectedNavigationIndex);
    }

    [Fact]
    public async Task AudiophileEngine_BitperfectRequiresExclusive_AndDisablingExclusiveDisablesBitperfect()
    {
        var engine = TestSupport.CreateEngine();

        // Initial state: neither is active
        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);

        // Turn on Bit-perfect: must automatically activate Exclusive mode
        await engine.SetBitperfectModeAsync(true);
        Assert.True(engine.IsBitperfect);
        Assert.True(engine.IsExclusiveMode);
        Assert.Equal(1.0, engine.Volume);

        // Turn off Exclusive mode: Bit-perfect is impossible in shared mixer mode, so it must turn OFF
        await engine.SetExclusiveModeAsync(false);
        Assert.False(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);

        // Turn on Exclusive mode alone: Bit-perfect remains false unless explicitly enabled
        await engine.SetExclusiveModeAsync(true);
        Assert.True(engine.IsExclusiveMode);
        Assert.False(engine.IsBitperfect);
    }

    [Fact]
    public void DrilldownNavigation_ArtistToAlbumToTracks()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        var audioEngine = TestSupport.CreateEngine();
        var vm = TestSupport.CreateMainViewModel(service, audioEngine);

        var sampleAlbum = new Album
        {
            Id = "alb_1",
            Title = "Kind of Blue",
            Artist = "Miles Davis",
            Tracks = new List<Track>
            {
                new() { Id = "t1", Title = "So What", TrackNumber = 1 },
                new() { Id = "t2", Title = "Freddie Freeloader", TrackNumber = 2 }
            }
        };

        var sampleArtist = new Artist
        {
            Id = "art_1",
            Name = "Miles Davis",
            Albums = new List<Album> { sampleAlbum },
            Tracks = sampleAlbum.Tracks
        };

        // 1. Open Artist
        vm.OpenArtistCommand.Execute(sampleArtist);
        Assert.Equal(2, vm.SelectedNavigationIndex); // Tab 2: Artists
        Assert.True(vm.Artists.IsArtistDetailOpen);
        Assert.Equal("Miles Davis", vm.Artists.SelectedArtist?.Name);
        Assert.Equal(2, vm.Artists.SelectedArtistTracks.Count);

        // 2. Open Album from Artist
        vm.OpenAlbumCommand.Execute(sampleAlbum);
        Assert.Equal(1, vm.SelectedNavigationIndex); // Tab 1: Albums
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal("Kind of Blue", vm.Albums.SelectedAlbum?.Title);
        Assert.Equal(2, vm.Albums.SelectedAlbum?.Tracks.Count);

        // 3. Close Album Detail returns to album grid
        vm.Albums.CloseAlbumDetailCommand.Execute(null);
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Null(vm.Albums.SelectedAlbum);
    }

    [Fact]
    public void UnifiedSettings_NavigationAndFooterStatus()
    {
        var repo = new MockRepository();
        var scanner = new MetadataScanner();
        var service = new LibraryService(repo, scanner);
        var audioEngine = TestSupport.CreateEngine();
        var vm = TestSupport.CreateMainViewModel(service, audioEngine);

        // Navigate to Settings (Tab 5)
        vm.NavigateToCommand.Execute(5);
        Assert.Equal(5, vm.SelectedNavigationIndex);

        // Verify Idle footer status: audio on left, library on right (no Kimenet prefix, no Wiretune brand text)
        Assert.Contains("Test USB DAC", vm.StatusText);
        Assert.DoesNotContain("Kimenet", vm.StatusText);
        Assert.DoesNotContain("Wiretune", vm.RightFooterStatusText);
        Assert.False(string.IsNullOrWhiteSpace(vm.RightFooterStatusText));

        // Set track and test footer status on left side (device info retained without redundant format/title/artist)
        var testTrack = new Track
        {
            Id = "t100",
            Title = "Hotel California",
            Artist = "Eagles",
            Format = new AudioFormat { Codec = "FLAC", SampleRate = 192000, BitsPerSample = 24 }
        };

        _ = audioEngine.PlayTrackAsync(testTrack);

        Assert.Contains("Test USB DAC", vm.StatusText);
        Assert.DoesNotContain("Kimenet", vm.StatusText);
        Assert.DoesNotContain("Eagles", vm.StatusText);
        Assert.DoesNotContain("Hotel California", vm.StatusText);
        Assert.DoesNotContain("Wiretune", vm.RightFooterStatusText);
    }

    [Fact]
    public void AlbumCardViewModel_WrapsAlbumCorrectly()
    {
        var album = new Album
        {
            Id = "alb_test",
            Title = "Random Access Memories",
            Artist = "Daft Punk",
            TrackCount = 13,
            FormatBadge = "FLAC / 24bit / 88.2kHz"
        };

        var card = new Wiretune.UI.ViewModels.AlbumCardViewModel(album);

        Assert.Equal("Random Access Memories", card.Title);
        Assert.Equal("Daft Punk", card.Artist);
        Assert.Equal(13, card.TrackCount);
        Assert.Equal("FLAC / 24bit / 88.2kHz", card.FormatBadge);
    }

    [Fact]
    public async Task MultiArtist_CompilationTracksInSameDirectory_ConsolidatesToVariousArtistsAndExcludesGuestArtists()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());

        await repo.SaveTracksBatchAsync(new[]
        {
            new Track { Id = "1", Title = "Song 1", Artist = "Guest Alpha", Album = "Top Hits", TrackNumber = 1, FilePath = "/Music/Compilations/TopHits/01.flac" },
            new Track { Id = "2", Title = "Song 2", Artist = "Guest Beta", Album = "Top Hits", TrackNumber = 2, FilePath = "/Music/Compilations/TopHits/02.flac" },
            new Track { Id = "3", Title = "Song 3", Artist = "Guest Gamma", Album = "Top Hits", TrackNumber = 3, FilePath = "/Music/Compilations/TopHits/03.flac" }
        });

        await service.InitializeAsync();

        Assert.Single(service.Albums);
        Assert.Equal("Various Artists", service.Albums[0].Artist);
        Assert.Single(service.Artists);
        Assert.Equal("Various Artists", service.Artists[0].Name);

        // Guest artists should not pollute primary Artists list, but should resolve on-demand
        Assert.DoesNotContain(service.Artists, a => a.Name == "Guest Alpha");
        var resolved = service.GetArtistByName("Guest Alpha");
        Assert.NotNull(resolved);
        Assert.Equal("Guest Alpha", resolved.Name);
        Assert.Single(resolved.Tracks);
    }

    [Fact]
    public async Task MultiArtist_DominantArtist_ResolvesToDominantAlbumArtist()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());

        await repo.SaveTracksBatchAsync(new[]
        {
            new Track { Id = "1", Title = "One More Time", Artist = "Daft Punk", Album = "Discovery", TrackNumber = 1, FilePath = "/Music/DaftPunk/Discovery/01.flac" },
            new Track { Id = "2", Title = "Aerodynamic", Artist = "Daft Punk", Album = "Discovery", TrackNumber = 2, FilePath = "/Music/DaftPunk/Discovery/02.flac" },
            new Track { Id = "3", Title = "Too Long", Artist = "Daft Punk feat. Romanthony", Album = "Discovery", TrackNumber = 3, FilePath = "/Music/DaftPunk/Discovery/03.flac" }
        });

        await service.InitializeAsync();

        Assert.Single(service.Albums);
        Assert.Equal("Daft Punk", service.Albums[0].Artist);
        Assert.Single(service.Artists);
        Assert.Equal("Daft Punk", service.Artists[0].Name);
        Assert.DoesNotContain(service.Artists, a => a.Name == "Daft Punk feat. Romanthony");
    }

    [Fact]
    public async Task Album_WithMixedHiResAndCdTracks_AssignsMixedHqBadge()
    {
        var repo = new MockRepository();
        var service = new LibraryService(repo, new MetadataScanner());

        await repo.SaveTracksBatchAsync(new[]
        {
            new Track
            {
                Id = "t1",
                Title = "Track 1 - Hi-Res",
                Artist = "Artist X",
                Album = "Mixed Album",
                TrackNumber = 1,
                FilePath = "/Music/ArtistX/Mixed/01.flac",
                Format = new AudioFormat { Codec = "FLAC", SampleRate = 96000, BitsPerSample = 24, IsLossless = true }
            },
            new Track
            {
                Id = "t2",
                Title = "Track 2 - CD Quality",
                Artist = "Artist X",
                Album = "Mixed Album",
                TrackNumber = 2,
                FilePath = "/Music/ArtistX/Mixed/02.flac",
                Format = new AudioFormat { Codec = "FLAC", SampleRate = 44100, BitsPerSample = 16, IsLossless = true }
            }
        });

        await service.InitializeAsync();

        Assert.Single(service.Albums);
        var album = service.Albums[0];
        Assert.Equal("MIXED HQ", album.FormatBadge);
        Assert.True(album.IsHiRes);
    }
}





