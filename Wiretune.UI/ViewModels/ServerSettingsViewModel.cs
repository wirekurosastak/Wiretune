using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class ServerSettingsViewModel : ObservableObject
{
    private readonly ILibraryService _library;
    private readonly ServerSession _session;

    [ObservableProperty] private string _serverUrl = ServerSession.DefaultServerUrl;
    [ObservableProperty] private string _localLibraryPath = string.Empty;
    [ObservableProperty] private bool _isServerConnected;
    [ObservableProperty] private bool _isServerReachable;
    [ObservableProperty] private bool _isConnecting;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private double _scanProgress;
    [ObservableProperty] private string _statusMessage = "Készenlétben";
    [ObservableProperty] private int _totalTracksCount;
    [ObservableProperty] private int _totalAlbumsCount;
    [ObservableProperty] private int _totalArtistsCount;
    [ObservableProperty] private string _serverStatusBadge = "Nincs kapcsolat";
    [ObservableProperty] private string _librarySourceText = "Nincs kiválasztott könyvtár";

    [ObservableProperty] private string _username = string.Empty;
    [ObservableProperty] private string _password = string.Empty;
    [ObservableProperty] private string _displayName = string.Empty;
    [ObservableProperty] private bool _stayLoggedIn = true;
    [ObservableProperty] private bool _isLoggedIn;
    [ObservableProperty] private bool _isAdmin;
    [ObservableProperty] private bool _isSetupRequired;
    [ObservableProperty] private string _currentUserName = string.Empty;
    [ObservableProperty] private string _currentUserRole = string.Empty;
    [ObservableProperty] private string _authErrorMessage = string.Empty;
    [ObservableProperty] private bool _hasAuthError;
    [ObservableProperty] private bool _isAuthenticating;
    [ObservableProperty] private bool _isServerOffline;

    private string? _lastSyncedServerUrl;

    public string PasswordHint => $"Jelszó (legalább {AuthRules.MinPasswordLength} karakter)";
    public bool IsBusy => IsConnecting || IsAuthenticating || (IsScanning && IsServerConnected);
    public bool CanRescanServer => IsLoggedIn && IsAdmin && !IsScanning;

    partial void OnIsConnectingChanged(bool value) => OnPropertyChanged(nameof(IsBusy));
    partial void OnIsAuthenticatingChanged(bool value) => OnPropertyChanged(nameof(IsBusy));
    partial void OnIsLoggedInChanged(bool value) => OnPropertyChanged(nameof(CanRescanServer));
    partial void OnIsAdminChanged(bool value) => OnPropertyChanged(nameof(CanRescanServer));

    partial void OnIsScanningChanged(bool value)
    {
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(CanRescanServer));
    }

    public ServerSettingsViewModel(ILibraryService library, ServerSession session)
    {
        _library = library;
        _session = session;

        LocalLibraryPath = !string.IsNullOrWhiteSpace(_library.LibraryPath)
            ? _library.LibraryPath
            : Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);

        _library.LibraryChanged += (_, _) => Ui.Post(UpdateStats);
        _library.ScanningStateChanged += (_, scanning) => Ui.Post(() => IsScanning = scanning);
        _session.StateChanged += (_, _) => Ui.Post(SyncWithSession);

        SyncWithSession();
        UpdateStats();
    }

    public void SyncWithSession()
    {
        // Only overwrite the text box when the session's address actually changed, not while the user is typing.
        if (_lastSyncedServerUrl != _session.ServerUrl)
        {
            _lastSyncedServerUrl = _session.ServerUrl;
            ServerUrl = _session.ServerUrl;
        }

        IsServerConnected = _session.IsLoggedIn;
        IsServerReachable = _session.IsServerReachable;
        IsServerOffline = _session.State == ServerConnectionState.Offline;
        IsConnecting = _session.State == ServerConnectionState.Connecting;
        IsLoggedIn = _session.IsLoggedIn;
        IsSetupRequired = _session.State == ServerConnectionState.SetupRequired;
        IsAdmin = _session.CurrentUser?.IsAdmin == true;
        CurrentUserName = _session.CurrentUser?.DisplayName ?? _session.CurrentUser?.Username ?? string.Empty;
        CurrentUserRole = IsAdmin ? "Adminisztrátor" : "Felhasználó";
        if (!string.IsNullOrWhiteSpace(_session.StatusMessage)) StatusMessage = _session.StatusMessage;

        ServerStatusBadge = _session.State switch
        {
            ServerConnectionState.Connected => $"Online • {CurrentUserName}",
            ServerConnectionState.Connecting => "Kapcsolódás...",
            ServerConnectionState.LoginRequired => "Online • bejelentkezés szükséges",
            ServerConnectionState.SetupRequired => "Online • beállítás szükséges",
            ServerConnectionState.Offline => "Nem elérhető",
            _ => "Nincs kapcsolat"
        };

        LibrarySourceText = _session.Source switch
        {
            LibrarySource.Server => $"Szerver könyvtár ({_session.ServerUrl})",
            LibrarySource.Local => $"Helyi mappa ({_library.LibraryPath})",
            _ => "Nincs kiválasztott könyvtár"
        };
    }

    private void UpdateStats()
    {
        TotalTracksCount = _library.Tracks.Count;
        TotalAlbumsCount = _library.Albums.Count;
        TotalArtistsCount = _library.Artists.Count;
    }

    private void ShowAuthError(string? message)
    {
        AuthErrorMessage = message ?? string.Empty;
        HasAuthError = !string.IsNullOrEmpty(message);
    }

    [RelayCommand]
    public async Task ConnectServerAsync()
    {
        ShowAuthError(null);
        await _session.ConnectAsync(ServerUrl);
        SyncWithSession();
    }

    [RelayCommand]
    public async Task LoginAsync()
    {
        if (string.IsNullOrWhiteSpace(Username) || string.IsNullOrEmpty(Password))
        {
            ShowAuthError("Add meg a felhasználónevet és a jelszót!");
            return;
        }

        IsAuthenticating = true;
        ShowAuthError(null);
        try
        {
            if (!_session.IsServerReachable || _session.State == ServerConnectionState.SetupRequired || !string.Equals(ServerUrl.Trim().TrimEnd('/'), _session.ServerUrl, StringComparison.OrdinalIgnoreCase))
            {
                await _session.ConnectAsync(ServerUrl);
            }

            if (_session.State == ServerConnectionState.Offline)
            {
                ShowAuthError(_session.StatusMessage);
                return;
            }

            if (_session.State == ServerConnectionState.SetupRequired)
            {
                ShowAuthError("A szerver még nincs beállítva: előbb hozd létre az adminisztrátori fiókot.");
                return;
            }

            if (_session.IsLoggedIn)
            {
                Password = string.Empty;
                return;
            }

            var error = await _session.LoginAsync(Username, Password, StayLoggedIn);
            ShowAuthError(error);
            if (error == null) Password = string.Empty;
        }
        finally
        {
            IsAuthenticating = false;
            SyncWithSession();
        }
    }

    [RelayCommand]
    public async Task SetupAdminAsync()
    {
        if (string.IsNullOrWhiteSpace(Username) || string.IsNullOrEmpty(Password))
        {
            ShowAuthError("Add meg az admin felhasználónevet és jelszót!");
            return;
        }

        if (Password.Length < AuthRules.MinPasswordLength)
        {
            ShowAuthError($"A jelszónak legalább {AuthRules.MinPasswordLength} karakter hosszúnak kell lennie!");
            return;
        }

        IsAuthenticating = true;
        ShowAuthError(null);
        try
        {
            var error = await _session.SetupAdminAsync(Username, Password, string.IsNullOrWhiteSpace(DisplayName) ? null : DisplayName);
            ShowAuthError(error);
            if (error == null) Password = string.Empty;
        }
        finally
        {
            IsAuthenticating = false;
            SyncWithSession();
        }
    }

    [RelayCommand]
    public async Task LogoutAsync()
    {
        await _session.LogoutAsync();
        SyncWithSession();
    }

    [RelayCommand]
    public async Task RescanServerAsync()
    {
        if (!_session.IsLoggedIn)
        {
            StatusMessage = "Előbb jelentkezz be a szerverre.";
            return;
        }

        IsScanning = true;
        StatusMessage = "Szerveroldali újraindexelés elindítva...";
        try
        {
            await _session.TriggerServerScanAsync();

            // The server scans in the background; poll its status until it settles.
            var deadline = DateTime.UtcNow.AddMinutes(10);
            ServerLibraryStatus status;
            do
            {
                await Task.Delay(1500);
                status = await _session.GetLibraryStatusAsync();
                StatusMessage = status.IsScanning
                    ? $"A szerver indexel... ({status.TrackCount} szám eddig)"
                    : "Indexelés kész, könyvtár frissítése...";
            } while (status.IsScanning && DateTime.UtcNow < deadline);

            await _session.RefreshLibraryAsync();
            StatusMessage = status.LastScanError is { Length: > 0 } err
                ? $"A szerver jelezte: {err}"
                : $"Szerver szinkronizálva: {_library.Tracks.Count} szám elérhető.";
        }
        catch (ServerRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden)
        {
            StatusMessage = "Az újraindexeléshez adminisztrátori jogosultság kell.";
        }
        catch (Exception ex) when (ex is ServerRequestException or ServerUnauthorizedException)
        {
            StatusMessage = $"Hiba az újraindexelés közben: {ex.Message}";
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
            StatusMessage = "A megadott mappa nem létezik!";
            return;
        }

        if (_library.IsScanning)
        {
            StatusMessage = "Már folyamatban van egy szkennelés.";
            return;
        }

        ScanProgress = 0;
        StatusMessage = "Zenefájlok keresése és metaadatok beolvasása...";
        var progress = new Progress<ScanProgressReport>(r => Dispatcher.UIThread.Post(() =>
        {
            ScanProgress = r.ProgressPercentage;
            StatusMessage = $"[{r.ScannedFiles}/{r.TotalEstimatedFiles}] {r.CurrentArtist} - {r.CurrentFile}";
        }));

        try
        {
            if (await _library.ScanFolderAsync(LocalLibraryPath, progress))
            {
                await _session.UseLocalLibraryAsync();
                ScanProgress = 100;
                StatusMessage = $"Helyi könyvtár beolvasva: {_library.Tracks.Count} szám.";
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Hiba a szkennelés közben: {ex.Message}";
        }
        finally
        {
            SyncWithSession();
        }
    }
}
