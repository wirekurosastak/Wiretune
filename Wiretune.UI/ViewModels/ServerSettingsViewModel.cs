using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;

namespace Wiretune.UI.ViewModels;

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

    // Authentication properties
    [ObservableProperty] private string _username = string.Empty;
    [ObservableProperty] private string _password = string.Empty;
    [ObservableProperty] private string _displayName = string.Empty;
    [ObservableProperty] private bool _stayLoggedIn = true;
    [ObservableProperty] private bool _isLoggedIn;
    [ObservableProperty] private bool _isSetupRequired;
    [ObservableProperty] private string _currentUserName = string.Empty;
    [ObservableProperty] private string _currentUserRole = string.Empty;
    [ObservableProperty] private string _authErrorMessage = string.Empty;
    [ObservableProperty] private bool _hasAuthError;
    [ObservableProperty] private bool _isAuthenticating;

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
        UpdateAuthStatus();
        UpdateStats();

        _library.LibraryChanged += (_, _) => Dispatcher.UIThread.Post(UpdateStats);
        _library.AuthStateChanged += (_, _) => Dispatcher.UIThread.Post(() =>
        {
            UpdateAuthStatus();
            UpdateStats();
        });
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

    private void UpdateAuthStatus()
    {
        IsLoggedIn = _library.IsLoggedIn;
        IsSetupRequired = _library.IsSetupRequired;
        CurrentUserName = _library.CurrentUser?.DisplayName ?? _library.CurrentUser?.Username ?? string.Empty;
        CurrentUserRole = _library.CurrentUser?.IsAdmin == true ? "Adminisztrátor" : "Felhasználó";
    }

    private void UpdateStats()
    {
        TotalTracksCount = _library.Tracks.Count;
        TotalAlbumsCount = _library.Albums.Count;
        TotalArtistsCount = _library.Artists.Count;
        IsServerConnected = _library.IsServerConnected;
        ServerStatusBadge = IsServerConnected
            ? (IsLoggedIn ? $"Online • {CurrentUserName}" : "Online (Bejelentkezés szükséges)")
            : "Helyi mód";
    }

    [RelayCommand]
    public async Task ConnectServerAsync()
    {
        ScanStatusText = $"Csatlakozás a szerverhez ({ServerUrl})...";
        await _library.ConnectServerAsync(ServerUrl);
        UpdateAuthStatus();
        UpdateStats();
        if (IsServerConnected)
        {
            if (IsSetupRequired)
            {
                ScanStatusText = "A szerver még nincs inicializálva! Hozz létre egy adminisztrátori fiókot.";
            }
            else if (!IsLoggedIn)
            {
                ScanStatusText = "Csatlakozva a szerverhez. A folytatáshoz kérlek jelentkezz be!";
            }
            else
            {
                ScanStatusText = TotalTracksCount > 0
                    ? $"Sikeres kapcsolódás! {TotalTracksCount} zeneszám betöltve a szerverről ({ServerUrl})."
                    : $"Kapcsolódva a szerverhez ({ServerUrl}), de a szerver még üres. A szerveroldali szkennelés elindult a háttérben...";
            }
        }
        else
        {
            ScanStatusText = $"Nem sikerült kapcsolódni a szerverhez ({ServerUrl}). Ellenőrizd a címet (pl. http://<szerver-ip>:5200) és a hálózatot!";
        }
    }

    [RelayCommand]
    public async Task LoginAsync()
    {
        if (string.IsNullOrWhiteSpace(Username) || string.IsNullOrWhiteSpace(Password))
        {
            AuthErrorMessage = "Kérlek add meg a felhasználónevet és a jelszót!";
            HasAuthError = true;
            return;
        }

        IsAuthenticating = true;
        HasAuthError = false;
        AuthErrorMessage = string.Empty;

        try
        {
            var success = await _library.LoginServerAsync(Username, Password, StayLoggedIn);
            if (success)
            {
                Password = string.Empty;
                UpdateAuthStatus();
                UpdateStats();
                ScanStatusText = $"Sikeres bejelentkezés ({CurrentUserName})!";
            }
            else
            {
                HasAuthError = true;
                AuthErrorMessage = "Hibás felhasználónév vagy jelszó!";
            }
        }
        catch (Exception ex)
        {
            HasAuthError = true;
            AuthErrorMessage = $"Hiba a bejelentkezés során: {ex.Message}";
        }
        finally
        {
            IsAuthenticating = false;
        }
    }

    [RelayCommand]
    public async Task SetupAdminAsync()
    {
        if (string.IsNullOrWhiteSpace(Username) || string.IsNullOrWhiteSpace(Password))
        {
            AuthErrorMessage = "Kérlek add meg az admin felhasználónevet és jelszót!";
            HasAuthError = true;
            return;
        }

        if (Password.Length < 6)
        {
            AuthErrorMessage = "A jelszónak legalább 6 karakter hosszúnak kell lennie!";
            HasAuthError = true;
            return;
        }

        IsAuthenticating = true;
        HasAuthError = false;
        AuthErrorMessage = string.Empty;

        try
        {
            var success = await _library.SetupServerAdminAsync(
                Username,
                Password,
                string.IsNullOrWhiteSpace(DisplayName) ? Username : DisplayName);

            if (success)
            {
                Password = string.Empty;
                UpdateAuthStatus();
                UpdateStats();
                ScanStatusText = "Admin fiók sikeresen létrehozva és bejelentkezve!";
            }
            else
            {
                HasAuthError = true;
                AuthErrorMessage = "Nem sikerült létrehozni az admin fiókot.";
            }
        }
        catch (Exception ex)
        {
            HasAuthError = true;
            AuthErrorMessage = $"Hiba a fiók létrehozásakor: {ex.Message}";
        }
        finally
        {
            IsAuthenticating = false;
        }
    }

    [RelayCommand]
    public async Task LogoutAsync()
    {
        await _library.LogoutServerAsync();
        UpdateAuthStatus();
        UpdateStats();
        ScanStatusText = "Kijelentkezve a szerverről.";
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
