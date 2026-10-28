// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The server connection, the account (sign-in, first-run setup), the local folder, and the administrator's tools.
class ServerSettingsViewModel extends ChangeNotifier {
  ServerSettingsViewModel(
    this._library,
    this._session, {
    required this.supportsLocalFolder,
    Future<bool> Function()? requestFolderAccess,
  }) : _requestFolderAccess = requestFolderAccess {
    localFolder = _library.musicFolder.trim().isNotEmpty ? _library.musicFolder : AppPaths.defaultMusicFolder();
    _unsubscribers.addAll([
      _library.scanningStateChanged.listen((scanning) {
        isScanning = scanning;
        notifyListeners();
      }),
      _session.stateChanged.listen((_) => syncWithSession()),
    ]);
    syncWithSession();
  }

  final LibraryService _library;
  final ServerSession _session;
  final List<void Function()> _unsubscribers = [];

  /// Whether this device can scan a folder of its own (desktop, Android phones); TVs and iPhones play from a server.
  final bool supportsLocalFolder;

  /// Asks for the permission to read the folder before a scan (Android); null when nothing needs asking.
  final Future<bool> Function()? _requestFolderAccess;

  /// The address field: the session's address, unless the user is typing another.
  String serverUrl = ServerSession.defaultServerUrl;
  String localFolder = '';

  /// This device's folder is being scanned (the server's: [isReindexing]).
  bool isScanning = false;
  double scanProgress = 0;

  bool stayLoggedIn = true;
  String authErrorMessage = '';
  bool isAuthenticating = false;

  String serverFolder = '';
  bool isUpdatingServerConfig = false;

  /// The server is scanning its folder again (Reindex), followed until it settles.
  bool isReindexing = false;

  /// The outcome of saving the server's music folder or reindexing it, shown beside that field.
  String serverFolderMessage = '';
  bool serverFolderIsError = false;

  /// What is wrong with the server's music folder right now (missing, empty, the last scan failed), for an
  /// administrator; empty while all is well.
  String serverFolderProblem = '';

  /// The progress and outcome of scanning the local folder, shown beside that field.
  String localFolderMessage = '';
  bool localFolderIsError = false;
  List<UserInfo> serverUsers = const [];
  bool isAddingUser = false;
  String userManagementErrorMessage = '';

  String? _lastSyncedServerUrl;
  String? _adminDataKey;

  bool get isServerReachable => _session.isServerReachable;

  /// The server can't be reached; not in offline mode, which leaves it alone on purpose.
  bool get isServerOffline => _session.state == ServerConnectionState.offline && !isOfflineMode;
  bool get isOfflineMode => _session.isOfflineMode;

  /// Offline mode is offered to a device that plays from a server.
  bool get offersOfflineMode => _session.usesServer || isOfflineMode;
  bool get isConnecting => _session.state == ServerConnectionState.connecting;
  bool get isSetupRequired => _session.state == ServerConnectionState.setupRequired;
  bool get isLoggedIn => _session.isLoggedIn;
  bool get isAdmin => _session.currentUser?.isAdmin ?? false;
  String get currentUserName => _session.currentUser?.username ?? '';
  String get currentUserRole => Localizer.get(isAdmin ? 'RoleAdmin' : 'RoleUser');

  /// What the session is doing, in a sentence; empty while there is nothing to tell (its badge says how it stands).
  String get statusMessage => _session.statusMessage ?? '';

  String get serverStatusBadge => Localizer.get(switch (_session.state) {
    ServerConnectionState.connected => isLoggedIn ? 'BadgeConnected' : 'BadgeOnline',
    ServerConnectionState.connecting => 'BadgeConnecting',
    ServerConnectionState.loginRequired => 'BadgeLoginRequired',
    ServerConnectionState.setupRequired => 'BadgeSetupRequired',
    ServerConnectionState.offline => isOfflineMode ? 'BadgeOfflineMode' : 'BadgeOffline',
    ServerConnectionState.notConfigured => 'BadgeNoConnection',
  });

