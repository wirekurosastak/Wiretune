using Wiretune.Core.Models;
using Wiretune.UI.Controls;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

public class NavVisualizerTests
{
    [Fact]
    public void NavVisualizerControl_Has8Bands()
    {
        Assert.Equal(8, NavVisualizerControl.BandsCount);
        var control = new NavVisualizerControl();
        Assert.Equal(8, NavVisualizerControl.BandsCount);
        Assert.False(control.IsPlaying);
    }

    [Theory]
    [InlineData(2, 0)] // Artists -> Visual Row 0
    [InlineData(1, 1)] // Albums -> Visual Row 1
    [InlineData(0, 2)] // Songs -> Visual Row 2
    [InlineData(4, 3)] // Favorites -> Visual Row 3
    [InlineData(3, 4)] // Playlists -> Visual Row 4
    [InlineData(5, 5)] // Settings -> Visual Row 5
    public void GetNavVisualOrder_MapsSidebarOrderCorrectly(int navIndex, int expectedVisualRow)
    {
        Assert.Equal(expectedVisualRow, MainViewModel.GetNavVisualOrder(navIndex));
    }

    [Fact]
    public void Navigation_DownwardInSidebar_TriggersLeftToRightWave()
    {
        var (vm, _) = CreateMainVm();

        NavWaveDirection? lastDirection = null;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.WaveTrigger))
            {
                lastDirection = vm.LastWaveDirection;
            }
        };

        // Start at Artists (visual row 0, nav index 2)
        vm.SelectedNavigationIndex = 2;

        // Navigate downwards to Albums (visual row 1, nav index 1)
        vm.NavigateTo(1);
        Assert.Equal(NavWaveDirection.LeftToRight, lastDirection);

        // Navigate downwards to Songs (visual row 2, nav index 0)
        vm.NavigateTo(0);
        Assert.Equal(NavWaveDirection.LeftToRight, lastDirection);
    }

    [Fact]
    public void Navigation_UpwardInSidebar_TriggersRightToLeftWave()
    {
        var (vm, _) = CreateMainVm();

        NavWaveDirection? lastDirection = null;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.WaveTrigger))
            {
                lastDirection = vm.LastWaveDirection;
            }
        };

        // Start at Songs (visual row 2, nav index 0)
        vm.SelectedNavigationIndex = 0;

        // Navigate upwards to Albums (visual row 1, nav index 1)
        vm.NavigateTo(1);
        Assert.Equal(NavWaveDirection.RightToLeft, lastDirection);

        // Navigate upwards to Artists (visual row 0, nav index 2)
        vm.NavigateTo(2);
        Assert.Equal(NavWaveDirection.RightToLeft, lastDirection);
    }

    [Fact]
    public void InwardNavigation_OpeningArtistOrAlbum_TriggersLeftToRightWave()
    {
        var (vm, _) = CreateMainVm();

        NavWaveDirection? lastDirection = null;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.WaveTrigger))
            {
                lastDirection = vm.LastWaveDirection;
            }
        };

        // Open an artist (inwards drill down)
        var artist = new Artist { Id = "art1", Name = "Queen" };
        vm.Artists.OpenArtist(artist);
        Assert.Equal(NavWaveDirection.LeftToRight, lastDirection);

        // Open an album (inwards drill down)
        var album = new Album { Id = "alb1", Title = "A Night at the Opera" };
        vm.Albums.OpenAlbum(album);
        Assert.Equal(NavWaveDirection.LeftToRight, lastDirection);
    }

    [Fact]
    public void OutwardNavigation_BackButtons_TriggersRightToLeftWave()
    {
        var (vm, _) = CreateMainVm();

        NavWaveDirection? lastDirection = null;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.WaveTrigger))
            {
                lastDirection = vm.LastWaveDirection;
            }
        };

        // Open artist first
        var artist = new Artist { Id = "art1", Name = "Queen" };
        vm.Artists.OpenArtist(artist);
        Assert.True(vm.Artists.IsArtistDetailOpen);

        // Click Back to all artists (outwards)
        vm.Artists.CloseArtistDetail();
        Assert.False(vm.Artists.IsArtistDetailOpen);
        Assert.Equal(NavWaveDirection.RightToLeft, lastDirection);

        // Open album first
        var album = new Album { Id = "alb1", Title = "A Night at the Opera" };
        vm.Albums.OpenAlbum(album);
        Assert.True(vm.Albums.IsAlbumDetailOpen);

        // Click Back to all albums (outwards)
        vm.Albums.CloseAlbumDetail();
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal(NavWaveDirection.RightToLeft, lastDirection);
    }

    [Fact]
    public void InwardAndOutward_Playlists_TriggersDirectionalWaves()
    {
        var (vm, _) = CreateMainVm();

        NavWaveDirection? lastDirection = null;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.WaveTrigger))
            {
                lastDirection = vm.LastWaveDirection;
            }
        };

        var playlist = new Playlist { Id = "pl1", Name = "Rock Classics" };

        // Open playlist (inwards)
        vm.Playlists.OpenPlaylist(playlist);
        Assert.True(vm.Playlists.IsPlaylistDetailOpen);
        Assert.Equal(NavWaveDirection.LeftToRight, lastDirection);

        // Close playlist (outwards)
        vm.Playlists.ClosePlaylistDetail();
        Assert.False(vm.Playlists.IsPlaylistDetailOpen);
        Assert.Equal(NavWaveDirection.RightToLeft, lastDirection);
    }

    [Fact]
    public void ArtistToAlbumAndBack_ReturnsToArtistView()
    {
        var (vm, _) = CreateMainVm();

        // 1. Go to artists tab
        vm.NavigateTo(2);
        Assert.Equal(2, vm.SelectedNavigationIndex);

        // 2. Click on an artist
        var artist = new Artist { Id = "art_queen", Name = "Queen" };
        vm.Artists.OpenArtist(artist);
        Assert.True(vm.Artists.IsArtistDetailOpen);
        Assert.Equal("Queen", vm.Artists.SelectedArtist?.Name);

        // 3. Click in one of the artist's albums
        var album = new Album { Id = "alb_opera", Title = "A Night at the Opera", Artist = "Queen" };
        vm.OpenAlbum(album);

        // Should be looking at the album detail
        Assert.Equal(1, vm.SelectedNavigationIndex);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal("A Night at the Opera", vm.Albums.SelectedAlbum?.Title);
        Assert.Equal("Vissza: Queen", vm.Albums.BackButtonText);

        // 4. Click Back on the album detail
        vm.Albums.CloseAlbumDetail();

        // Must return to the artist view, NOT the general albums grid!
        Assert.Equal(2, vm.SelectedNavigationIndex);
        Assert.True(vm.Artists.IsArtistDetailOpen);
        Assert.Equal("Queen", vm.Artists.SelectedArtist?.Name);
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal(NavWaveDirection.RightToLeft, vm.LastWaveDirection);
    }

    private static (MainViewModel vm, MockRepository repo) CreateMainVm()
    {
        var repo = new MockRepository();
        var library = new Core.Services.LibraryService(repo, new Core.Services.MetadataScanner());
        var session = new Core.Services.ServerSession(library, repo);
        var vm = new MainViewModel(new Wiretune.Core.Audio.WiretuneAudioEngine(), library, session);
        return (vm, repo);
    }
}

