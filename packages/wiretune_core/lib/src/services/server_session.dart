// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:collection';

import '../data/library_repository.dart';
import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../models/protocol.dart';
import '../util/async_lock.dart';
import '../util/event.dart';
import 'library_service.dart';
import 'server_client.dart';
import 'wiretune_log.dart';

enum ServerConnectionState { notConfigured, connecting, offline, setupRequired, loginRequired, connected }

/// The player's connection to a Wiretune server: server address, sign-in, copying the server's track list into the
/// local [LibraryService], and keeping the signed-in account's favourites, play counts and playlists on the server.
/// Every failure becomes a [state] with a message the interface can show; the commands never throw.
class ServerSession {
  ServerSession(this._library, this._settings, [ServerClient? client]) : _client = client ?? ServerClient() {
    _unsubscribers.addAll([
      Localizer.instance.languageChanged.listen((_) => stateChanged.emit(null)),
      _library.favoriteToggled.listen((track) => _change(() => _pushFavorite(track))),
      _library.playRecorded.listen((track) => _change(() => _pushPlay(track))),
      _library.playlistEdited.listen((playlist) => _change(() => _pushPlaylist(playlist.id))),
      _library.playlistRemoved.listen((id) => _change(() => _pushPlaylistRemoved(id))),
      _library.hiddenToggled.listen((change) => _change(() => _pushHidden(change.kind, change.id, change.hidden))),
    ]);
  }

  static const String defaultServerUrl = 'http://localhost:5200';

  /// The account the stored sign-in token belongs to.
  static const String _userIdSetting = 'auth_user_id';

  /// A stream token is replaced once it has less than this left, so one handed out just now outlasts the longest track.
  static const Duration _streamTokenRefreshMargin = Duration(hours: 4);

  /// How long an unreachable server is left before it is asked again: twice as long each time, up to [_lastRetry].
  /// Tests shorten it.
  static Duration firstRetry = const Duration(seconds: 5);
  static const Duration _lastRetry = Duration(minutes: 2);

  final LibraryService _library;
  final LibraryRepository _settings;
  final ServerClient _client;
  final AsyncLock _gate = AsyncLock();
  final AsyncLock _streamTokenGate = AsyncLock();
  final List<void Function()> _unsubscribers = [];

  // Changes to the account's data go to the server one at a time, in the order they were made.
  final Queue<Future<void> Function()> _pushQueue = Queue();
  bool _pushLoopRunning = false;

  // How many changes were made here, so that a refresh can tell one made while it downloaded.
  int _localChanges = 0;

  // The server's track list and the account's data as last downloaded, each with its version (the server's ETag), so
  // that a refresh downloads only what changed.
  List<Track> _serverTracks = const [];
  String? _serverTracksVersion;
  UserDataSnapshot? _userData;
  String? _userDataVersion;
  Timer? _retry;
  Duration _retryDelay = firstRetry;
  bool _userDataRefreshing = false;
  bool _userDataRefreshAgain = false;
  (String token, DateTime expiresUtc)? _streamToken;
  String? _statusKey;
  List<Object?> _statusArgs = const [];

  bool _disposed = false;

  String serverUrl = defaultServerUrl;
  ServerConnectionState state = ServerConnectionState.notConfigured;
  UserInfo? currentUser;

  /// Whether this device plays from a server: it keeps a sign-in for one, or still has its tracks from the last time.
  bool get usesServer => (_client.authToken ?? '').isNotEmpty || _library.rawTracks.any((t) => !t.isLocal);

  /// Whether this device has music of its own: a folder it scanned.
  bool get usesLocalFolder => _library.musicFolder.isNotEmpty || _library.rawTracks.any((t) => t.isLocal);

  /// Raised whenever state, user or status message changes.
  final Event<void> stateChanged = Event<void>();

  /// A change to the account's data that the server turned down (an account limit, a rule), with why, in the user's
  /// language; the change is undone where it can be (a favourite, a hidden item).
  final Event<String> changeRefused = Event<String>();