  bool get hasAuthError => authErrorMessage.isNotEmpty;
  bool get hasUserManagementError => userManagementErrorMessage.isNotEmpty;
  String get passwordHint => Localizer.format('PasswordHint', [AuthRules.minPasswordLength]);
  bool get isBusy => isConnecting || isAuthenticating || ((isScanning || isReindexing) && isLoggedIn);
  bool get canReindexServer => isLoggedIn && isAdmin && !isReindexing;

  /// Whether connecting to [address] means leaving the server this device is signed in to.
  bool wouldSwitchServer(String address) {
    if (!_session.isLoggedIn) return false;
    final target = ServerSession.normalizeServerUrl(address);
    return target != null && target.toLowerCase() != _session.serverUrl.toLowerCase();
  }

  /// The server this device is connected to.
  String get connectedServerUrl => _session.serverUrl;

  /// The texts follow the language by themselves; the view only has to draw again.
  void refreshLocalizedTexts() => notifyListeners();

  void syncWithSession() {
    // Only overwrite the address field when the session's address actually changed, not while the user is typing.
    if (_lastSyncedServerUrl != _session.serverUrl) {
      _lastSyncedServerUrl = _session.serverUrl;
      serverUrl = _session.serverUrl;
    }

    // The administrator's data is fetched once per administrator sign-in, not on every state change.
    final adminKey = isLoggedIn && isAdmin ? '${_session.serverUrl}|$currentUserName' : null;
    if (adminKey != _adminDataKey) {
      _adminDataKey = adminKey;
      if (adminKey != null) {
        unawaited(loadServerFolder());
        unawaited(loadUsers());
      }
    }
    notifyListeners();
  }

  void _showAuthError(String? message) {
    authErrorMessage = message ?? '';
    notifyListeners();
  }

  Future<void> connectServer() async {
    _showAuthError(null);
    await _session.connect(serverUrl);
    syncWithSession();
  }

  Future<void> setOfflineMode(bool enabled) async {
    await _session.setOfflineMode(enabled);
    syncWithSession();
  }

  /// Signs in to the server at [serverUrl] (connecting to it first when needed); what went wrong is [authErrorMessage].
  Future<void> login(String username, String password) async {
    if (username.trim().isEmpty || password.isEmpty) {
      _showAuthError(Localizer.get('AuthEnterCredentials'));
      return;
    }

    isAuthenticating = true;
    _showAuthError(null);
    try {
      final typed = ServerSession.normalizeServerUrl(serverUrl)?.toLowerCase();
      if (!_session.isServerReachable ||
          _session.state == ServerConnectionState.setupRequired ||
          typed != _session.serverUrl.toLowerCase()) {
        await _session.connect(serverUrl);
      }

      if (_session.state == ServerConnectionState.offline) {
        _showAuthError(_session.statusMessage);
        return;
      }
      if (_session.state == ServerConnectionState.setupRequired) {
        _showAuthError(Localizer.get('AuthSetupFirst'));
        return;
      }
      if (_session.isLoggedIn) return;

      _showAuthError(await _session.login(username, password, stayLoggedIn));
    } finally {
      isAuthenticating = false;
      syncWithSession();
    }
  }

  /// Creates the server's first account, its administrator; what went wrong is [authErrorMessage].
  Future<void> setupAdmin(String username, String password, String setupCode) async {
    if (username.trim().isEmpty || password.isEmpty) {
      _showAuthError(Localizer.get('AuthEnterAdminCredentials'));
      return;
    }
    if (password.length < AuthRules.minPasswordLength) {
      _showAuthError(Localizer.format('PasswordTooShort', [AuthRules.minPasswordLength]));
      return;
    }

    isAuthenticating = true;
    _showAuthError(null);
    try {
      _showAuthError(await _session.setupAdmin(username, password, setupCode));
    } finally {
      isAuthenticating = false;
      syncWithSession();
    }
  }

