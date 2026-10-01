using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Wiretune.Core.Localization;
using Wiretune.Core.Models;
using Wiretune.Core.Services;
using Wiretune.UI.Services;

namespace Wiretune.UI.ViewModels;

public partial class ServerSettingsViewModel : ObservableObject
{
    private readonly LibraryService _library;
    private readonly ServerSession _session;

    [ObservableProperty] private string _serverUrl = ServerSession.DefaultServerUrl;
    [ObservableProperty] private string _localLibraryPath = string.Empty;
    [ObservableProperty] private bool _isServerReachable;
    [ObservableProperty] private bool _isConnecting;
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private double _scanProgress;
    [ObservableProperty] private string _statusMessage = Localizer.Get("StatusReady");
    private bool _statusIsIdle = true;
    [ObservableProperty] private int _totalTracksCount;
    [ObservableProperty] private int _totalAlbumsCount;
    [ObservableProperty] private int _totalArtistsCount;
    [ObservableProperty] private int _totalFavoritesCount;
    [ObservableProperty] private int _totalPlaylistsCount;
    [ObservableProperty] private string _serverStatusBadge = Localizer.Get("BadgeNoConnection");
    [ObservableProperty] private string _librarySourceText = Localizer.Get("SourceNoneSelected");

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
    [ObservableProperty] private bool _isUpdatingServerConfig;
    [ObservableProperty] private System.Collections.ObjectModel.ObservableCollection<UserInfo> _serverUsers = new();
    [ObservableProperty] private string _newUsername = string.Empty;
    [ObservableProperty] private string _newPassword = string.Empty;
    [ObservableProperty] private string _confirmPassword = string.Empty;
    [ObservableProperty] private bool _isAddingUser;
    [ObservableProperty] private string _userManagementErrorMessage = string.Empty;
    [ObservableProperty] private bool _hasUserManagementError;

    private string? _lastSyncedServerUrl;
    private string? _adminDataKey;

    public string PasswordHint => Localizer.Format("PasswordHint", AuthRules.MinPasswordLength);
    public bool IsBusy => IsConnecting || IsAuthenticating || (IsScanning && IsLoggedIn);
    public bool CanRescanServer => IsLoggedIn && IsAdmin && !IsScanning;

    partial void OnStatusMessageChanged(string value) => _statusIsIdle = value == Localizer.Get("StatusReady");
    partial void OnIsConnectingChanged(bool value) => OnPropertyChanged(nameof(IsBusy));
    partial void OnIsAuthenticatingChanged(bool value) => OnPropertyChanged(nameof(IsBusy));
    partial void OnIsLoggedInChanged(bool value) => OnPropertyChanged(nameof(CanRescanServer));
    partial void OnIsAdminChanged(bool value) => OnPropertyChanged(nameof(CanRescanServer));