  /// The current status text in the active language; it follows language changes.
  String? get statusMessage => _statusKey == null ? null : Localizer.format(_statusKey!, _statusArgs);

  String? get authToken => _client.authToken;

  /// This player's remote-control device ID; the server leaves it out when it tells the account's players of a change
  /// this one made.
  set deviceId(String value) => _client.deviceId = value;

  bool get isLoggedIn => state == ServerConnectionState.connected && currentUser != null;

  bool get isServerReachable =>
      state == ServerConnectionState.setupRequired ||
      state == ServerConnectionState.loginRequired ||
      state == ServerConnectionState.connected;

  /// Lyrics of a server track; null for local tracks, when signed out, on any failure, or when there are none.
  Future<String?> getLyrics(Track track) async {
    if (track.isLocal || !isLoggedIn) return null;
    try {
      return await _client.getLyrics(serverUrl, track.id);
    } on ServerRequestException catch (e) {
      WiretuneLog.debug('ServerSession', "No lyrics for '${track.title}': $e");
    } on ServerUnauthorizedException catch (e) {
      WiretuneLog.debug('ServerSession', "No lyrics for '${track.title}': $e");
    }
    return null;
  }

  void initialize() {
    final url = _settings.getSetting('server_url', defaultServerUrl);
    serverUrl = url != null && url.isNotEmpty ? url : defaultServerUrl;

    final token = _settings.getSetting('auth_token');
    _client.authToken = token == null || token.isEmpty ? null : token;
    // Until the server confirms the account, what the device kept of it (its hidden items) applies, also offline.
    if (_client.authToken != null) _library.setCurrentUser(_settings.getSetting(_userIdSetting));
    _setState(usesServer ? ServerConnectionState.offline : ServerConnectionState.notConfigured, null);
  }

  /// The address the user typed, made into a server URL: `http://` is added when no scheme is given, the path and a
  /// trailing slash are dropped. Null for anything that is not an http(s) address of a host, or that carries
  /// "user:password@" (which would be stored and logged as part of the address).
  static String? normalizeServerUrl(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    var candidate = input.trim();
    if (!candidate.contains('://')) candidate = 'http://$candidate';

    final uri = Uri.tryParse(candidate);
    if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return null;
    }
    if (uri.userInfo.isNotEmpty) return null;

    var normalized = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Checks the server and, if already signed in, refreshes the library from it.
  Future<void> connect([String? newServerUrl]) => _gate.synchronized(
    () => _guarded(() async {
      if (newServerUrl != null) {
        final normalized = normalizeServerUrl(newServerUrl);
        if (normalized == null) {
          _setState(ServerConnectionState.offline, 'SessionInvalidUrl', [newServerUrl]);
          return;
        }
        if (normalized.toLowerCase() != serverUrl.toLowerCase()) {
          serverUrl = normalized;
          _forgetToken(); // a token is never sent to a different server
        }
        _settings.setSetting('server_url', serverUrl);
      }

      _setState(ServerConnectionState.connecting, 'SessionConnecting');
      WiretuneLog.info('ServerSession', "Connecting to '$serverUrl'");

      if (await _client.checkSetupRequired(serverUrl)) {
        _setState(ServerConnectionState.setupRequired, 'SessionSetupRequired');
        return;
      }
      if (_client.authToken == null || _client.authToken!.isEmpty) {
        _setState(ServerConnectionState.loginRequired, 'SessionLoginRequired');
        return;
      }

      final user = currentUser = await _client.getCurrentUser(serverUrl);
      _library.setCurrentUser(user.id);
      // Kept next to a kept token; one an earlier version kept gets its account here.
      if ((_settings.getSetting('auth_token') ?? '').isNotEmpty) {
        _settings.setSetting(_userIdSetting, user.id);
      }
      await _refreshLibraryCore();
    }),
  );

