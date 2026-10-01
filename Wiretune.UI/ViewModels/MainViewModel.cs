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

    [ObservableProperty] private int _selectedNavigationIndex = 2;
    [ObservableProperty] private int _waveTrigger;
    [ObservableProperty] private NavWaveDirection _lastWaveDirection = NavWaveDirection.LeftToRight;
    private int _previousNavIndex = 2;
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

    /// <summary>True on the playlists page and on the favorites page, which the phone layout files under "Playlists".</summary>
    public bool IsPlaylistsSectionActive => SelectedNavigationIndex is 3 or 4;

    /// <summary>The languages the user can pick, with the active one marked.</summary>
    public IReadOnlyList<LanguageOptionViewModel> LanguageOptions { get; } =
        Localizer.Languages.Select(l => new LanguageOptionViewModel(l.Code, l.NativeName)).ToList();

    /// <summary>Text of the language picker's button: the active language's code, e.g. "EN".</summary>
    public string LanguageBadge => Localizer.Instance.Language.ToUpperInvariant();

    public MainViewModel(WiretuneAudioEngine audioEngine, LibraryService library, ServerSession session)
    {
        Theme = new ThemeService();
        AudioEngine = audioEngine;
        Library = library;
        Session = session;

        Player = new PlayerViewModel(AudioEngine, Library)
        {
            LyricsProvider = (track, ct) => track.IsLocal ? MetadataScanner.ReadLyricsAsync(track.FilePath, ct) : Session.GetLyricsAsync(track, ct)
        };
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
            // Apply credentials immediately so a play command issued right after login is authorised.
            AudioEngine.SetStreamAuthorization(Session.AuthToken);
            CoverArtService.AuthToken = Session.AuthToken;
            CoverArtService.ServerUrl = Session.ServerUrl;
            Ui.Post(OnSessionStateChanged);
        };

        UpdateAuthDisplay();
        UpdateStatusText();
        Theme.UpdateDynamicBackground(SelectedNavigationIndex);
        LogoTransform = $"rotate({SelectedNavigationIndex * 90}deg)";

        Albums.OnNavWave = TriggerNavWave;
        Artists.OnNavWave = TriggerNavWave;
        Playlists.OnNavWave = TriggerNavWave;
        _previousNavIndex = SelectedNavigationIndex;

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

    /// <summary>Applies the language and theme the user picked in an earlier session.</summary>
    private async Task ApplyPreferencesAsync()
    {
        var language = Localizer.Normalize(await Library.GetPreferenceAsync(LanguagePreference));
        if (language != null) Localizer.Instance.SetLanguage(language);

        if (await Library.GetPreferenceAsync(ThemePreference) is { } theme)
        {
            Theme.SetTheme(string.Equals(theme, "Light", StringComparison.OrdinalIgnoreCase));
        }
    }

    /// <summary>Creates the production object graph (SQLite cache, ffplay or platform audio driver).</summary>
    public static MainViewModel CreateDefault(IAudioDriver? audioDriver = null)
    {
        var repository = new LibraryRepository(new DatabaseManager());
        var library = new LibraryService(repository, new MetadataScanner());
        var session = new ServerSession(library, repository);
        return new MainViewModel(new WiretuneAudioEngine(audioDriver), library, session);
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

    public static int GetNavVisualOrder(int navIndex) => navIndex switch
    {
        2 => 0, // Artists
        1 => 1, // Albums
        0 => 2, // Songs
        4 => 3, // Favorites
        3 => 4, // Playlists
        5 => 5, // Settings
        _ => navIndex
    };

    partial void OnSelectedNavigationIndexChanged(int value)
    {
        OnPropertyChanged(nameof(IsPlaylistsSectionActive));
        Player.CloseQueue();
        Theme.UpdateDynamicBackground(value);
        LogoTransform = $"rotate({value * 90}deg)";

        if (_previousNavIndex >= 0 && _previousNavIndex != value)
        {
            var oldOrder = GetNavVisualOrder(_previousNavIndex);
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
        _previousNavIndex = value;
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
    /// The phone's back gesture: closes the innermost open layer (dialog, full-screen player, search, detail page) and
    /// says whether it did. When it returns false, there is nothing left to go back to and the app may close.
    /// </summary>
    public bool TryNavigateBack()
    {
        if (Playlists.IsCreateDialogOpen) { Playlists.CloseCreateDialog(); return true; }
        if (Playlists.IsAddToPlaylistDialogOpen) { Playlists.CancelAddTrack(); return true; }
        if (Playlists.IsDeleteConfirmOpen) { Playlists.CancelDeletePlaylist(); return true; }
        if (IsNowPlayingOpen) { IsNowPlayingOpen = false; return true; }
        if (IsSearchOpen) { CloseSearch(); return true; }

        switch (SelectedNavigationIndex)
        {
            case 1 when Albums.IsAlbumDetailOpen: Albums.CloseAlbumDetail(); return true;
            case 2 when Artists.IsArtistDetailOpen: Artists.CloseArtistDetail(); return true;
            case 3 when Playlists.IsPlaylistDetailOpen: Playlists.ClosePlaylistDetail(); return true;
            case 4: NavigateTo(3); return true;
        }

        // The sign-in screen is shown over an empty library; leaving it to reach the (empty) app would be a dead end.
        if (IsLoginViewActive && Library.Tracks.Count > 0) { IsLoginViewActive = false; return true; }
        return false;
    }

    [RelayCommand]
    public void NavigateTo(object? parameter)
    {
        var targetIndex = parameter switch
        {
            int i => i,
            _ when int.TryParse(parameter?.ToString(), out var parsed) => parsed,
            _ => -1
        };
        if (targetIndex < 0 || targetIndex > 5) return;

        if (targetIndex == 1) { Albums.ReturnAction = null; Albums.CloseAlbumDetail(); }
        else if (targetIndex == 2) { Artists.ReturnAction = null; Artists.CloseArtistDetail(); }

        SearchQuery = string.Empty;
        IsSearchOpen = false;
        SelectedNavigationIndex = targetIndex;
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

        Func<string>? backText = null;
        Action? onReturn = null;

        if (IsSearchActive)
        {
            var activeQuery = SearchQuery;
            backText = () => Localizer.Get("BackToSearch");
            onReturn = () =>
            {
                SearchQuery = activeQuery;
                IsSearchActive = true;
            };
        }
        else if (SelectedNavigationIndex == 2 && Artists.IsArtistDetailOpen && Artists.SelectedArtist != null)
        {
            var returnArtist = Artists.SelectedArtist;
            backText = () => Localizer.Format("BackTo", returnArtist.Name);
            onReturn = () =>
            {
                SelectedNavigationIndex = 2;
                Artists.OpenArtistWithOrigin(returnArtist, null, null, NavWaveDirection.RightToLeft);
            };
        }
        else if (SelectedNavigationIndex == 3 && Playlists.IsPlaylistDetailOpen && Playlists.SelectedPlaylist != null)
        {
            var returnPlaylist = Playlists.SelectedPlaylist;
            backText = () => Localizer.Format("BackTo", returnPlaylist.Name);
            onReturn = () =>
            {
                SelectedNavigationIndex = 3;
                Playlists.OpenPlaylist(returnPlaylist);
            };
        }
        else if (SelectedNavigationIndex == 4)
        {
            backText = () => Localizer.Get("BackToFavorites");
            onReturn = () => SelectedNavigationIndex = 4;
        }
        else if (SelectedNavigationIndex == 0)
        {
            backText = () => Localizer.Get("BackToTracks");
            onReturn = () => SelectedNavigationIndex = 0;
        }

        Albums.OpenAlbumWithOrigin(album, backText, onReturn);
        IsNowPlayingOpen = false;
        IsSearchActive = false;
        SelectedNavigationIndex = 1;
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;

        Func<string>? backText = null;
        Action? onReturn = null;

        if (IsSearchActive)
        {
            var activeQuery = SearchQuery;
            backText = () => Localizer.Get("BackToSearch");
            onReturn = () =>
            {
                SearchQuery = activeQuery;
                IsSearchActive = true;
            };
        }
        else if (SelectedNavigationIndex == 1 && Albums.IsAlbumDetailOpen && Albums.SelectedAlbum != null)
        {
            var returnAlbum = Albums.SelectedAlbum;
            backText = () => Localizer.Format("BackTo", returnAlbum.Title);
            onReturn = () =>
            {
                SelectedNavigationIndex = 1;
                Albums.OpenAlbumWithOrigin(returnAlbum, null, null, NavWaveDirection.RightToLeft);
            };
        }
        else if (SelectedNavigationIndex == 3 && Playlists.IsPlaylistDetailOpen && Playlists.SelectedPlaylist != null)
        {
            var returnPlaylist = Playlists.SelectedPlaylist;
            backText = () => Localizer.Format("BackTo", returnPlaylist.Name);
            onReturn = () =>
            {
                SelectedNavigationIndex = 3;
                Playlists.OpenPlaylist(returnPlaylist);
            };
        }
        else if (SelectedNavigationIndex == 4)
        {
            backText = () => Localizer.Get("BackToFavorites");
            onReturn = () => SelectedNavigationIndex = 4;
        }
        else if (SelectedNavigationIndex == 0)
        {
            backText = () => Localizer.Get("BackToTracks");
            onReturn = () => SelectedNavigationIndex = 0;
        }

        Artists.OpenArtistWithOrigin(artist, backText, onReturn);
        IsNowPlayingOpen = false;
        IsSearchActive = false;
        SelectedNavigationIndex = 2;
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
        GC.SuppressFinalize(this);
    }
}




