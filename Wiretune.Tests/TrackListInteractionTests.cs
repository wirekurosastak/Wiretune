using System.Reflection;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

public class TrackListInteractionTests
{
    [Fact]
    public void CoverImage_DefaultProperties_AreInitializedCorrectly()
    {
        var cover = new CoverImage();
        Assert.Equal(64, cover.DecodeWidth);
        Assert.Null(cover.SourcePath);
        Assert.False(cover.HasBitmap);
        Assert.Null(cover.Source);

        cover.DecodeWidth = 128;
        Assert.Equal(128, cover.DecodeWidth);

        cover.SourcePath = null;
        Assert.False(cover.HasBitmap);
        Assert.Null(cover.Source);

        cover.SourcePath = "   ";
        Assert.False(cover.HasBitmap);
        Assert.Null(cover.Source);
    }

    [Fact]
    public async Task SongsView_PlayTrackCommand_StartsPlaybackOfClickedTrack()
    {
        var repo = new MockRepository();
        var track1 = new Track { Id = "trk_1", Title = "Bohemian Rhapsody", Artist = "Queen", Album = "A Night at the Opera" };
        var track2 = new Track { Id = "trk_2", Title = "Love of My Life", Artist = "Queen", Album = "A Night at the Opera" };
        repo.Tracks.Add(track1);
        repo.Tracks.Add(track2);

        var library = new LibraryService(repo, new MetadataScanner());
        await library.InitializeAsync();

        var session = new ServerSession(library, repo);
        var vm = new MainViewModel(new Wiretune.Core.Audio.WiretuneAudioEngine(), library, session);
        vm.Tracks.RefreshTracks();

        // The user clicks on track2's title row in the displayed songs DataGrid
        var clickedTrack = vm.Tracks.DisplayedTracks.First(t => t.Id == "trk_2");
        vm.Tracks.PlayTrackCommand.Execute(clickedTrack);

        var current = GetCurrentPlayingTrack(vm.Player);
        Assert.NotNull(current);
        Assert.Equal("trk_2", current.Id);
        Assert.Equal("Love of My Life", current.Title);
    }

    [Fact]
    public void AlbumDetailView_PlayAlbumTrackCommand_StartsPlaybackOfClickedTrack()
    {
        var repo = new MockRepository();
        var library = new LibraryService(repo, new MetadataScanner());
        var session = new ServerSession(library, repo);
        var vm = new MainViewModel(new Wiretune.Core.Audio.WiretuneAudioEngine(), library, session);

        var track1 = new Track { Id = "trk_10", Title = "Come Together", Artist = "The Beatles", Album = "Abbey Road", TrackNumber = 1 };
        var track2 = new Track { Id = "trk_11", Title = "Something", Artist = "The Beatles", Album = "Abbey Road", TrackNumber = 2 };

        var album = new Album
        {
            Id = "alb_abbey",
            Title = "Abbey Road",
            Artist = "The Beatles",
            Tracks = [track1, track2]
        };

        vm.OpenAlbum(album);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal("Abbey Road", vm.Albums.SelectedAlbum?.Title);

        // Clicking title of track2 in album detail
        vm.Albums.PlayAlbumTrackCommand.Execute(track2);

        var current = GetCurrentPlayingTrack(vm.Player);
        Assert.NotNull(current);
        Assert.Equal("trk_11", current.Id);
        Assert.Equal("Something", current.Title);
    }

