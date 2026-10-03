using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Audio;
using Wiretune.Core.Audio.Drivers;
using Wiretune.Core.Data;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class MainViewModel : ObservableObject, IDisposable
{
    public const int CompactLayoutWidth = 1000;

    private bool _disposed;

    public ThemeService Theme { get; }
    public WiretuneAudioEngine AudioEngine { get; }
    public LibraryService Library { get; }
    public ServerSession Session { get; }

    public PlayerViewModel Player { get; }
    public TracksViewModel Tracks { get; }
    public AlbumsViewModel Albums { get; }
    public ArtistsViewModel Artists { get; }
    public PlaylistsViewModel Playlists { get; }
    public FavoritesViewModel Favorites { get; }
    public AudiophileSettingsViewModel AudiophileSettings { get; }
    public ServerSettingsViewModel ServerSettings { get; }
    public SearchResultsViewModel Search { get; }

    [ObservableProperty] private AppSection _selectedSection = AppSection.Artists;
    [ObservableProperty] private int _waveTrigger;
    [ObservableProperty] private NavWaveDirection _lastWaveDirection = NavWaveDirection.LeftToRight;
    private AppSection _previousSection = AppSection.Artists;

    // The tabs the user came from, the latest last; the tab that is open is never in it. The phone's back gesture walks it
    // backwards (see TryNavigateBack). _isRestoringTab keeps that walk itself out of the list.
    private readonly List<AppSection> _tabHistory = new();
    private bool _isRestoringTab;

    [ObservableProperty] private string _searchQuery = string.Empty;
    [ObservableProperty] private bool _isSearchActive;
    [ObservableProperty] private string _statusText = Localizer.Get("StatusStarting");
    [ObservableProperty] private string _rightFooterStatusText = Localizer.Get("FooterLoading");
    [ObservableProperty] private string _logoTransform = "rotate(0deg)";
    [ObservableProperty] private bool _isServerOfflineBannerVisible;
    [ObservableProperty] private string _serverBannerMessage = string.Empty;
    [ObservableProperty] private bool _isLoginViewActive;
    [ObservableProperty] private bool _isUserLoggedIn;
    [ObservableProperty] private string _currentUserBadge = Localizer.Get("SignIn");
    [ObservableProperty] private bool _isCompactLayout;
    [ObservableProperty] private bool _isStarting = true;
    [ObservableProperty] private bool _isLibraryEmpty;

    // Phone layout state (the desktop layout ignores these): the full-screen player, the search mode of the top bar and
    // the tab of the full-screen player (0 = player, 1 = queue, 2 = lyrics).
    [ObservableProperty] private bool _isNowPlayingOpen;
    [ObservableProperty] private bool _isSearchOpen;
    [ObservableProperty] private int _nowPlayingTab;

    /// <summary>
    /// Whether the phone layout draws the performance statistics (frame graphs and counters) over the app. A tuning tool: it is
    /// off until the user turns it on in the settings, and the choice is remembered.
    /// </summary>
    [ObservableProperty] private bool _showPerformanceStats;

    /// <summary>
    /// Whether a track that has no lyrics of its own is looked up online (LRCLIB). On by default; the Settings switch
    /// turns it off, and the choice is remembered. Only the track's title, artist, album and length are sent.
    /// </summary>
    [ObservableProperty] private bool _useOnlineLyrics = true;

    /// <summary>The languages the user can pick, with the active one marked.</summary>
    public IReadOnlyList<LanguageOptionViewModel> LanguageOptions { get; } =
        Localizer.Languages.Select(l => new LanguageOptionViewModel(l.Code, l.NativeName)).ToList();

    /// <summary>Text of the language picker's button: the active language's code, e.g. "EN".</summary>
    public string LanguageBadge => Localizer.Instance.Language.ToUpperInvariant();

    private readonly OnlineLyrics? _onlineLyrics;

    /// <param name="onlineLyrics">The internet lyrics lookup; null (as in most tests) means tracks are never looked up online.</param>
    public MainViewModel(WiretuneAudioEngine audioEngine, LibraryService library, ServerSession session, OnlineLyrics? onlineLyrics = null)
    {
        Theme = new ThemeService();
        AudioEngine = audioEngine;
        Library = library;
        Session = session;
        _onlineLyrics = onlineLyrics;

        // Stream URLs carry a short-lived, media-only token that the session renews, not the login token.
        AudioEngine.SetStreamTokenProvider(Session.GetStreamTokenAsync);

        Player = new PlayerViewModel(AudioEngine, Library)
        {
            LyricsProvider = (track, ct) => track.IsLocal ? MetadataScanner.ReadLyricsAsync(track.FilePath, ct) : Session.GetLyricsAsync(track, ct),
            IsOnlineLyricsEnabled = UseOnlineLyrics,
        };
        if (onlineLyrics != null) Player.OnlineLyricsProvider = onlineLyrics.FindAsync;
        Tracks = new TracksViewModel(Library, Player);
        Albums = new AlbumsViewModel(Library, Player);
        Artists = new ArtistsViewModel(Library, Player);
        Playlists = new PlaylistsViewModel(Library, Player);
        Favorites = new FavoritesViewModel(Library, Player);
        AudiophileSettings = new AudiophileSettingsViewModel(AudioEngine);
        ServerSettings = new ServerSettingsViewModel(Library, Session);
        Search = new SearchResultsViewModel(Library, Player, q => SearchQuery = q, OpenAlbum, OpenArtist);

        // The full-screen player has nothing to show once the queue has been cleared.
        Player.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PlayerViewModel.CurrentTrack) && Player.CurrentTrack == null) IsNowPlayingOpen = false;
        };

        AudioEngine.TrackChanged += (_, _) => Ui.Post(UpdateStatusText);
        AudioEngine.BitperfectChanged += (_, _) => Ui.Post(UpdateStatusText);
        AudioEngine.ExclusiveModeChanged += (_, _) => Ui.Post(UpdateStatusText);
        AudioEngine.StateChanged += (_, _) => Ui.Post(UpdateStatusText);
        AudioEngine.DevicesChanged += (_, _) => Ui.Post(UpdateStatusText);
        Library.LibraryChanged += (_, _) => Ui.Post(UpdateStatusText);

        Session.StateChanged += (_, _) =>
        {
            CoverArtService.AuthToken = Session.AuthToken;
            CoverArtService.ServerUrl = Session.ServerUrl;
            Ui.Post(OnSessionStateChanged);
        };

        UpdateAuthDisplay();
        UpdateStatusText();
        Theme.UpdateDynamicBackground(SelectedSection);
        LogoTransform = LogoTransformFor(SelectedSection);

        Albums.OnNavWave = TriggerNavWave;
        Artists.OnNavWave = TriggerNavWave;
        Playlists.OnNavWave = TriggerNavWave;
        _previousSection = SelectedSection;

        Localizer.Instance.LanguageChanged += OnLanguageChanged;
        SyncLanguageOptions();
    }

    private void OnLanguageChanged(object? sender, EventArgs e) => Ui.Post(() =>
    {
        SyncLanguageOptions();
        OnPropertyChanged(nameof(LanguageBadge));
        RefreshLocalizedTexts();
    });

    private void SyncLanguageOptions()
    {
        foreach (var option in LanguageOptions) option.IsSelected = option.Code == Localizer.Instance.Language;
    }

    /// <summary>Recomputes every text that view models formatted earlier, after the language changed.</summary>
    private void RefreshLocalizedTexts()
    {
        OnSessionStateChanged();
        Tracks.RefreshTracks();
        Albums.RefreshLocalizedTexts();
        Artists.RefreshLocalizedTexts();
        Player.RefreshLocalizedTexts();
        Playlists.RefreshLocalizedTexts();
        Favorites.RefreshLocalizedTexts();
        Search.RefreshLocalizedTexts();
        AudiophileSettings.RefreshLocalizedTexts();
        ServerSettings.RefreshLocalizedTexts();
    }

    /// <summary>Switches the interface language and remembers the choice.</summary>
    [RelayCommand]
    public void ChangeLanguage(string? code)
    {
        if (!Localizer.Instance.SetLanguage(code)) return;
        Ui.Forget(Library.SetPreferenceAsync(LanguagePreference, Localizer.Instance.Language), "MainViewModel");
    }

    private const string LanguagePreference = "Language";
    private const string ThemePreference = "Theme";
    private const string PerformanceStatsPreference = "ShowPerformanceStats";
    private const string OnlineLyricsPreference = "OnlineLyrics";

    // True while the saved preferences are applied, so that applying them does not write them back.
    private bool _isApplyingPreferences;

    partial void OnShowPerformanceStatsChanged(bool value)
    {
        if (_isApplyingPreferences) return;
        Ui.Forget(Library.SetPreferenceAsync(PerformanceStatsPreference, value ? "1" : "0"), "MainViewModel");
    }

    partial void OnUseOnlineLyricsChanged(bool value)
    {
        Player.IsOnlineLyricsEnabled = value;
        if (_isApplyingPreferences) return;
        Ui.Forget(Library.SetPreferenceAsync(OnlineLyricsPreference, value ? "1" : "0"), "MainViewModel");
    }

    /// <summary>Applies the language and theme the user picked in an earlier session.</summary>
    private async Task ApplyPreferencesAsync()
    {
        var language = Localizer.Normalize(await Library.GetPreferenceAsync(LanguagePreference));
        if (language != null) Localizer.Instance.SetLanguage(language);

        if (await Library.GetPreferenceAsync(ThemePreference) is { } theme)
        {
            Theme.SetTheme(string.Equals(theme, "Light", StringComparison.OrdinalIgnoreCase));
        }

        var stats = await Library.GetPreferenceAsync(PerformanceStatsPreference);
        var onlineLyrics = await Library.GetPreferenceAsync(OnlineLyricsPreference);
        _isApplyingPreferences = true;
        try
        {
            ShowPerformanceStats = stats == "1";
            UseOnlineLyrics = onlineLyrics != "0"; // on unless the user turned it off
        }
        finally { _isApplyingPreferences = false; }
    }

    /// <summary>Creates the production object graph (SQLite cache, ffplay or platform audio driver).</summary>
    public static MainViewModel CreateDefault(IAudioDriver? audioDriver = null)
    {
        var repository = new LibraryRepository(new DatabaseManager());
        var library = new LibraryService(repository, new MetadataScanner());
        var session = new ServerSession(library, repository);
        return new MainViewModel(new WiretuneAudioEngine(audioDriver), library, session, OnlineLyrics.CreateDefault());
    }

    /// <summary>Loads the local cache, then reconnects to the server if it is the library source.</summary>
    public async Task StartAsync()
    {
        try
        {
            await Library.InitializeAsync();
            await ApplyPreferencesAsync();
            await Session.InitializeAsync();
            ServerSettings.SyncWithSession();
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("MainViewModel", $"Startup failed: {ex.Message}", ex);
            StatusText = Localizer.Format("StartupError", ex.Message);
            return;
        }
        finally
        {
            // The cached library is usable now; the server connection below may take a while.
            IsStarting = false;
            UpdateStatusText();
        }

        if (Session.Source is LibrarySource.Server or LibrarySource.Hybrid)
        {
            await Session.ConnectAsync();
        }

        IsLoginViewActive = (Session.Source == LibrarySource.None && Library.Tracks.Count == 0) ||
                            (Session.Source == LibrarySource.Server && Session.State is ServerConnectionState.LoginRequired or ServerConnectionState.SetupRequired);
    }

    private void OnSessionStateChanged()
    {
        IsServerOfflineBannerVisible = (Session.Source is LibrarySource.Server or LibrarySource.Hybrid) && Session.State == ServerConnectionState.Offline;
        if (Session.Source == LibrarySource.Hybrid && Session.State == ServerConnectionState.Offline)
        {
            ServerBannerMessage = Localizer.Format("ServerBannerOffline", Session.ServerUrl);
        }
        else
        {
            ServerBannerMessage = Session.StatusMessage ?? Localizer.Format("ServerBannerUnreachable", Session.ServerUrl);
        }

        if (Session.IsLoggedIn) IsLoginViewActive = false;

        UpdateAuthDisplay();
        UpdateStatusText();
    }

    private void UpdateAuthDisplay()
    {
        IsUserLoggedIn = Session.IsLoggedIn;
        CurrentUserBadge = Session.CurrentUser is { } user ? user.Username : Localizer.Get("SignIn");
    }

    private void UpdateStatusText()
    {
        IsLibraryEmpty = !IsStarting && Library.Tracks.Count == 0;

        var device = AudioEngine.CurrentDevice;
        var mode = Localizer.Get(AudioEngine.IsBitperfect ? "ModeBitPerfect" : AudioEngine.IsExclusiveMode ? "ModeExclusive" : "ModeShared");
        var deviceName = device?.Name ?? Localizer.Get("DefaultOutput");
        var driver = !string.IsNullOrWhiteSpace(device?.DriverType) ? $"[{device.DriverType}]" : string.Empty;

        // Left side: Mode and Device (Format is already displayed on player bar, remove Kimenet: word)
        StatusText = string.IsNullOrEmpty(driver)
            ? $"{mode} • {deviceName}"
            : $"{mode} • {deviceName} {driver}";

        // Right side: Library Info in order: x artists • x albums • x songs (x local, x server)
        if (Library.IsScanning)
        {
            RightFooterStatusText = Localizer.Get("FooterScanning");
            return;
        }

        var songCount = Library.Tracks.Count;
        var albumCount = Library.Albums.Count;
        var artistCount = Library.Artists.Count;
        var localCount = Library.Tracks.Count(t => t.IsLocal);
        var serverCount = Library.Tracks.Count(t => !t.IsLocal);

        if (songCount == 0)
        {
            RightFooterStatusText = Localizer.Get("FooterNoTracks");
            return;
        }

        var counts = $"{Localizer.Format("ArtistCount", artistCount)} • {Localizer.Format("AlbumCount", albumCount)} • {Localizer.Format("TrackCount", songCount)}";
        var origin = localCount > 0 && serverCount > 0 ? Localizer.Format("FooterLocalAndServer", localCount, serverCount)
            : serverCount > 0 ? Localizer.Format("FooterServerOnly", serverCount)
            : Localizer.Format("FooterLocalOnly", localCount);
        RightFooterStatusText = $"{counts} {origin}";
    }

    public void TriggerNavWave(NavWaveDirection direction)
    {
        LastWaveDirection = direction;
        WaveTrigger++;
    }

    /// <summary>Where a section is drawn in the sidebar, counted from the top: the order the navigation wave runs in.</summary>
    public static int GetNavVisualOrder(AppSection section) => section switch
    {
        AppSection.Artists => 0,
        AppSection.Albums => 1,
        AppSection.Tracks => 2,
        AppSection.Favorites => 3,
        AppSection.Playlists => 4,
        AppSection.Settings => 5,
        _ => (int)section
    };

    private static string LogoTransformFor(AppSection section) => $"rotate({(int)section * 90}deg)";

    partial void OnSelectedSectionChanged(AppSection value)
    {
        Player.CloseQueue();
        Theme.UpdateDynamicBackground(value);
        LogoTransform = LogoTransformFor(value);

        if (_previousSection != value)
        {
            if (!_isRestoringTab) RememberTab(_previousSection, value);

            var oldOrder = GetNavVisualOrder(_previousSection);
            var newOrder = GetNavVisualOrder(value);
            if (newOrder > oldOrder)
            {
                TriggerNavWave(NavWaveDirection.LeftToRight); // downwards
            }
            else if (newOrder < oldOrder)
            {
                TriggerNavWave(NavWaveDirection.RightToLeft); // upwards
            }
        }
        _previousSection = value;
    }

    /// <summary>Keeps <see cref="_tabHistory"/>: leaving a tab adds it, returning to a tab already in the list cuts the list back to it.</summary>
    private void RememberTab(AppSection from, AppSection to)
    {
        var index = _tabHistory.LastIndexOf(to);
        if (index >= 0) _tabHistory.RemoveRange(index, _tabHistory.Count - index);
        else _tabHistory.Add(from);
    }

    partial void OnSearchQueryChanged(string value)
    {
        Search.UpdateQuery(value);
        IsSearchActive = !string.IsNullOrWhiteSpace(value);
    }

    partial void OnIsSearchActiveChanged(bool value)
    {
        if (value) IsSearchOpen = true;
        // A result was opened (the query is kept so that "back" can return to it): leave the search mode.
        else if (SearchQuery.Length > 0) IsSearchOpen = false;
    }

    partial void OnIsNowPlayingOpenChanged(bool value)
    {
        if (!value) NowPlayingTab = 0;
    }

    partial void OnNowPlayingTabChanged(int value) => Player.IsQueueOpen = value != 0;

    [RelayCommand]
    public void ClearSearch() => SearchQuery = string.Empty;

    [RelayCommand]
    public void OpenSearch() => IsSearchOpen = true;

    [RelayCommand]
    public void CloseSearch()
    {
        SearchQuery = string.Empty;
        IsSearchOpen = false;
    }

    [RelayCommand]
    public void OpenNowPlaying()
    {
        if (Player.CurrentTrack != null) IsNowPlayingOpen = true;
    }

    [RelayCommand]
    public void CloseNowPlaying() => IsNowPlayingOpen = false;

    /// <param name="parameter">0 = player, 1 = queue, 2 = lyrics.</param>
    [RelayCommand]
    public void SetNowPlayingTab(object? parameter)
    {
        if (int.TryParse(parameter?.ToString(), out var tab) && tab is >= 0 and <= 2) NowPlayingTab = tab;
    }

    /// <summary>The back button of the phone layout: see <see cref="TryNavigateBack"/>.</summary>
    [RelayCommand]
    public void GoBack() => TryNavigateBack();

    /// <summary>
    /// The phone's back gesture: closes the innermost open layer (dialog, full-screen player, sign-in screen, search,
    /// detail page) and then walks back through the tabs the user has visited. It says whether it did anything; when it
    /// returns false there is nothing left to go back to and the app may close.
    /// </summary>
    public bool TryNavigateBack()
    {
        if (Playlists.IsCreateDialogOpen) { Playlists.CloseCreateDialog(); return true; }
        if (Playlists.IsAddToPlaylistDialogOpen) { Playlists.CancelAddTrack(); return true; }
        if (Playlists.IsDeleteConfirmOpen) { Playlists.CancelDeletePlaylist(); return true; }

        if (IsNowPlayingOpen)
        {
            // The queue and the lyrics are pages of the full-screen player: back returns to the player, then closes it.
            if (NowPlayingTab != 0) NowPlayingTab = 0;
            else IsNowPlayingOpen = false;
            return true;
        }

        // The sign-in screen is shown over an empty library; leaving it to reach the (empty) app would be a dead end.
        if (IsLoginViewActive && Library.Tracks.Count > 0) { IsLoginViewActive = false; return true; }

        if (IsSearchOpen) { CloseSearch(); return true; }

        switch (SelectedSection)
        {
            case AppSection.Albums when Albums.IsAlbumDetailOpen: Albums.CloseAlbumDetail(); return true;
            case AppSection.Artists when Artists.IsArtistDetailOpen: Artists.CloseArtistDetail(); return true;
            case AppSection.Playlists when Playlists.IsPlaylistDetailOpen: Playlists.ClosePlaylistDetail(); return true;
        }

        // Back from a tab goes to the tab the user came from. The tab is shown as it was left (an open album stays open).
        if (_tabHistory.Count > 0)
        {
            var previous = _tabHistory[^1];
            _tabHistory.RemoveAt(_tabHistory.Count - 1);

            _isRestoringTab = true;
            try { SelectedSection = previous; }
            finally { _isRestoringTab = false; }
            return true;
        }

        return false;
    }

    [RelayCommand]
    public void NavigateTo(AppSection section)
    {
        if (!Enum.IsDefined(section)) return;

        if (section == AppSection.Albums) { Albums.ReturnAction = null; Albums.CloseAlbumDetail(); }
        else if (section == AppSection.Artists) { Artists.ReturnAction = null; Artists.CloseArtistDetail(); }

        SearchQuery = string.Empty;
        IsSearchOpen = false;
        SelectedSection = section;
    }

    /// <summary>
    /// What "back" does on an album or artist page opened from where the user is now: return to the search results, to the
    /// detail page the user came from, or to the tab. <paramref name="target"/> is the section being opened; one of its own
    /// detail pages is never the origin.
    /// </summary>
    private (Func<string>? BackText, Action? OnReturn) CaptureOrigin(AppSection target)
    {
        if (IsSearchActive)
        {
            var activeQuery = SearchQuery;
            return (() => Localizer.Get("BackToSearch"), () =>
            {
                SearchQuery = activeQuery;
                IsSearchActive = true;
            });
        }

        switch (SelectedSection)
        {
            case AppSection.Albums when target != AppSection.Albums && Albums.IsAlbumDetailOpen && Albums.SelectedAlbum != null:
                var returnAlbum = Albums.SelectedAlbum!;
                return (() => Localizer.Format("BackTo", returnAlbum.Title), () =>
                {
                    SelectedSection = AppSection.Albums;
                    Albums.OpenAlbumWithOrigin(returnAlbum, null, null, NavWaveDirection.RightToLeft);
                });

            case AppSection.Artists when target != AppSection.Artists && Artists.IsArtistDetailOpen && Artists.SelectedArtist != null:
                var returnArtist = Artists.SelectedArtist!;
                return (() => Localizer.Format("BackTo", returnArtist.Name), () =>
                {
                    SelectedSection = AppSection.Artists;
                    Artists.OpenArtistWithOrigin(returnArtist, null, null, NavWaveDirection.RightToLeft);
                });

            case AppSection.Playlists when Playlists.IsPlaylistDetailOpen && Playlists.SelectedPlaylist != null:
                var returnPlaylist = Playlists.SelectedPlaylist!;
                return (() => Localizer.Format("BackTo", returnPlaylist.Name), () =>
                {
                    SelectedSection = AppSection.Playlists;
                    Playlists.OpenPlaylist(returnPlaylist);
                });

            case AppSection.Favorites:
                return (() => Localizer.Get("BackToFavorites"), () => SelectedSection = AppSection.Favorites);

            case AppSection.Tracks:
                return (() => Localizer.Get("BackToTracks"), () => SelectedSection = AppSection.Tracks);

            default:
                return (null, null);
        }
    }

    [RelayCommand]
    public void OpenAlbum(object? parameter)
    {
        var album = parameter switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            Track t => Library.GetAlbumForTrack(t),
            _ => null
        };
        if (album == null) return;

        var (backText, onReturn) = CaptureOrigin(AppSection.Albums);
        Albums.OpenAlbumWithOrigin(album, backText, onReturn);
        IsNowPlayingOpen = false;
        IsSearchActive = false;
        SelectedSection = AppSection.Albums;
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;

        var (backText, onReturn) = CaptureOrigin(AppSection.Artists);
        Artists.OpenArtistWithOrigin(artist, backText, onReturn);
        IsNowPlayingOpen = false;
        IsSearchActive = false;
        SelectedSection = AppSection.Artists;
    }

    [RelayCommand]
    public void OpenArtistByName(string? artistName)
    {
        if (!string.IsNullOrWhiteSpace(artistName)) OpenArtist(Library.GetArtistByName(artistName));
    }

    [RelayCommand]
    public void AddToPlaylist(Track? track)
    {
        if (track != null) Playlists.BeginAddTrack(track);
    }

    [RelayCommand]
    public Task RetryConnectServerAsync() => Session.ConnectAsync();

    [RelayCommand]
    public void DismissServerBanner() => IsServerOfflineBannerVisible = false;

    [RelayCommand]
    public void ToggleTheme()
    {
        Theme.ToggleTheme();
        Ui.Forget(Library.SetPreferenceAsync(ThemePreference, Theme.IsLight ? "Light" : "Dark"), "MainViewModel");
    }

    [RelayCommand]
    public void ContinueOffline() => IsLoginViewActive = false;

    [RelayCommand]
    public void ShowLoginScreen() => IsLoginViewActive = true;

    [RelayCommand]
    public async Task LogoutAsync()
    {
        await ServerSettings.LogoutAsync();
        UpdateAuthDisplay();
        IsLoginViewActive = Library.Tracks.Count == 0;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Localizer.Instance.LanguageChanged -= OnLanguageChanged;
        AudioEngine.Dispose();
        Session.Dispose();
        _onlineLyrics?.Dispose();
        GC.SuppressFinalize(this);
    }
}




