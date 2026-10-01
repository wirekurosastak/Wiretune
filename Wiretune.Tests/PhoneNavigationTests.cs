using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.ViewModels;
using Xunit;

namespace Wiretune.Tests;

/// <summary>
/// The navigation state behind the phone layout: which layers the back gesture closes and in what order, how the
/// search page and the full-screen player open and close, and how their tabs follow the player.
/// </summary>
public sealed class PhoneNavigationTests : IDisposable
{
    private readonly WiretuneAudioEngine _engine = TestSupport.CreateEngine();

    public void Dispose() => _engine.Dispose();

    private async Task<MainViewModel> CreateAsync()
    {
        var repo = new MockRepository();
        await repo.SaveTracksBatchAsync(new[]
        {
            TestSupport.MakeTrack("1", "So What", "Miles Davis", "Kind of Blue", trackNumber: 1),
            TestSupport.MakeTrack("2", "Blue in Green", "Miles Davis", "Kind of Blue", trackNumber: 2),
            TestSupport.MakeTrack("3", "Opening", "Daft Punk", "Random Access Memories", trackNumber: 1),
        });
        var library = new LibraryService(repo, new MetadataScanner());
        await library.InitializeAsync();
        return TestSupport.CreateMainViewModel(library, _engine);
    }

    /// <summary>Makes the player show a track, as it does once the engine reports one (that arrives on the UI thread).</summary>
    private static void ShowTrack(MainViewModel vm) => vm.Player.CurrentTrack = vm.Library.Tracks[0];

    // ── Back gesture ─────────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Back_ClosesTheInnermostLayerFirst_AndSaysWhenThereIsNothingLeft()
    {
        var vm = await CreateAsync();
        vm.NavigateTo(3);
        ShowTrack(vm);
        vm.OpenNowPlaying();
        vm.Playlists.OpenCreateDialog();

        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.Playlists.IsCreateDialogOpen);
        Assert.True(vm.IsNowPlayingOpen); // the dialog went first

        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.IsNowPlayingOpen);

        vm.OpenSearch();
        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.IsSearchOpen);

        vm.NavigateTo(0);
        Assert.False(vm.TryNavigateBack()); // nothing to close: the app may leave
        Assert.Equal(0, vm.SelectedNavigationIndex);
    }

    [Fact]
    public async Task Back_LeavesADetailPage_ThenTheFavoritesTab()
    {
        var vm = await CreateAsync();

        vm.NavigateTo(1);
        vm.OpenAlbum(vm.Library.Albums[0]);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.False(vm.TryNavigateBack());

        vm.NavigateTo(4);
        Assert.True(vm.IsPlaylistsSectionActive);
        Assert.True(vm.TryNavigateBack());
        Assert.Equal(3, vm.SelectedNavigationIndex);
        Assert.True(vm.IsPlaylistsSectionActive);
    }

    [Fact]
    public async Task IsPlaylistsSectionActive_CoversPlaylistsAndFavoritesOnly()
    {
        var vm = await CreateAsync();

        for (var index = 0; index <= 5; index++)
        {
            vm.NavigateTo(index);
            Assert.Equal(index is 3 or 4, vm.IsPlaylistsSectionActive);
        }
    }

    // ── Search page ──────────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task Search_TypingKeepsThePageOpen_AndClosingClearsTheQuery()
    {
        var vm = await CreateAsync();

        vm.OpenSearch();
        Assert.True(vm.IsSearchOpen);
        Assert.False(vm.IsSearchActive); // open, but nothing typed yet

        vm.SearchQuery = "blue";
        Assert.True(vm.IsSearchActive);
        Assert.True(vm.IsSearchOpen);

        vm.CloseSearch();
        Assert.False(vm.IsSearchOpen);
        Assert.Equal(string.Empty, vm.SearchQuery);
    }

    [Fact]
    public async Task Search_OpeningAResultShowsItAndBackReturnsToTheResults()
    {
        var vm = await CreateAsync();
        vm.OpenSearch();
        vm.SearchQuery = "kind";

        vm.OpenAlbum(vm.Library.Albums.First(a => a.Title == "Kind of Blue"));
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.False(vm.IsSearchOpen); // the album replaces the search page ...
        Assert.Equal("kind", vm.SearchQuery); // ... but the query is kept

        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.True(vm.IsSearchOpen);
        Assert.Equal("kind", vm.SearchQuery);
    }

    [Fact]
    public async Task Navigating_ClosesTheSearchPage()
    {
        var vm = await CreateAsync();
        vm.OpenSearch();
        vm.SearchQuery = "opening";

        vm.NavigateTo(2);

        Assert.False(vm.IsSearchOpen);
        Assert.Equal(string.Empty, vm.SearchQuery);
    }

    // ── Full-screen player ───────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task NowPlaying_NeedsATrack_AndClosesWhenTheQueueIsCleared()
    {
        var vm = await CreateAsync();

        vm.OpenNowPlaying();
        Assert.False(vm.IsNowPlayingOpen); // nothing is playing

        ShowTrack(vm);
        vm.OpenNowPlaying();
        Assert.True(vm.IsNowPlayingOpen);

        vm.Player.CurrentTrack = null; // the queue was cleared or playback ended
        Assert.False(vm.IsNowPlayingOpen);
    }

    [Fact]
    public async Task NowPlayingTabs_FollowThePlayersQueueFlag_AndResetOnClose()
    {
        var vm = await CreateAsync();
        ShowTrack(vm);
        vm.OpenNowPlaying();
        Assert.Equal(0, vm.NowPlayingTab);
        Assert.False(vm.Player.IsQueueOpen);

        vm.SetNowPlayingTab(1);
        Assert.Equal(1, vm.NowPlayingTab);
        Assert.True(vm.Player.IsQueueOpen);

        vm.SetNowPlayingTab("2");
        Assert.Equal(2, vm.NowPlayingTab);
        Assert.True(vm.Player.IsQueueOpen);

        vm.SetNowPlayingTab(7); // not a tab
        vm.SetNowPlayingTab("lyrics");
        vm.SetNowPlayingTab(null);
        Assert.Equal(2, vm.NowPlayingTab);

        vm.CloseNowPlaying();
        Assert.Equal(0, vm.NowPlayingTab);
        Assert.False(vm.Player.IsQueueOpen);
    }
}
