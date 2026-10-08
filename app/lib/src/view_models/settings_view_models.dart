// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The server connection, the account (sign-in, first-run setup), the local folder, and the administrator's tools.
class ServerSettingsViewModel extends ChangeNotifier {
  ServerSettingsViewModel(this._library, this._session, {required this.supportsLocalFolder}) {
    localLibraryPath = _library.libraryPath.trim().isNotEmpty ? _library.libraryPath : AppPaths.musicFolder();
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) => _updateStats()),
      _library.playlistsChanged.listen((_) => _updateStats()),
      _library.scanningStateChanged.listen((scanning) {
        isScanning = scanning;
        notifyListeners();
      }),
      _session.stateChanged.listen((_) => syncWithSession()),
    ]);
    syncWithSession();
    _updateStats();
  }

  final LibraryService _library;
  final ServerSession _session;
  final List<void Function()> _unsubscribers = [];

  /// Whether this device can scan a folder of its own (desktop); phones and TVs play from a server.
  final bool supportsLocalFolder;

  String serverUrl = ServerSession.defaultServerUrl;
  String localLibraryPath = '';
  bool isServerReachable = false;
  bool isConnecting = false;
  bool isScanning = false;
  double scanProgress = 0;
  String _statusMessage = Localizer.get('StatusReady');
  bool _statusIsIdle = true;
  int totalTracksCount = 0;
  int totalAlbumsCount = 0;
  int totalArtistsCount = 0;
  int totalFavoritesCount = 0;
  int totalPlaylistsCount = 0;
  String serverStatusBadge = Localizer.get('BadgeNoConnection');
  String librarySourceText = Localizer.get('SourceNoneSelected');

  String username = '';
  String password = '';
  bool stayLoggedIn = true;
  bool isLoggedIn = false;
  bool isAdmin = false;
  bool isSetupRequired = false;
  String setupCode = '';
  String currentUserName = '';
  String currentUserRole = '';
  String authErrorMessage = '';
  bool isAuthenticating = false;
  bool isServerOffline = false;

  String serverLibraryPath = '';
  bool isUpdatingServerConfig = false;
  List<UserInfo> serverUsers = const [];
  String newUsername = '';
  String newPassword = '';
  String confirmPassword = '';
  bool isAddingUser = false;
  String userManagementErrorMessage = '';

  String? _lastSyncedServerUrl;
  String? _adminDataKey;

  String get statusMessage => _statusMessage;
  set statusMessage(String value) {
    _statusMessage = value;
    _statusIsIdle = value == Localizer.get('StatusReady');
  }

  bool get hasAuthError => authErrorMessage.isNotEmpty;
  bool get hasUserManagementError => userManagementErrorMessage.isNotEmpty;
  String get passwordHint => Localizer.format('PasswordHint', [AuthRules.minPasswordLength]);
  bool get isBusy => isConnecting || isAuthenticating || (isScanning && isLoggedIn);
  bool get canRescanServer => isLoggedIn && isAdmin && !isScanning;

  /// Re-renders the texts that were computed in the previous language.
  void refreshLocalizedTexts() {
    // The idle status is the one message that would otherwise stay in the previous language until something happens.
    if (_statusIsIdle) statusMessage = Localizer.get('StatusReady');
    syncWithSession();
  }

  void syncWithSession() {
    // Only overwrite the address field when the session's address actually changed, not while the user is typing.
    if (_lastSyncedServerUrl != _session.serverUrl) {
      _lastSyncedServerUrl = _session.serverUrl;
      serverUrl = _session.serverUrl;
    }

    isServerReachable = _session.isServerReachable;
    isServerOffline = _session.state == ServerConnectionState.offline;
    isConnecting = _session.state == ServerConnectionState.connecting;
    isLoggedIn = _session.isLoggedIn;
    isSetupRequired = _session.state == ServerConnectionState.setupRequired;
    isAdmin = _session.currentUser?.isAdmin ?? false;
    currentUserName = _session.currentUser?.username ?? '';
    currentUserRole = Localizer.get(isAdmin ? 'RoleAdmin' : 'RoleUser');
    final message = _session.statusMessage;
    if (message != null && message.trim().isNotEmpty) statusMessage = message;

    serverStatusBadge = Localizer.get(switch (_session.state) {
      ServerConnectionState.connected => isLoggedIn ? 'BadgeConnected' : 'BadgeOnline',
      ServerConnectionState.connecting => 'BadgeConnecting',
      ServerConnectionState.loginRequired => 'BadgeLoginRequired',
      ServerConnectionState.setupRequired => 'BadgeSetupRequired',
      ServerConnectionState.offline => 'BadgeOffline',
      ServerConnectionState.notConfigured => 'BadgeNoConnection',
    });

    librarySourceText = switch (_session.source) {
      LibrarySource.hybrid => Localizer.format('SourceHybrid', [_session.serverUrl]),
      LibrarySource.server => Localizer.format('SourceServer', [_session.serverUrl]),
      LibrarySource.local => Localizer.format('SourceLocal', [_library.libraryPath]),
      LibrarySource.none => Localizer.get('SourceNone'),
    };

    // The administrator's data is fetched once per administrator sign-in, not on every state change.
    final adminKey = isLoggedIn && isAdmin ? '${_session.serverUrl}|$currentUserName' : null;
    if (adminKey != _adminDataKey) {
      _adminDataKey = adminKey;
      if (adminKey != null) {
        unawaited(loadServerConfig());
        unawaited(loadUsers());
      }
    }
    notifyListeners();
  }

  void _updateStats() {
    totalTracksCount = _library.tracks.length;
    totalAlbumsCount = _library.albums.length;
    totalArtistsCount = _library.artists.length;
    totalFavoritesCount = _library.favorites.length;
    totalPlaylistsCount = _library.playlists.length;
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

  Future<void> login() async {
    if (username.trim().isEmpty || password.isEmpty) {
      _showAuthError(Localizer.get('AuthEnterCredentials'));
      return;
    }

    isAuthenticating = true;
    _showAuthError(null);
    try {
      final typed = serverUrl.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();
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
      if (_session.isLoggedIn) {
        password = '';
        return;
      }

      final error = await _session.login(username, password, stayLoggedIn);
      _showAuthError(error);
      if (error == null) password = '';
    } finally {
      isAuthenticating = false;
      syncWithSession();
    }
  }

  Future<void> setupAdmin() async {
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
      final error = await _session.setupAdmin(username, password, setupCode);
      _showAuthError(error);
      if (error == null) {
        password = '';
        setupCode = '';
      }
    } finally {
      isAuthenticating = false;
      syncWithSession();
    }
  }

  Future<void> logout() async {
    await _session.logout();
    syncWithSession();
  }

  Future<void> rescanServer() async {
    if (!_session.isLoggedIn) {
      statusMessage = Localizer.get('ScanSignInFirst');
      notifyListeners();
      return;
    }

    isScanning = true;
    statusMessage = Localizer.get('ReindexStarted');
    notifyListeners();
    try {
      await _session.triggerServerScan();

      // The server scans in the background; poll its status until it settles.
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      ServerLibraryStatus status;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        status = await _session.getLibraryStatus();
        statusMessage = status.isScanning
            ? Localizer.format('ReindexProgress', [status.trackCount])
            : Localizer.get('ReindexFinished');
        notifyListeners();
      } while (status.isScanning && DateTime.now().isBefore(deadline));

      await _session.refreshLibrary();
      final error = status.lastScanError;
      statusMessage = _session.state != ServerConnectionState.connected
          ? _session.statusMessage ?? Localizer.get('LibraryRefreshFailed')
          : (error != null && error.isNotEmpty
                ? Localizer.format('ServerReported', [error])
                : Localizer.format('ServerSynced', [_library.tracks.length]));
    } on ServerRequestException catch (e) {
      statusMessage = e.statusCode == 403
          ? Localizer.get('ReindexNeedsAdmin')
          : Localizer.format('ReindexError', [e.message]);
    } on ServerUnauthorizedException catch (e) {
      statusMessage = Localizer.format('ReindexError', ['$e']);
    } finally {
      isScanning = false;
      notifyListeners();
    }
  }

  Future<void> startScanFolder() async {
    if (localLibraryPath.trim().isEmpty || !Directory(localLibraryPath).existsSync()) {
      statusMessage = Localizer.get('FolderMissing');
      notifyListeners();
      return;
    }
    if (_library.isScanning) {
      statusMessage = Localizer.get('ScanAlreadyRunning');
      notifyListeners();
      return;
    }

    scanProgress = 0;
    statusMessage = Localizer.get('ScanStarted');
    notifyListeners();
    try {
      final done = await _library.scanFolder(
        localLibraryPath,
        onProgress: (report) {
          scanProgress = report.progressPercentage;
          statusMessage =
              '[${report.scannedFiles}/${report.totalEstimatedFiles}] '
              '${report.currentArtist.isEmpty ? '' : '${report.currentArtist} - '}${report.currentFile}';
          notifyListeners();
        },
      );
      if (done) {
        await _session.useLocalLibrary();
        scanProgress = 100;
        final localCount = _library.tracks.where((t) => t.isLocal).length;
        final serverCount = _library.tracks.length - localCount;
        statusMessage = serverCount > 0
            ? Localizer.format('ScanDoneMixed', [localCount, serverCount, _library.tracks.length])
            : Localizer.format('ScanDoneLocal', [_library.tracks.length]);
      }
    } catch (e) {
      statusMessage = Localizer.format('ScanError', ['$e']);
    } finally {
      syncWithSession();
    }
  }

  Future<void> loadServerConfig() async {
    if (!isLoggedIn || !isAdmin) return;
    try {
      serverLibraryPath = (await _session.getServerConfig()).libraryPath;
    } catch (e) {
      statusMessage = Localizer.format('ServerSettingsLoadError', ['$e']);
    }
    notifyListeners();
  }

  Future<void> updateServerLibraryPath() async {
    if (!isLoggedIn || !isAdmin) return;
    if (serverLibraryPath.trim().isEmpty) {
      statusMessage = Localizer.get('EnterServerFolder');
      notifyListeners();
      return;
    }

    isUpdatingServerConfig = true;
    notifyListeners();
    try {
      serverLibraryPath = (await _session.updateServerLibraryPath(serverLibraryPath)).libraryPath;
      statusMessage = Localizer.get('ServerFolderUpdated');
    } catch (e) {
      statusMessage = Localizer.format('FolderSaveError', ['$e']);
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

  Future<void> addUser() async {
    if (!isLoggedIn || !isAdmin) return;
    if (newUsername.trim().isEmpty || newPassword.isEmpty) {
      _showUserManagementError(Localizer.get('AuthEnterCredentials'));
      return;
    }
    if (newPassword.length < AuthRules.minPasswordLength) {
      _showUserManagementError(Localizer.format('PasswordTooShort', [AuthRules.minPasswordLength]));
      return;
    }
    if (newPassword != confirmPassword) {
      _showUserManagementError(Localizer.get('PasswordsDontMatch'));
      return;
    }

    isAddingUser = true;
    _showUserManagementError(null);
    try {
      await _session.registerUser(newUsername, newPassword);
      newUsername = '';
      newPassword = '';
      confirmPassword = '';
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

  Future<String?> changePassword(String currentPassword, String newPassword, String confirmPassword) async {
    if (!isLoggedIn) return Localizer.get('NotSignedIn');
    if (currentPassword.isEmpty) return Localizer.get('EnterCurrentPassword');
    if (newPassword.isEmpty) return Localizer.get('EnterNewPassword');
    if (newPassword.length < AuthRules.minPasswordLength) {
      return Localizer.format('PasswordTooShort', [AuthRules.minPasswordLength]);
    }
    if (newPassword != confirmPassword) return Localizer.get('PasswordsDontMatch');

    try {
      await _session.changePassword(currentPassword, newPassword);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> adminResetPassword(String userId, String newPassword, String confirmPassword) async {
    if (!isLoggedIn || !isAdmin) return Localizer.get('SessionRejected');
    if (newPassword.isEmpty) return Localizer.get('EnterNewPassword');
    if (newPassword.length < AuthRules.minPasswordLength) {
      return Localizer.format('PasswordTooShort', [AuthRules.minPasswordLength]);
    }
    if (newPassword != confirmPassword) return Localizer.get('PasswordsDontMatch');

    try {
      await _session.adminResetPassword(userId, newPassword);
      return null;
    } catch (e) {
      return '$e';
    }
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
      _engine.bitperfectChanged.listen((_) => _syncWithEngine()),
      _engine.devicesChanged.listen((_) => refreshDeviceList()),
      _engine.trackChanged.listen((_) => _updateSignalPath()),
    ]);
    refreshDeviceList();
  }

  final WiretuneAudioEngine _engine;
  final List<void Function()> _unsubscribers = [];

  bool isExclusiveMode = false;
  bool isBitperfect = false;
  bool isExclusiveAvailable = false;
  bool isBitperfectAvailable = false;
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
    isBitperfectAvailable = availableDevices.any((d) => d.isBitperfectSupported && d.isExclusiveSupported);
    _syncWithEngine();
  }

  void _syncWithEngine() {
    isExclusiveMode = _engine.isExclusiveMode;
    isBitperfect = _engine.isBitperfect;
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
      final rates = device.supportedSampleRates.isNotEmpty
          ? '${AudioFormat.khz(device.supportedSampleRates.reduce((a, b) => a < b ? a : b))}–'
                '${AudioFormat.khz(device.supportedSampleRates.reduce((a, b) => a > b ? a : b))} kHz'
          : Localizer.get('Unknown');
      final modes = Localizer.get(device.isBitperfectSupported ? 'AudioModesFull' : 'AudioModesShared');
      hardwareStatusText = '${device.name} [${device.driverType}] • $rates • $modes';
    }
    notifyListeners();
  }

  Future<void> setExclusiveMode(bool value) async {
    isExclusiveMode = value;
    notifyListeners();
    await _engine.setExclusiveMode(value);
    _syncWithEngine();
  }

  Future<void> setBitperfect(bool value) async {
    isBitperfect = value;
    if (value) isExclusiveMode = true;
    notifyListeners();
    await _engine.setBitperfectMode(value);
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
