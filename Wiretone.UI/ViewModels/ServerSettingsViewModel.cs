using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretone.Core.Models;
using Wiretone.Core.Services;

namespace Wiretone.UI.ViewModels;

public partial class ServerSettingsViewModel : ObservableObject
{
    private readonly ILibraryService _library;

    [ObservableProperty] private string _serverUrl = "http://localhost:5200";
    [ObservableProperty] private string _localLibraryPath = string.Empty;
    [ObservableProperty] private bool _isServerConnected;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private double _scanProgress;
    [ObservableProperty] private string _scanStatusText = "Készenlétben";
    [ObservableProperty] private int _totalTracksCount;
    [ObservableProperty] private int _totalAlbumsCount;
    [ObservableProperty] private int _totalArtistsCount;
    [ObservableProperty] private string _serverStatusBadge = "Offline";

    public ServerSettingsViewModel(ILibraryService library)
    {
        _library = library;

        ServerUrl = _library.ServerUrl;
        LocalLibraryPath = !string.IsNullOrWhiteSpace(_library.LibraryPath)
            ? _library.LibraryPath
            : (Directory.Exists("/home/wirekurosastak/Music")
                ? "/home/wirekurosastak/Music"
                : Environment.GetFolderPath(Environment.SpecialFolder.MyMusic));
        IsServerConnected = _library.IsServerConnected;
        UpdateStats();

        _library.LibraryChanged += (_, _) => Dispatcher.UIThread.Post(UpdateStats);
        _library.ScanningStateChanged += (_, scanning) => Dispatcher.UIThread.Post(() =>
        {
            IsScanning = scanning;
            if (!scanning)
            {
                ScanStatusText = "A könyvtár indexelése sikeresen befejeződött.";
                ScanProgress = 100;
            }
        });
    }

    private void UpdateStats()
    {
        TotalTracksCount = _library.Tracks.Count;
        TotalAlbumsCount = _library.Albums.Count;
        TotalArtistsCount = _library.Artists.Count;
        IsServerConnected = _library.IsServerConnected;
        ServerStatusBadge = IsServerConnected ? "Online (Streamelhető)" : "Helyi mód";
    }

    [RelayCommand]
    public async Task ConnectServerAsync()
    {
        ScanStatusText = $"Csatlakozás a szerverhez ({ServerUrl})...";
        await _library.ConnectServerAsync(ServerUrl);
        UpdateStats();
        if (IsServerConnected)
        {
            ScanStatusText = TotalTracksCount > 0
                ? $"Sikeres kapcsolódás! {TotalTracksCount} zeneszám betöltve a szerverről ({ServerUrl})."
                : $"Kapcsolódva a szerverhez ({ServerUrl}), de a szerver még üres. A szerveroldali szkennelés elindult a háttérben...";
        }
        else
        {
            ScanStatusText = $"Nem sikerült kapcsolódni a szerverhez ({ServerUrl}). Ellenőrizd a címet (pl. http://<szerver-ip>:5200) és a hálózatot!";
        }
    }

    [RelayCommand]
    public async Task RescanServerAsync()
    {
        if (!IsServerConnected)
        {
            ScanStatusText = "A szerver nem elérhető! Először kapcsolódj a szerverhez.";
            return;
        }

        IsScanning = true;
        ScanStatusText = "Szerveroldali könyvtár újraindexelése folyamatban...";
        try
        {
            var streamingClient = new ServerStreamingClient();
            var started = await streamingClient.TriggerScanAsync(ServerUrl);
            if (started)
            {
                ScanStatusText = "A szerver elkezdte a könyvtár felindexelését. Frissítés folyamatban...";
                for (int i = 0; i < 15; i++)
                {
                    await Task.Delay(1500);
                    await _library.ConnectServerAsync(ServerUrl);
                    UpdateStats();
                    if (TotalTracksCount > 0) break;
                }
                ScanStatusText = $"Szerver szinkronizálva! {TotalTracksCount} zeneszám elérhető a streaminghez.";
            }
            else
            {
                ScanStatusText = "A szerver nem tudta elindítani a szkennelést.";
            }
        }
        catch (Exception ex)
        {
            ScanStatusText = $"Hiba a szerver szkennelése közben: {ex.Message}";
        }
        finally
        {
            IsScanning = false;
        }
    }

    [RelayCommand]
    public async Task StartScanFolderAsync()
    {
        if (string.IsNullOrWhiteSpace(LocalLibraryPath) || !Directory.Exists(LocalLibraryPath))
        {
            ScanStatusText = "A megadott elérési út nem létezik!";
            return;
        }

        IsScanning = true;
        ScanProgress = 0;
        ScanStatusText = "Zenefájlok keresése és metaadatok beolvasása...";

        var progress = new Progress<ScanProgressReport>(r =>
        {
            Dispatcher.UIThread.Post(() =>
            {
                ScanProgress = r.ProgressPercentage;
                ScanStatusText = $"[{r.ScannedFiles}/{r.TotalEstimatedFiles}] {r.CurrentArtist} - {r.CurrentFile}";
            });
        });

        await _library.ScanFolderAsync(LocalLibraryPath, progress);
    }
}