  /// Runs a server operation and turns every failure into a session state the interface can show. The callers are
  /// fire-and-forget commands, where an escaping exception would end up unhandled, and the state must never be left
  /// at "connecting".
  Future<void> _guarded(Future<void> Function() operation) async {
    try {
      await operation();
    } on ServerUnauthorizedException catch (e) {
      if (e.token != null && e.token != _client.authToken) {
        // Refused for a token that has been replaced meanwhile (a password change): the session itself still stands.
        WiretuneLog.info('ServerSession', 'A request with a replaced sign-in token was refused.');
        return;
      }
      _forgetToken();
      _setState(ServerConnectionState.loginRequired, switch (e.code) {
        ErrorCodes.passwordChanged => 'ErrorPasswordChanged',
        ErrorCodes.accountRemoved => 'ErrorAccountRemoved',
        _ => 'SessionExpired',
      });
    } on ServerRequestException catch (e) {
      WiretuneLog.warn('ServerSession', "Server '$serverUrl' unavailable: ${e.message}");
      _setState(ServerConnectionState.offline, 'SessionUnreachable', [serverUrl, e.message]);
    } catch (e, s) {
      WiretuneLog.error('ServerSession', "Unexpected failure talking to '$serverUrl'", e, s);
      _setState(ServerConnectionState.offline, 'SessionUnexpected', ['$e']);
    }
  }

  /// Returns null on success, otherwise a user-facing error message.
  Future<String?> login(String username, String password, bool rememberMe) => _authenticate(
    () => _client.login(serverUrl, username.trim(), password, rememberMe),
    rememberMe,
    'SessionBadCredentials',
  );

  /// Creates the first (administrator) account. Returns null on success, otherwise a user-facing error message.
  Future<String?> setupAdmin(String username, String password, [String? setupCode]) =>
      _authenticate(() => _client.setupAdmin(serverUrl, username.trim(), password, setupCode), true, 'SessionRejected');

  Future<String?> _authenticate(Future<AuthResponse> Function() call, bool rememberMe, String unauthorizedKey) =>
      _gate.synchronized(() async {
        AuthResponse auth;
        try {
          auth = await call();
        } on ServerUnauthorizedException {
          return Localizer.get(unauthorizedKey);
        } on ServerRequestException catch (e) {
          if (e.statusCode == 409) {
            // Another player finished the first-run setup in the meantime.
            _setState(ServerConnectionState.loginRequired, 'SessionAlreadySetUp');
            return statusMessage;
          }
          if (e.statusCode == null) {
            _setState(ServerConnectionState.offline, 'SessionUnreachable', [serverUrl, e.message]);
            return e.message;
          }
          // A code the player knows is a whole sentence in the user's language already.
          return e.code != null && e.message != e.code
              ? e.message
              : Localizer.format('SessionRejectedWith', [e.message]);
        }

        _streamToken = null;
        _client.authToken = auth.token;
        currentUser = auth.user;
        _library.setCurrentUser(auth.user.id);
        await _guarded(() async {
          _settings.setSetting('auth_token', rememberMe ? auth.token : '');
          _settings.setSetting(_userIdSetting, rememberMe ? auth.user.id : '');
          await _refreshLibraryCore();
        });

        // The credentials were accepted; if the library download then failed, the state says why.
        return state == ServerConnectionState.connected ? null : statusMessage;
      });

  Future<void> logout() async {
    // Changes the user just made still have to reach the server while the token is valid, but a server that does not
    // answer must not keep the user from signing out.
    await flushUserData(const Duration(seconds: 10));

    await _gate.synchronized(() async {
      // The account's tracks, playlists and hidden items go while the library still knows whose they are.
      _library.removeServerTracks();
      _serverTracks = const [];
      _forgetToken();
      _setState(ServerConnectionState.loginRequired, 'SessionSignedOut');
    });
  }

  /// Downloads what changed on the server since the last download: the track list (a scan found new music), the
  /// account's data, or both. Quietly: the session stays connected meanwhile.
  Future<void> refreshLibrary() => _gate.synchronized(
    () => _guarded(() async {
      if (isLoggedIn) await _downloadLibrary(always: false);
    }),
  );