    [Fact]
    public async Task ArtistDetailView_PlayArtistTrackCommand_StartsPlaybackOfClickedTrack()
    {
        var repo = new MockRepository();
        var track1 = new Track { Id = "trk_time", Title = "Time", Artist = "Pink Floyd", Album = "The Dark Side of the Moon" };
        var track2 = new Track { Id = "trk_money", Title = "Money", Artist = "Pink Floyd", Album = "The Dark Side of the Moon" };
        repo.Tracks.Add(track1);
        repo.Tracks.Add(track2);

        var library = new LibraryService(repo, new MetadataScanner());
        await library.InitializeAsync();

        var session = new ServerSession(library, repo);
        var vm = new MainViewModel(new Wiretune.Core.Audio.WiretuneAudioEngine(), library, session);
        vm.Artists.RefreshArtists();

        var artist = vm.Artists.DisplayedArtists.First(a => a.Name == "Pink Floyd");
        vm.Artists.OpenArtist(artist);
        Assert.True(vm.Artists.IsArtistDetailOpen);

        // Clicking title of track2 in artist detail
        var clickedTrack = vm.Artists.SelectedArtistTracks.First(t => t.Id == "trk_money");
        vm.Artists.PlayArtistTrackCommand.Execute(clickedTrack);

        var current = GetCurrentPlayingTrack(vm.Player);
        Assert.NotNull(current);
        Assert.Equal("trk_money", current.Id);
        Assert.Equal("Money", current.Title);
    }

    [Fact]
    public void RowPressSync_AttachedProperty_CanBeSetAndRetrieved()
    {
        var btn = new Avalonia.Controls.Button();
        Assert.False(RowPressSync.GetSyncWithTitle(btn));

        RowPressSync.SetSyncWithTitle(btn, true);
        Assert.True(RowPressSync.GetSyncWithTitle(btn));

        RowPressSync.SetSyncWithTitle(btn, false);
        Assert.False(RowPressSync.GetSyncWithTitle(btn));
    }

    [Fact]
    public void PlaylistCardViewModel_CoversCollage_ReflectsTrackCountCorrectly()
    {
        // 0 tracks -> No covers
        var plEmpty = new Playlist { Name = "Empty" };
        var cardEmpty = new PlaylistCardViewModel(plEmpty, Array.Empty<Track>());
        Assert.False(cardEmpty.HasCovers);
        Assert.False(cardEmpty.HasSingleCover);
        Assert.False(cardEmpty.HasMultipleCovers);

        // 1-3 tracks -> Single cover
        var plSingle = new Playlist { Name = "Single" };
        var tracksSingle = new List<Track>
        {
            new Track { Title = "T1", CoverArtPath = "/path/to/c1.jpg" }
        };
        var cardSingle = new PlaylistCardViewModel(plSingle, tracksSingle);
        Assert.True(cardSingle.HasCovers);
        Assert.True(cardSingle.HasSingleCover);
        Assert.False(cardSingle.HasMultipleCovers);
        Assert.Equal("/path/to/c1.jpg", cardSingle.SingleCoverPath);

        // 4+ tracks with covers -> Multiple covers (2x2 collage)
        var plMulti = new Playlist { Name = "Multi" };
        var tracksMulti = new List<Track>
        {
            new Track { Title = "T1", CoverArtPath = "/path/c1.jpg", Album = "A1" },
            new Track { Title = "T2", CoverArtPath = "/path/c2.jpg", Album = "A2" },
            new Track { Title = "T3", CoverArtPath = "/path/c3.jpg", Album = "A3" },
            new Track { Title = "T4", CoverArtPath = "/path/c4.jpg", Album = "A4" }
        };
        var cardMulti = new PlaylistCardViewModel(plMulti, tracksMulti);
        Assert.True(cardMulti.HasCovers);
        Assert.False(cardMulti.HasSingleCover);
        Assert.True(cardMulti.HasMultipleCovers);
        Assert.Equal("/path/c1.jpg", cardMulti.Cover0);
        Assert.Equal("/path/c2.jpg", cardMulti.Cover1);
        Assert.Equal("/path/c3.jpg", cardMulti.Cover2);
        Assert.Equal("/path/c4.jpg", cardMulti.Cover3);
    }

    private static Track? GetCurrentPlayingTrack(PlayerViewModel player)
    {
        var indexField = typeof(PlayerViewModel).GetField("_queueIndex",
            BindingFlags.NonPublic | BindingFlags.Instance);
        var queueField = typeof(PlayerViewModel).GetField("_playbackQueue",
            BindingFlags.NonPublic | BindingFlags.Instance);

        var idx = (int)(indexField?.GetValue(player) ?? -1);
        var queue = (List<Track>?)(queueField?.GetValue(player));

        if (queue != null && idx >= 0 && idx < queue.Count)
        {
            return queue[idx];
        }
        return null;
    }
}