    partial void OnIsScanningChanged(bool value)
    {
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(CanRescanServer));
    }

    public ServerSettingsViewModel(LibraryService library, ServerSession session)
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

    /// <summary>Re-renders the texts that were computed in the previous language.</summary>
    public void RefreshLocalizedTexts()
    {
        // The idle status is the one message that would otherwise stay in the previous language until something happens.
        if (_statusIsIdle) StatusMessage = Localizer.Get("StatusReady");
        SyncWithSession();
        OnPropertyChanged(nameof(PasswordHint));
    }

    public void SyncWithSession()
    {
        // Only overwrite the text box when the session's address actually changed, not while the user is typing.
        if (_lastSyncedServerUrl != _session.ServerUrl)
        {
            _lastSyncedServerUrl = _session.ServerUrl;
            ServerUrl = _session.ServerUrl;
        }

        IsServerReachable = _session.IsServerReachable;
        IsServerOffline = _session.State == ServerConnectionState.Offline;
        IsConnecting = _session.State == ServerConnectionState.Connecting;
        IsLoggedIn = _session.IsLoggedIn;
        IsSetupRequired = _session.State == ServerConnectionState.SetupRequired;
        IsAdmin = _session.CurrentUser?.IsAdmin == true;
        CurrentUserName = _session.CurrentUser?.Username ?? string.Empty;
        CurrentUserRole = Localizer.Get(IsAdmin ? "RoleAdmin" : "RoleUser");
        if (!string.IsNullOrWhiteSpace(_session.StatusMessage)) StatusMessage = _session.StatusMessage;

        ServerStatusBadge = _session.State switch
        {
            ServerConnectionState.Connected => Localizer.Get(IsLoggedIn ? "BadgeConnected" : "BadgeOnline"),
            ServerConnectionState.Connecting => Localizer.Get("BadgeConnecting"),
            ServerConnectionState.LoginRequired => Localizer.Get("BadgeLoginRequired"),
            ServerConnectionState.SetupRequired => Localizer.Get("BadgeSetupRequired"),
            ServerConnectionState.Offline => Localizer.Get("BadgeOffline"),
            _ => Localizer.Get("BadgeNoConnection")
        };

        LibrarySourceText = _session.Source switch
        {
            LibrarySource.Hybrid => Localizer.Format("SourceHybrid", _session.ServerUrl),
            LibrarySource.Server => Localizer.Format("SourceServer", _session.ServerUrl),
            LibrarySource.Local => Localizer.Format("SourceLocal", _library.LibraryPath),
            _ => Localizer.Get("SourceNone")
        };

        // The admin-only data is fetched once per admin login, not on every session state change.
        var adminKey = IsLoggedIn && IsAdmin ? $"{_session.ServerUrl}|{CurrentUserName}" : null;
        if (adminKey != _adminDataKey)
        {
            _adminDataKey = adminKey;
            if (adminKey != null)
            {
                _ = LoadServerConfigAsync();
                _ = LoadUsersAsync();
            }
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
            ShowAuthError(Localizer.Get("AuthEnterCredentials"));
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
                ShowAuthError(Localizer.Get("AuthSetupFirst"));
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
            ShowAuthError(Localizer.Get("AuthEnterAdminCredentials"));
            return;
        }

        if (Password.Length < AuthRules.MinPasswordLength)
        {
            ShowAuthError(Localizer.Format("PasswordTooShort", AuthRules.MinPasswordLength));
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
            StatusMessage = Localizer.Get("ScanSignInFirst");
            return;
        }

        IsScanning = true;
        StatusMessage = Localizer.Get("ReindexStarted");
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
                    ? Localizer.Format("ReindexProgress", status.TrackCount)
                    : Localizer.Get("ReindexFinished");
            } while (status.IsScanning && DateTime.UtcNow < deadline);

            await _session.RefreshLibraryAsync();
            StatusMessage = _session.State != ServerConnectionState.Connected
                ? _session.StatusMessage ?? Localizer.Get("LibraryRefreshFailed")
                : status.LastScanError is { Length: > 0 } err
                    ? Localizer.Format("ServerReported", err)
                    : Localizer.Format("ServerSynced", _library.Tracks.Count);
        }
        catch (ServerRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden)
        {
            StatusMessage = Localizer.Get("ReindexNeedsAdmin");
        }
        catch (Exception ex) when (ex is ServerRequestException or ServerUnauthorizedException)
        {
            StatusMessage = Localizer.Format("ReindexError", ex.Message);
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
            StatusMessage = Localizer.Get("FolderMissing");
            return;
        }

        if (_library.IsScanning)
        {
            StatusMessage = Localizer.Get("ScanAlreadyRunning");
            return;
        }

        ScanProgress = 0;
        StatusMessage = Localizer.Get("ScanStarted");
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
                    ? Localizer.Format("ScanDoneMixed", localCount, serverCount, _library.Tracks.Count)
                    : Localizer.Format("ScanDoneLocal", _library.Tracks.Count);
            }
        }
        catch (Exception ex)
        {
            StatusMessage = Localizer.Format("ScanError", ex.Message);
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
        try
        {
            var config = await _session.GetServerConfigAsync();
            ServerLibraryPath = config.LibraryPath;
        }
        catch (Exception ex)
        {
            StatusMessage = Localizer.Format("ServerSettingsLoadError", ex.Message);
        }
    }

    [RelayCommand]
    public async Task UpdateServerLibraryPathAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        if (string.IsNullOrWhiteSpace(ServerLibraryPath))
        {
            StatusMessage = Localizer.Get("EnterServerFolder");
            return;
        }

        IsUpdatingServerConfig = true;
        try
        {
            var config = await _session.UpdateServerLibraryPathAsync(ServerLibraryPath);
            ServerLibraryPath = config.LibraryPath;
            StatusMessage = Localizer.Get("ServerFolderUpdated");
        }
        catch (Exception ex)
        {
            StatusMessage = Localizer.Format("FolderSaveError", ex.Message);
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
        ShowUserManagementError(null);
        try
        {
            var users = await _session.GetUsersAsync();
            ServerUsers = new System.Collections.ObjectModel.ObservableCollection<UserInfo>(users);
        }
        catch (Exception ex)
        {
            ShowUserManagementError(Localizer.Format("UsersLoadError", ex.Message));
        }
    }

    [RelayCommand]
    public async Task AddUserAsync()
    {
        if (!IsLoggedIn || !IsAdmin) return;
        if (string.IsNullOrWhiteSpace(NewUsername) || string.IsNullOrEmpty(NewPassword))
        {
            ShowUserManagementError(Localizer.Get("AuthEnterCredentials"));
            return;
        }

        if (NewPassword.Length < AuthRules.MinPasswordLength)
        {
            ShowUserManagementError(Localizer.Format("PasswordTooShort", AuthRules.MinPasswordLength));
            return;
        }

        if (NewPassword != ConfirmPassword)
        {
            ShowUserManagementError(Localizer.Get("PasswordsDontMatch"));
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
            ShowUserManagementError(Localizer.Format("UserAddError", ex.Message));
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
            ShowUserManagementError(Localizer.Format("UserDeleteError", ex.Message));
        }
    }

    private void ShowUserManagementError(string? message)
    {
        UserManagementErrorMessage = message ?? string.Empty;
        HasUserManagementError = !string.IsNullOrEmpty(message);
    }
}