  /// The player came back to the front: a server that was out of reach is asked again at once, and a connected one
  /// whether its library changed meanwhile.
  Future<void> resume() async {
    if (state == ServerConnectionState.offline) {
      _retry?.cancel();
      _retry = null;
      _retryDelay = firstRetry;
      await _retryConnect();
    } else {
      await refreshLibrary();
    }
  }

  /// Downloads the account's favourites, play counts, playlists and hidden items again, when another of its players
  /// changed them, and applies them to the track list as it was last downloaded (which isn't downloaded again). A
  /// change made here meanwhile wins: the downloaded data is then dropped, and the server's word on that change brings
  /// the next refresh.
  Future<void> refreshUserData() async {
    if (_userDataRefreshing) {
      _userDataRefreshAgain = true;
      return;
    }
    _userDataRefreshing = true;
    try {
      do {
        _userDataRefreshAgain = false;
        await _gate.synchronized(() => _guarded(_refreshUserDataCore));
      } while (_userDataRefreshAgain);
    } finally {
      _userDataRefreshing = false;
    }
  }

  Future<void> _refreshUserDataCore() async {
    if (isLoggedIn && await _fetchUserData() && isLoggedIn) _library.mergeServerTracks(_serverTracks, _userData!);
  }

  /// Downloads the account's data if it changed, once the changes made here have reached the server; true when it
  /// did. A change made while it downloads would be undone by it, so then it is asked again (a few times at most).
  Future<bool> _fetchUserData() async {
    var changed = false;
    for (var attempt = 1; attempt <= 3; attempt++) {
      // What the user changed so far must reach the server before its data is downloaded, or the download undoes it.
      await flushUserData(const Duration(seconds: 10));
      final changes = _localChanges;
      final answer = await _client.getUserData(serverUrl, _userDataVersion);
      if (answer != null) {
        _userData = answer.data;
        _userDataVersion = answer.version;
        changed = true;
      }
      if (changes == _localChanges) break;
    }
    return changed;
  }

  Future<List<UserInfo>> getUsers() => _client.getUsers(serverUrl);

  Future<UserInfo> registerUser(String username, String password) =>
      _client.registerUser(serverUrl, username, password);

  Future<void> deleteUser(String userId) => _client.deleteUser(serverUrl, userId);

  /// Changes the account's password. The server signs out every other session of the account and hands this one a new
  /// token, which replaces the stored one. Throws [ServerRequestException] or [ServerUnauthorizedException] when the
  /// password could not be changed.
  Future<void> changePassword(String currentPassword, String newPassword) async {
    // What is on its way to the server goes with the old token, before it stops working.
    await flushUserData(const Duration(seconds: 10));
    await _gate.synchronized(() async {
      final renewed = await _client.changePassword(serverUrl, currentPassword, newPassword);
      _client.authToken = renewed.token;
      _streamToken = null;
      // Kept only when the old one was ("stay signed in").
      if ((_settings.getSetting('auth_token') ?? '').isNotEmpty) {
        _settings.setSetting('auth_token', renewed.token);
      }
      stateChanged.emit(null);
    });
  }

  Future<void> adminResetPassword(String userId, String newPassword) =>
      _client.adminResetPassword(serverUrl, userId, newPassword);

  Future<ServerConfigInfo> getServerConfig() => _client.getServerConfig(serverUrl);

  Future<ServerConfigInfo> saveServerFolder(String folder) => _client.saveServerFolder(serverUrl, folder);

  Future<ServerLibraryStatus> getLibraryStatus() => _client.getLibraryStatus(serverUrl);

  Future<void> triggerServerScan() => _client.triggerScan(serverUrl);

