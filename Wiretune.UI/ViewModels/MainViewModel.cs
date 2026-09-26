using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Audio;
using Wiretune.Audio.Drivers;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.Data;
using Wiretune.UI.Controls;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class MainViewModel : ObservableObject, IDisposable
{
    public const int CompactLayoutWidth = 1000;

    private bool _disposed;

    public ThemeService Theme { get; }
    public IAudioEngine AudioEngine { get; }
    public ILibraryService Library { get; }
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
    [ObservableProperty] private string _statusText = "Indítás...";
    [ObservableProperty] private string _rightFooterStatusText = "Wiretune";
    [ObservableProperty] private string _logoTransform = "rotate(0deg)";
    [ObservableProperty] private bool _isServerOfflineBannerVisible;
    [ObservableProperty] private string _serverBannerMessage = string.Empty;
    [ObservableProperty] private bool _isLoginViewActive;
    [ObservableProperty] private bool _isUserLoggedIn;
    [ObservableProperty] private string _currentUserBadge = "Bejelentkezés";
    [ObservableProperty] private bool _isCompactLayout;
    [ObservableProperty] private bool _isStarting = true;
    [ObservableProperty] private bool _isLibraryEmpty;

    public MainViewModel(IAudioEngine audioEngine, ILibraryService library, ServerSession session)
    {
        Theme = new ThemeService();
        AudioEngine = audioEngine;
        Library = library;
        Session = session;

        Player = new PlayerViewModel(AudioEngine, Library);
        Tracks = new TracksViewModel(Library, Player);
        Albums = new AlbumsViewModel(Library, Player);
        Artists = new ArtistsViewModel(Library, Player);
        Playlists = new PlaylistsViewModel(Library, Player);
        Favorites = new FavoritesViewModel(Library, Player);
        AudiophileSettings = new AudiophileSettingsViewModel(AudioEngine);
        ServerSettings = new ServerSettingsViewModel(Library, Session);
        Search = new SearchResultsViewModel(Library, Player, q => SearchQuery = q, OpenAlbum, OpenArtist);

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
            await Session.InitializeAsync();
            ServerSettings.SyncWithSession();
        }
        catch (Exception ex)
        {
            WiretuneLog.Error("MainViewModel", $"Startup failed: {ex.Message}", ex);
            StatusText = $"Indítási hiba: {ex.Message}";
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
            ServerBannerMessage = $"A Wiretune szerver ({Session.ServerUrl}) nem érhető el. A helyi zeneszámok továbbra is elérhetők offline módban.";
        }
        else
        {
            ServerBannerMessage = Session.StatusMessage ?? $"A Wiretune szerver ({Session.ServerUrl}) nem érhető el.";
        }

        if (Session.IsLoggedIn) IsLoginViewActive = false;

        UpdateAuthDisplay();
        UpdateStatusText();
    }

    private void UpdateAuthDisplay()
    {
        IsUserLoggedIn = Session.IsLoggedIn;
        CurrentUserBadge = Session.CurrentUser is { } user ? user.DisplayName ?? user.Username : "Bejelentkezés";
    }

    private void UpdateStatusText()
    {
        IsLibraryEmpty = !IsStarting && Library.Tracks.Count == 0;

        var device = AudioEngine.CurrentDevice;
        var mode = AudioEngine.IsBitperfect ? "Bit-Perfect" : AudioEngine.IsExclusiveMode ? "Exclusive" : "Megosztott";
        var deviceName = device?.Name ?? "Alapértelmezett kimenet";

        if (AudioEngine.CurrentTrack is { } track)
        {
            StatusText = $"Lejátszás: {track.Artist} - {track.Title} | {mode} -> {deviceName}";
            var fmt = track.Format;
            var quality = fmt.IsLossless
                ? $"{fmt.Codec.ToUpperInvariant()} {fmt.BitsPerSample}-bit/{fmt.SampleRate / 1000.0:0.#}kHz"
                : fmt.QualityLabel;
            RightFooterStatusText = $"{quality} • {device?.DriverType ?? "Audio"} • {mode}";
            return;
        }

        var source = Session.Source switch
        {
            LibrarySource.Hybrid => Session.IsLoggedIn
                ? $"Egyesített könyvtár (Szerver + Helyi) • {Library.Tracks.Count(t => t.IsLocal)} helyi, {Library.Tracks.Count(t => !t.IsLocal)} szerver"
                : $"Helyi könyvtár (Szerver offline) • {Library.Tracks.Count(t => t.IsLocal)} helyi szám",
            LibrarySource.Server => Session.IsLoggedIn ? "Szerver: online" : "Szerver: nem elérhető",
            LibrarySource.Local => "Helyi könyvtár",
            _ => "Nincs könyvtár"
        };
        StatusText = $"{mode} | Kimenet: {deviceName} | {source} | {Library.Tracks.Count} szám elérhető";
        RightFooterStatusText = $"Wiretune • {device?.DriverType ?? "Audio"}";
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

    [RelayCommand]
    public void ClearSearch() => SearchQuery = string.Empty;

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

        string? backText = null;
        Action? onReturn = null;

        if (SelectedNavigationIndex == 2 && Artists.IsArtistDetailOpen && Artists.SelectedArtist != null)
        {
            var returnArtist = Artists.SelectedArtist;
            backText = $"Vissza: {returnArtist.Name}";
            onReturn = () =>
            {
                SelectedNavigationIndex = 2;
                Artists.OpenArtistWithOrigin(returnArtist, null, null, NavWaveDirection.RightToLeft);
            };
        }
        else if (SelectedNavigationIndex == 3 && Playlists.IsPlaylistDetailOpen && Playlists.SelectedPlaylist != null)
        {
            var returnPlaylist = Playlists.SelectedPlaylist;
            backText = $"Vissza: {returnPlaylist.Name}";
            onReturn = () =>
            {
                SelectedNavigationIndex = 3;
                Playlists.OpenPlaylist(returnPlaylist);
            };
        }
        else if (SelectedNavigationIndex == 4)
        {
            backText = "Vissza a kedvencekhez";
            onReturn = () => SelectedNavigationIndex = 4;
        }
        else if (SelectedNavigationIndex == 0)
        {
            backText = "Vissza a számokhoz";
            onReturn = () => SelectedNavigationIndex = 0;
        }
        else if (IsSearchActive)
        {
            backText = "Vissza a kereséshez";
            onReturn = () => IsSearchActive = true;
        }

        SearchQuery = string.Empty;
        Albums.OpenAlbumWithOrigin(album, backText, onReturn);
        SelectedNavigationIndex = 1;
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;

        string? backText = null;
        Action? onReturn = null;

        if (SelectedNavigationIndex == 1 && Albums.IsAlbumDetailOpen && Albums.SelectedAlbum != null)
        {
            var returnAlbum = Albums.SelectedAlbum;
            backText = $"Vissza: {returnAlbum.Title}";
            onReturn = () =>
            {
                SelectedNavigationIndex = 1;
                Albums.OpenAlbumWithOrigin(returnAlbum, null, null, NavWaveDirection.RightToLeft);
            };
        }
        else if (SelectedNavigationIndex == 3 && Playlists.IsPlaylistDetailOpen && Playlists.SelectedPlaylist != null)
        {
            var returnPlaylist = Playlists.SelectedPlaylist;
            backText = $"Vissza: {returnPlaylist.Name}";
            onReturn = () =>
            {
                SelectedNavigationIndex = 3;
                Playlists.OpenPlaylist(returnPlaylist);
            };
        }
        else if (SelectedNavigationIndex == 4)
        {
            backText = "Vissza a kedvencekhez";
            onReturn = () => SelectedNavigationIndex = 4;
        }
        else if (SelectedNavigationIndex == 0)
        {
            backText = "Vissza a számokhoz";
            onReturn = () => SelectedNavigationIndex = 0;
        }
        else if (IsSearchActive)
        {
            backText = "Vissza a kereséshez";
            onReturn = () => IsSearchActive = true;
        }

        SearchQuery = string.Empty;
        Artists.OpenArtistWithOrigin(artist, backText, onReturn);
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
    public void ToggleTheme() => Theme.ToggleTheme();

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
        AudioEngine.Dispose();
        Session.Dispose();
        GC.SuppressFinalize(this);
    }
}