  Future<void> logout() async {
    await _session.logout();
    syncWithSession();
  }

  void _showServerFolder(String message, {bool isError = false}) {
    serverFolderMessage = message;
    serverFolderIsError = isError;
    notifyListeners();
  }

  /// What the last scan's problem means for the administrator: the folder can't be reached (the library is kept), it
  /// looks unmounted, or the scan failed. Empty when there is none.
  String _scanProblemText(ServerLibraryStatus status) => switch (status.lastScanProblem) {
    ErrorCodes.folderMissing => Localizer.format('ServerFolderUnavailable', [serverFolder]),
    null => '',
    final code => describeServerError(code) ?? status.lastScanError ?? '',
  };

  Future<void> _loadServerFolderProblem() async {
    try {
      serverFolderProblem = _scanProblemText(await _session.getLibraryStatus());
    } on ServerRequestException catch (e) {
      WiretuneLog.warn('Settings', "Could not read the server's library status: ${e.message}");
    }
    notifyListeners();
  }

  Future<void> reindexServer() async {
    if (!_session.isLoggedIn) {
      _showServerFolder(Localizer.get('ScanSignInFirst'), isError: true);
      return;
    }

    isReindexing = true;
    _showServerFolder(Localizer.get('ReindexStarted'));
    try {
      await _session.triggerServerScan();

      // The server scans in the background; poll its status until it settles.
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      ServerLibraryStatus status;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        status = await _session.getLibraryStatus();
        _showServerFolder(
          status.isScanning
              ? Localizer.format('ReindexProgress', [status.trackCount])
              : Localizer.get('ReindexFinished'),
        );
      } while (status.isScanning && DateTime.now().isBefore(deadline));

      await _session.refreshLibrary();
      serverFolderProblem = _scanProblemText(status);
      if (_session.state != ServerConnectionState.connected) {
        _showServerFolder(_session.statusMessage ?? Localizer.get('LibraryRefreshFailed'), isError: true);
      } else {
        // A problem shows on its own line; this one says what the library now holds.
        _showServerFolder(Localizer.format('ServerSynced', [_library.tracks.length]));
      }
    } on ServerRequestException catch (e) {
      _showServerFolder(Localizer.format('ReindexError', [e.message]), isError: true);
    } finally {
      isReindexing = false;
      notifyListeners();
    }
  }

  void _showLocalFolder(String message, {bool isError = false}) {
    localFolderMessage = message;
    localFolderIsError = isError;
    notifyListeners();
  }

  Future<void> scanLocalFolder() async {
    // Asked here, when the user wants their music read, rather than at start.
    final request = _requestFolderAccess;
    if (request != null && !await request()) {
      _showLocalFolder(Localizer.get('FolderAccessDenied'), isError: true);
      return;
    }
    if (localFolder.trim().isEmpty || !Directory(localFolder).existsSync()) {
      _showLocalFolder(Localizer.get('FolderMissing'), isError: true);
      return;
    }
    if (_library.isScanning) {
      _showLocalFolder(Localizer.get('ScanAlreadyRunning'), isError: true);
      return;
    }

    scanProgress = 0;
    _showLocalFolder(Localizer.get('ScanStarted'));
    try {
      final done = await _library.scanFolder(
        localFolder,
        onProgress: (report) {
          scanProgress = report.progressPercentage;
          _showLocalFolder(
            '[${report.scannedFiles}/${report.totalEstimatedFiles}] '
            '${report.currentArtist.isEmpty ? '' : '${report.currentArtist} - '}${report.currentFile}',
          );
        },
      );
      if (done) {
        _session.useLocalLibrary();
        scanProgress = 100;
        final localCount = _library.tracks.where((t) => t.isLocal).length;
        final serverCount = _library.tracks.length - localCount;
        _showLocalFolder(
          serverCount > 0
              ? Localizer.format('ScanDoneMixed', [localCount, serverCount, _library.tracks.length])
              : Localizer.format('ScanDoneLocal', [_library.tracks.length]),
        );
      }
    } catch (e) {
      WiretuneLog.error('Settings', 'Scanning the local folder failed', e);
      _showLocalFolder(Localizer.format('ScanError', ['$e']), isError: true);
    } finally {
      syncWithSession();
    }
  }

  /// The server's music folder, and what is wrong with it if anything (administrators only).
  Future<void> loadServerFolder() async {
    if (!isLoggedIn || !isAdmin) return;
    try {
      serverFolder = (await _session.getServerConfig()).musicFolder;
      savedServerFolder = serverFolder;
    } on ServerRequestException catch (e) {
      _showServerFolder(Localizer.format('ServerSettingsLoadError', [e.message]), isError: true);
    }
    await _loadServerFolderProblem();
  }

  /// The server's music folder as the server has it (what [serverFolder] was before the administrator typed).
  String savedServerFolder = '';

  /// Whether saving the folder field would change the server's music folder.
  bool get serverFolderChanged => serverFolder.trim() != savedServerFolder;

  Future<void> saveServerFolder() async {
    if (!isLoggedIn || !isAdmin) return;
    if (serverFolder.trim().isEmpty) {
      _showServerFolder(Localizer.get('EnterServerFolder'), isError: true);
      return;
    }

    isUpdatingServerConfig = true;
    notifyListeners();
    try {
      serverFolder = savedServerFolder = (await _session.saveServerFolder(serverFolder)).musicFolder;
      serverFolderProblem = '';
      _showServerFolder(Localizer.get('ServerFolderUpdated'));
    } on ServerRequestException catch (e) {
      // The server's reason is a whole sentence in the user's language when it is one the player knows.
      _showServerFolder(e.code != null ? e.message : Localizer.format('FolderSaveError', [e.message]), isError: true);
    } finally {
      isUpdatingServerConfig = false;
      notifyListeners();
    }
  }

  Future<void> loadUsers() async {
    if (!isLoggedIn || !isAdmin) return;
    _showUserManagementError(null);
    try {
      serverUsers = await _session.getUsers();
    } catch (e) {
      _showUserManagementError(Localizer.format('UsersLoadError', ['$e']));
    }
    notifyListeners();
  }

  /// Adds an account to the server (for its administrator); what went wrong is [userManagementErrorMessage].
  Future<void> addUser(String username, String password, String confirmPassword) async {
    if (!isLoggedIn || !isAdmin) return;
    final problem = username.trim().isEmpty || password.isEmpty
        ? Localizer.get('AuthEnterCredentials')
        : _newPasswordProblem(password, confirmPassword);
    if (problem != null) {
      _showUserManagementError(problem);
      return;
    }

    isAddingUser = true;
    _showUserManagementError(null);
    try {
      await _session.addUser(username, password);
      await loadUsers();
    } catch (e) {
      _showUserManagementError(Localizer.format('UserAddError', ['$e']));
    } finally {
      isAddingUser = false;
      notifyListeners();
    }
  }

  Future<void> deleteUser(String? userId) async {
    if (!isLoggedIn || !isAdmin || userId == null || userId.isEmpty) return;
    _showUserManagementError(null);
    try {
      await _session.deleteUser(userId);
      await loadUsers();
    } catch (e) {
      _showUserManagementError(Localizer.format('UserDeleteError', ['$e']));
    }
  }

  Future<String?> changePassword(String newPassword, String confirmPassword) async {
    if (!isLoggedIn) return Localizer.get('NotSignedIn');
    if (_newPasswordProblem(newPassword, confirmPassword) case final problem?) return problem;
    try {
      await _session.changePassword(newPassword);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> adminResetPassword(String userId, String newPassword, String confirmPassword) async {
    if (!isLoggedIn || !isAdmin) return Localizer.get('SessionRejected');
    if (_newPasswordProblem(newPassword, confirmPassword) case final problem?) return problem;
    try {
      await _session.adminResetPassword(userId, newPassword);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// What is wrong with [password] as a new one, typed again as [confirm]; null when nothing is.
  static String? _newPasswordProblem(String password, String confirm) {
    if (password.isEmpty) return Localizer.get('EnterNewPassword');
    if (password.length < AuthRules.minPasswordLength) {
      return Localizer.format('PasswordTooShort', [AuthRules.minPasswordLength]);
    }
    return password == confirm ? null : Localizer.get('PasswordsDontMatch');
  }

  void _showUserManagementError(String? message) {
    userManagementErrorMessage = message ?? '';
    notifyListeners();
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}

/// The output device and the exclusive and bit-perfect switches.
class AudioSettingsViewModel extends ChangeNotifier {
  AudioSettingsViewModel(this._engine) {
    _unsubscribers.addAll([
      _engine.exclusiveModeChanged.listen((_) => _syncWithEngine()),
      _engine.bitPerfectChanged.listen((_) => _syncWithEngine()),
      _engine.devicesChanged.listen((_) => refreshDeviceList()),
      _engine.trackChanged.listen((_) => _updateSignalPath()),
    ]);
    refreshDeviceList();
  }

  final WiretuneAudioEngine _engine;
  final List<void Function()> _unsubscribers = [];

  // The engine's own: it tells of a change at once, before the slow restart of the output.
  bool get isExclusiveMode => _engine.isExclusiveMode;
  bool get isBitPerfect => _engine.isBitPerfect;
  bool isExclusiveAvailable = false;
  bool isBitPerfectAvailable = false;
  AudioOutputDevice? selectedDevice;
  String signalPath = '';
  String hardwareStatusText = '';
  List<AudioOutputDevice> availableDevices = const [];

  /// Whether there is anything to choose: phones, TVs and the system default alone offer no choice.
  bool get hasDeviceChoice => availableDevices.length > 1 || isExclusiveAvailable;

  void refreshDeviceList() {
    availableDevices = List.of(_engine.availableDevices);
    selectedDevice = availableDevices.where((d) => d.id == _engine.currentDevice?.id).firstOrNull;
    isExclusiveAvailable = availableDevices.any((d) => d.isExclusiveSupported);
    isBitPerfectAvailable = availableDevices.any((d) => d.isBitPerfectSupported && d.isExclusiveSupported);
    _syncWithEngine();
  }

  void _syncWithEngine() {
    selectedDevice = availableDevices.where((d) => d.id == _engine.currentDevice?.id).firstOrNull ?? selectedDevice;
    _updateSignalPath();
  }

  /// Re-renders the texts that were computed in the previous language.
  void refreshLocalizedTexts() => refreshDeviceList(); // the "default output" names are translated

  void _updateSignalPath() {
    signalPath = _engine.signalPathDescription;
    final device = _engine.currentDevice;
    if (device == null) {
      hardwareStatusText = Localizer.get('AudioNoOutput');
    } else {
      final modes = Localizer.get(device.isBitPerfectSupported ? 'AudioModesFull' : 'AudioModesShared');
      hardwareStatusText = '${device.name} [${device.driverType}] • $modes';
    }
    notifyListeners();
  }

  Future<void> setExclusiveMode(bool value) async {
    await _engine.setExclusiveMode(value);
    _syncWithEngine();
  }

  Future<void> setBitPerfect(bool value) async {
    await _engine.setBitPerfectMode(value);
    _syncWithEngine();
  }

  Future<void> selectDevice(AudioOutputDevice? device) async {
    if (device == null || device.id == _engine.currentDevice?.id) return;
    selectedDevice = device;
    notifyListeners();
    await _engine.setOutputDevice(device);
    _syncWithEngine();
  }

  Future<void> refreshDevices() async {
    await _engine.refreshDevices();
    refreshDeviceList();
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}