  /// The local folder was scanned: without a server, the session says that the local library is in use.
  void useLocalLibrary() {
    if (!usesServer) {
      _setState(ServerConnectionState.notConfigured, 'SessionLocalInUse');
    } else if (state == ServerConnectionState.connected) {
      _setState(ServerConnectionState.connected, null);
    }
  }

  Future<void> _refreshLibraryCore() async {
    _setState(ServerConnectionState.connecting, 'SessionDownloading');
    await _downloadLibrary(always: true);
    _setState(ServerConnectionState.connected, null);
  }

  /// Downloads the track list and the account's data, each unless it is still the one downloaded last, and puts them in
  /// the library. Unless [always], nothing changes when neither did.
  Future<void> _downloadLibrary({required bool always}) async {
    final list = await _client.fetchTracks(serverUrl, _serverTracksVersion);
    if (list != null) {
      _serverTracks = list.tracks;
      _serverTracksVersion = list.version;
    }
    if (!await _fetchUserData() && list == null && !always) return;
    _library.mergeServerTracks(_serverTracks, _userData!);
    WiretuneLog.info(
      'ServerSession',
      "Loaded ${_serverTracks.length} tracks from '$serverUrl'. Total library: ${_library.tracks.length} tracks.",
    );
  }

  /// The token for stream URLs: a short-lived one that opens only the audio and cover routes, so that the URL (which
  /// ends up in decoder logs) never carries the sign-in token. Null when signed out or when no token could be had.
  Future<String?> getStreamToken() async {
    if ((_client.authToken ?? '').isEmpty) return null;
    if (_isFresh(_streamToken)) return _streamToken!.$1;

    return _streamTokenGate.synchronized(() async {
      if (_isFresh(_streamToken)) return _streamToken!.$1;
      try {
        final issued = await _client.getStreamToken(serverUrl);
        _streamToken = (issued.token, issued.expiresAt.toUtc());
      } on ServerRequestException catch (e) {
        // The token we hold (if any) may still be valid for a while; otherwise playback fails with the server's answer.
        WiretuneLog.warn('ServerSession', 'Could not get a stream token: $e');
      } on ServerUnauthorizedException catch (e) {
        WiretuneLog.warn('ServerSession', 'Could not get a stream token: $e');
      }
      final held = _streamToken;
      return held != null && held.$2.isAfter(DateTime.now().toUtc()) ? held.$1 : null;
    });
  }

  static bool _isFresh((String, DateTime)? token) =>
      token != null && token.$2.difference(DateTime.now().toUtc()) > _streamTokenRefreshMargin;

  void _forgetToken() {
    _streamToken = null;
    _serverTracksVersion = null;
    _userData = null;
    _userDataVersion = null;
    _client.authToken = null;
    currentUser = null;
    _library.setCurrentUser(null);
    _settings.setSetting('auth_token', '');
    _settings.setSetting(_userIdSetting, '');
  }

  /// [messageKey] is the key of the status text; the text is rendered on demand so that it follows language changes.
  void _setState(ServerConnectionState newState, String? messageKey, [List<Object?> args = const []]) {
    state = newState;
    _statusKey = messageKey;
    _statusArgs = args;
    _library.serverConnected = isLoggedIn;
    if (newState == ServerConnectionState.offline) {
      _retryLater();
    } else if (newState != ServerConnectionState.connecting) {
      _retry?.cancel();
      _retry = null;
      _retryDelay = firstRetry;
    }
    stateChanged.emit(null);
  }

  // ── Coming back by itself ──

  /// While the server is out of reach, it is asked now and then whether it is back, quietly: the session shows
  /// "offline" until it answers, and then connects.
  void _retryLater() {
    if (_retry != null || _disposed) return;
    _retry = Timer(_retryDelay, () {
      _retry = null;
      final doubled = _retryDelay * 2;
      _retryDelay = doubled > _lastRetry ? _lastRetry : doubled;
      unawaited(_retryConnect());
    });
  }

