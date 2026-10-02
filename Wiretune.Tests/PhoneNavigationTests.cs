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
        vm.NavigateTo(AppSection.Playlists);
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

        // No layer is left: back now walks the tabs the user came from (Artists, Playlists, Tracks), newest first ...
        vm.NavigateTo(AppSection.Tracks);
        Assert.True(vm.TryNavigateBack());
        Assert.Equal(AppSection.Playlists, vm.SelectedSection);
        Assert.True(vm.TryNavigateBack());
        Assert.Equal(AppSection.Artists, vm.SelectedSection);

        // ... and when that history is used up there is nothing to close: the app may leave.
        Assert.False(vm.TryNavigateBack());
        Assert.Equal(AppSection.Artists, vm.SelectedSection);
    }

    [Fact]
    public async Task Back_LeavesADetailPage_ThenTheFavoritesTab()
    {
        var vm = await CreateAsync();

        vm.NavigateTo(AppSection.Albums);
        vm.OpenAlbum(vm.Library.Albums[0]);
        Assert.True(vm.Albums.IsAlbumDetailOpen);
        Assert.True(vm.TryNavigateBack());
        Assert.False(vm.Albums.IsAlbumDetailOpen);
        Assert.Equal(AppSection.Albums, vm.SelectedSection); // closing the page stays on the tab

        vm.NavigateTo(AppSection.Favorites);
        Assert.True(vm.TryNavigateBack());
        Assert.Equal(AppSection.Albums, vm.SelectedSection); // the tab the user came from
    }

    [Fact]
    public async Task Back_FromSettings_ReturnsToTheTabTheUserCameFrom()
    {
        // The settings are not in the bottom bar: the account button of a page header opens them.
        var vm = await CreateAsync();

        vm.NavigateTo(AppSection.Favorites);
        vm.NavigateTo(AppSection.Settings);
        Assert.Equal(AppSection.Settings, vm.SelectedSection);

        Assert.True(vm.TryNavigateBack());
        Assert.Equal(AppSection.Favorites, vm.SelectedSection);
    }

    [Fact]
    public async Task PerformanceStats_AreOffUntilTheUserTurnsThemOnInTheSettings()
    {
        var vm = await CreateAsync();

        Assert.False(vm.ShowPerformanceStats);

        var raised = new List<string?>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName);
        vm.ShowPerformanceStats = true;
        Assert.Contains(nameof(MainViewModel.ShowPerformanceStats), raised); // the phone layout shows the panel on this
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

        vm.NavigateTo(AppSection.Artists);

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
