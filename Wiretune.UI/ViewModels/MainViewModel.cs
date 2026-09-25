using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Audio;
using Wiretune.Core.Audio;
using Wiretune.Core.Models;
using Wiretune.Core.Repositories;
using Wiretune.Core.Services;
using Wiretune.Data;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class MainViewModel : ObservableObject
{
    public ThemeService Theme { get; }
    public IAudioEngine AudioEngine { get; }
    public ILibraryService Library { get; }

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
    [ObservableProperty] private string _searchQuery = string.Empty;
    [ObservableProperty] private bool _isSearchActive;
    [ObservableProperty] private string _statusText = "Készenlétben";
    [ObservableProperty] private string _rightFooterStatusText = "Wiretune v1.0 • Hi-Fi Audio Engine Kész";
    [ObservableProperty] private string _logoTransform = "rotate(0deg)";
    [ObservableProperty] private bool _isServerOfflineBannerVisible = false;
    [ObservableProperty] private string _serverBannerMessage = string.Empty;

    public MainViewModel()
        : this(new WiretuneAudioEngine(), new LibraryService(new LibraryRepository(), new MetadataScanner()))
    {
    }

    public MainViewModel(IAudioEngine audioEngine, ILibraryService library)
    {
        Theme = new ThemeService();
        AudioEngine = audioEngine;
        Library = library;

        Player = new PlayerViewModel(AudioEngine, Library);
        Tracks = new TracksViewModel(Library, Player);
        Albums = new AlbumsViewModel(Library, Player);
        Artists = new ArtistsViewModel(Library, Player);
        Playlists = new PlaylistsViewModel(Library, Player);
        Favorites = new FavoritesViewModel(Library, Player);
        AudiophileSettings = new AudiophileSettingsViewModel(AudioEngine);
        ServerSettings = new ServerSettingsViewModel(Library);

        Search = new SearchResultsViewModel(
            Library,
            AudioEngine,
            Player,
            q => SearchQuery = q,
            album => OpenAlbum(album),
            artist => OpenArtist(artist));

        _ = Library.InitializeAsync();

        UpdateStatusText();
        AudioEngine.TrackChanged += (_, _) => DispatchToUI(UpdateStatusText);
        AudioEngine.BitperfectChanged += (_, _) => DispatchToUI(UpdateStatusText);
        AudioEngine.ExclusiveModeChanged += (_, _) => DispatchToUI(UpdateStatusText);
        AudioEngine.StateChanged += (_, _) => DispatchToUI(UpdateStatusText);

        Library.ServerStatusChanged += (_, msg) => DispatchToUI(() =>
        {
            if (!Library.IsServerConnected && !string.IsNullOrWhiteSpace(Library.ServerUrl))
            {
                ServerBannerMessage = msg ?? $"A WiretuneLibrary szerver ({Library.ServerUrl}) nem érhető el.";
                IsServerOfflineBannerVisible = true;
            }
            else
            {
                IsServerOfflineBannerVisible = false;
            }
            UpdateStatusText();
        });

        Library.LibraryChanged += (_, _) => DispatchToUI(UpdateStatusText);

        Theme.UpdateDynamicBackground(SelectedNavigationIndex);
        LogoTransform = $"rotate({SelectedNavigationIndex * 90}deg)";
    }

    private static void DispatchToUI(Action action)
    {
        if (Avalonia.Threading.Dispatcher.UIThread.CheckAccess())
        {
            action();
        }
        else
        {
            Avalonia.Threading.Dispatcher.UIThread.Post(action);
        }
    }

    private void UpdateStatusText()
    {
        if (AudioEngine.CurrentTrack != null)
        {
            var modeText = AudioEngine.IsBitperfect && AudioEngine.IsExclusiveMode
                ? "Bit-Perfect [Exclusive Direct]"
                : (AudioEngine.IsBitperfect
                    ? "Bit-Perfect [PipeWire]"
                    : (AudioEngine.IsExclusiveMode ? "Exclusive Direct" : "Standard [Shared]"));
            var dev = AudioEngine.CurrentDevice?.Name ?? "Audio DAC";
            StatusText = $"Lejátszás: {AudioEngine.CurrentTrack.Artist} - {AudioEngine.CurrentTrack.Title} | {modeText} -> {dev}";

            var fmt = AudioEngine.CurrentTrack.Format;
            var transport = AudioEngine.IsExclusiveMode
                ? "ALSA Direct (hw)"
                : (AudioEngine.IsBitperfect ? "PipeWire Bit-Perfect Clock" : "PipeWire Shared");
            RightFooterStatusText = $"{fmt.Codec.ToUpperInvariant()} {fmt.BitsPerSample}-bit/{fmt.SampleRate / 1000.0:0.#}kHz • {transport}";
        }
        else
        {
            var bp = AudioEngine.IsBitperfect ? "Bit-Perfect aktív" : (AudioEngine.IsExclusiveMode ? "Exclusive aktív" : "Standard audio");
            var dev = AudioEngine.CurrentDevice?.Name ?? "Alapértelmezett kimenet";
            var srv = Library.IsServerConnected ? "Szerver: Online" : (string.IsNullOrWhiteSpace(Library.ServerUrl) ? "Helyi könyvtár" : "Szerver: Nem elérhető");
            StatusText = $"{bp} | Kimenet: {dev} | {srv} | {Library.Tracks.Count} szám elérhető";
            RightFooterStatusText = "Wiretune v1.0 • Audiophile Native Engine Kész";
        }
    }

    partial void OnSelectedNavigationIndexChanged(int value)
    {
        Theme.UpdateDynamicBackground(value);
        LogoTransform = $"rotate({value * 90}deg)";
    }

    partial void OnSearchQueryChanged(string value)
    {
        Tracks.SearchFilter = value;
        Albums.SearchFilter = value;
        Artists.SearchFilter = value;
        Search.UpdateQuery(value);
        IsSearchActive = !string.IsNullOrWhiteSpace(value);
    }

    [RelayCommand]
    public void ClearSearch()
    {
        SearchQuery = string.Empty;
    }

    [RelayCommand]
    public void NavigateTo(object? parameter)
    {
        int targetIndex = -1;
        if (parameter is int i)
        {
            targetIndex = i;
        }
        else if (parameter != null && int.TryParse(parameter.ToString(), out var parsed))
        {
            targetIndex = parsed;
        }

        if (targetIndex >= 0)
        {
            if (targetIndex == 1)
            {
                Albums.CloseAlbumDetail();
            }
            else if (targetIndex == 2)
            {
                Artists.CloseArtistDetail();
            }
            SearchQuery = string.Empty;
            SelectedNavigationIndex = targetIndex;
        }
    }

    [RelayCommand]
    public void OpenAlbum(object? parameter)
    {
        Album? album = parameter switch
        {
            Album a => a,
            AlbumCardViewModel vm => vm.Album,
            _ => null
        };
        if (album == null) return;
        SearchQuery = string.Empty;
        Albums.OpenAlbum(album);
        SelectedNavigationIndex = 1;
    }

    [RelayCommand]
    public void OpenAlbumByTitle(string? albumTitle)
    {
        if (string.IsNullOrWhiteSpace(albumTitle)) return;
        var found = Library.Albums.FirstOrDefault(a => a.Title.Equals(albumTitle, StringComparison.OrdinalIgnoreCase));
        if (found != null)
        {
            OpenAlbum(found);
        }
    }

    [RelayCommand]
    public void OpenArtist(Artist? artist)
    {
        if (artist == null) return;
        SearchQuery = string.Empty;
        Artists.OpenArtist(artist);
        SelectedNavigationIndex = 2;
    }

    [RelayCommand]
    public void OpenArtistByName(string? artistName)
    {
        if (string.IsNullOrWhiteSpace(artistName)) return;
        var found = Library.Artists.FirstOrDefault(a => a.Name.Equals(artistName, StringComparison.OrdinalIgnoreCase));
        if (found != null)
        {
            OpenArtist(found);
        }
    }

    [RelayCommand]
    public async Task RetryConnectServerAsync()
    {
        if (!string.IsNullOrWhiteSpace(Library.ServerUrl))
        {
            await Library.ConnectServerAsync(Library.ServerUrl);
        }
    }

    [RelayCommand]
    public void DismissServerBanner()
    {
        IsServerOfflineBannerVisible = false;
    }

    [RelayCommand]
    public void ToggleTheme()
    {
        Theme.ToggleTheme();
    }

    public void Dispose()
    {
        AudioEngine.Dispose();
    }
}