  Future<void> _retryConnect() async {
    if (state != ServerConnectionState.offline || !usesServer) return;
    try {
      await _client.checkSetupRequired(serverUrl);
    } on Exception {
      if (state == ServerConnectionState.offline) _retryLater();
      return;
    }
    if (state == ServerConnectionState.offline) await connect();
  }

  // ── The account's favourites, play counts and playlists ──

  /// Whether changes can be sent to the server now. Deliberately independent of [state]: a change made while connected
  /// is still sent when the session briefly shows "connecting" because of a refresh.
  bool get _canPush => currentUser != null && (_client.authToken ?? '').isNotEmpty;

  /// A change of the account's data made here, for the server. What the library shows is no longer the data downloaded
  /// last, so the next download can't be skipped as "not modified": that data may be what the server holds again.
  void _change(Future<void> Function() job) {
    _localChanges++;
    _userDataVersion = null;
    _enqueue(job);
  }

  void _enqueue(Future<void> Function() job) {
    _pushQueue.add(job);
    if (!_pushLoopRunning) unawaited(_pushLoop());
  }

  Future<void> _pushLoop() async {
    _pushLoopRunning = true;
    try {
      while (_pushQueue.isNotEmpty) {
        final job = _pushQueue.removeFirst();
        try {
          await job();
        } catch (e, s) {
          WiretuneLog.error('ServerSession', 'Sending a change to the server failed: $e', e, s);
        }
      }
    } finally {
      _pushLoopRunning = false;
    }
  }

  /// Completes when every change made so far has been sent (or failed), or after [timeout].
  Future<void> flushUserData([Duration timeout = const Duration(seconds: 30)]) async {
    final done = Completer<void>();
    _enqueue(() async => done.complete());
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      WiretuneLog.warn('ServerSession', 'Gave up waiting for pending changes to reach the server.');
    }
  }

  /// The server answered, and said no: an invalid value, an account limit or a body that is too big.
  static bool _isRefusal(ServerRequestException e) => e.statusCode == 400 || e.statusCode == 409 || e.statusCode == 413;

  /// Sends one change. A server that refuses it can be reached, so the session keeps its state (the change is not
  /// kept); any other failure is handled like every server call. False says it was not sent.
  Future<bool> _sendChange(Future<void> Function() send) async {
    var sent = false;
    await _guarded(() async {
      try {
        await send();
        sent = true;
      } on ServerRequestException catch (e) {
        if (!_isRefusal(e)) rethrow;
        WiretuneLog.warn('ServerSession', 'The server did not accept a change: ${e.message}');
        changeRefused.emit(e.message);
      }
    });
    return sent;
  }

  Future<void> _pushFavorite(Track track) async {
    if (!_canPush) return;
    final favorite = _library.isFavorite(track.id);
    final sent = await _sendChange(() => _client.setFavorite(serverUrl, track.id, favorite));
    // The server did not take it: show the star as it really is instead of pretending.
    if (!sent) _library.setFavorite(track.id, !favorite);
  }

  Future<void> _pushPlay(Track track) async {
    if (!_canPush) return;
    await _sendChange(() => _client.recordPlay(serverUrl, track.id));
  }

  Future<void> _pushPlaylist(String playlistId) async {
    if (!_canPush) return;
    // Read when it is this change's turn, so a burst of edits ends with the latest state on the server.
    final playlist = _library.getPlaylist(playlistId);
    if (playlist == null || !playlist.isServer) return;
    await _sendChange(() => _client.savePlaylist(serverUrl, playlist));
  }

  Future<void> _pushPlaylistRemoved(String playlistId) async {
    if (!_canPush) return;
    await _sendChange(() => _client.deletePlaylist(serverUrl, playlistId));
  }

  Future<void> _pushHidden(HiddenKind kind, String id, bool hidden) async {
    if (!_canPush) return;
    final sent = await _sendChange(() => _client.setHidden(serverUrl, kind, id, hidden));
    if (!sent) _library.setHiddenLocal(kind, id, !hidden);
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    _unsubscribers.clear();
    _client.close();
  }
}
