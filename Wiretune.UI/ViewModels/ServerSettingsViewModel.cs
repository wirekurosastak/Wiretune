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
    [ObservableProperty] private int _totalFavoritesCount;
    [ObservableProperty] private int _totalPlaylistsCount;
    [ObservableProperty] private string _serverStatusBadge = "Nincs kapcsolat";
    [ObservableProperty] private string _librarySourceText = "Nincs kiválasztott könyvtár";

    [ObservableProperty] private string _username = string.Empty;
    [ObservableProperty] private string _password = string.Empty;
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

    [ObservableProperty] private string _serverLibraryPath = string.Empty;
    [ObservableProperty] private bool _isLoadingServerConfig;
    [ObservableProperty] private bool _isUpdatingServerConfig;
    [ObservableProperty] private System.Collections.ObjectModel.ObservableCollection<UserInfo> _serverUsers = new();
    [ObservableProperty] private bool _isLoadingUsers;
    [ObservableProperty] private string _newUsername = string.Empty;
    [ObservableProperty] private string _newPassword = string.Empty;
    [ObservableProperty] private string _confirmPassword = string.Empty;
    [ObservableProperty] private bool _isAddingUser;
    [ObservableProperty] private string _userManagementErrorMessage = string.Empty;
    [ObservableProperty] private bool _hasUserManagementError;

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
        _library.PlaylistsChanged += (_, _) => Ui.Post(UpdateStats);
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
        CurrentUserName = _session.CurrentUser?.Username ?? string.Empty;
        CurrentUserRole = IsAdmin ? "Adminisztrátor" : "Felhasználó";
        if (!string.IsNullOrWhiteSpace(_session.StatusMessage)) StatusMessage = _session.StatusMessage;

        ServerStatusBadge = _session.State switch
        {
            ServerConnectionState.Connected => IsLoggedIn ? "Csatlakoztatva" : "Online",
            ServerConnectionState.Connecting => "Kapcsolódás...",
            ServerConnectionState.LoginRequired => "Bejelentkezés szükséges",
            ServerConnectionState.SetupRequired => "Beállítás szükséges",
            ServerConnectionState.Offline => "Offline",
            _ => "Nincs kapcsolat"
        };

        LibrarySourceText = _session.Source switch
        {
            LibrarySource.Hybrid => $"Egyesített ({_session.ServerUrl} + helyi mappa)",
            LibrarySource.Server => $"Szerver ({_session.ServerUrl})",
            LibrarySource.Local => $"Helyi mappa ({_library.LibraryPath})",
            _ => "Nincs aktív forrás"
        };

        if (IsLoggedIn && IsAdmin)
        {
            _ = LoadServerConfigAsync();
            _ = LoadUsersAsync();
        }
    }

    private void UpdateStats()
    {
        TotalTracksCount = _library.Tracks.Count;
        TotalAlbumsCount = _library.Albums.Count;
        TotalArtistsCount = _library.Artists.Count;
        TotalFavoritesCount = _library.Favorites.Count;
        TotalPlaylistsCount = _library.Playlists.Count;
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
            var error = await _session.SetupAdminAsync(Username, Password);
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
                var localCount = _library.Tracks.Count(t => t.IsLocal);
                var serverCount = _library.Tracks.Count(t => !t.IsLocal);
                StatusMessage = serverCount > 0
                    ? $"Könyvtár beolvasva: {localCount} helyi szám, {serverCount} szerver szám ({_library.Tracks.Count} összesen)."
                    : $"Helyi könyvtár beolvasva: {_library.Tracks.Count} szám.";
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

    [RelayCommand]
    public async Task LoadServerConfigAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        IsLoadingServerConfig = true;
        try
        {
            var config = await _session.GetServerConfigAsync();
            ServerLibraryPath = config.LibraryPath;
        }
        catch (Exception ex)
        {
            StatusMessage = $"Szerver beállítások betöltési hiba: {ex.Message}";
        }
        finally
        {
            IsLoadingServerConfig = false;
        }
    }

    [RelayCommand]
    public async Task UpdateServerLibraryPathAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        if (string.IsNullOrWhiteSpace(ServerLibraryPath))
        {
            StatusMessage = "Add meg a szerver zenemappájának elérését!";
            return;
        }

        IsUpdatingServerConfig = true;
        try
        {
            var config = await _session.UpdateServerLibraryPathAsync(ServerLibraryPath);
            ServerLibraryPath = config.LibraryPath;
            StatusMessage = "Szerver zenemappa frissítve, indexelés elindítva!";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Hiba a mappa mentésekor: {ex.Message}";
        }
        finally
        {
            IsUpdatingServerConfig = false;
        }
    }

    [RelayCommand]
    public async Task LoadUsersAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        IsLoadingUsers = true;
        ShowUserManagementError(null);
        try
        {
            var users = await _session.GetUsersAsync();
            ServerUsers = new System.Collections.ObjectModel.ObservableCollection<UserInfo>(users);
        }
        catch (Exception ex)
        {
            ShowUserManagementError($"Felhasználók betöltési hiba: {ex.Message}");
        }
        finally
        {
            IsLoadingUsers = false;
        }
    }

    [RelayCommand]
    public async Task AddUserAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        if (string.IsNullOrWhiteSpace(NewUsername) || string.IsNullOrEmpty(NewPassword))
        {
            ShowUserManagementError("Add meg a felhasználónevet és a jelszót!");
            return;
        }

        if (NewPassword.Length < AuthRules.MinPasswordLength)
        {
            ShowUserManagementError($"A jelszónak legalább {AuthRules.MinPasswordLength} karakternek kell lennie!");
            return;
        }

        if (NewPassword != ConfirmPassword)
        {
            ShowUserManagementError("A megadott jelszavak nem egyeznek!");
            return;
        }

        IsAddingUser = true;
        ShowUserManagementError(null);
        try
        {
            await _session.RegisterUserAsync(NewUsername, NewPassword);
            NewUsername = string.Empty;
            NewPassword = string.Empty;
            ConfirmPassword = string.Empty;
            await LoadUsersAsync();
        }
        catch (Exception ex)
        {
            ShowUserManagementError($"Hiba a felhasználó hozzáadásakor: {ex.Message}");
        }
        finally
        {
            IsAddingUser = false;
        }
    }

    [RelayCommand]
    public async Task DeleteUserAsync(string? userId)
    {
        if (!IsLoggedIn || !IsAdmin || string.IsNullOrEmpty(userId)) return;
        ShowUserManagementError(null);
        try
        {
            await _session.DeleteUserAsync(userId);
            await LoadUsersAsync();
        }
        catch (Exception ex)
        {
            ShowUserManagementError($"Hiba a törlésnél: {ex.Message}");
        }
    }

    private void ShowUserManagementError(string? message)
    {
        UserManagementErrorMessage = message ?? string.Empty;
        HasUserManagementError = !string.IsNullOrEmpty(message);
    }
}
