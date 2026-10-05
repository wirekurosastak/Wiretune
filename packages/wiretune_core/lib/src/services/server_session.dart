// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
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

enum LibrarySource { none, server, local, hybrid }

/// The player's connection to a Wiretune server: server address, sign-in, copying the server's track list into the
/// local [LibraryService], and keeping the signed-in account's favourites, play counts and playlists on the server.
/// Every failure becomes a [state] with a message the interface can show; the commands never throw.
class ServerSession {
  ServerSession(this._library, this._settings, [ServerStreamingClient? client])
    : _client = client ?? ServerStreamingClient() {
    _unsubscribers.addAll([
      Localizer.instance.languageChanged.listen((_) => stateChanged.emit(null)),
      _library.favoriteToggled.listen((track) => _enqueue(() => _pushFavorite(track))),
      _library.playRecorded.listen((track) => _enqueue(() => _pushPlay(track))),
      _library.playlistEdited.listen((playlist) => _enqueue(() => _pushPlaylist(playlist.id))),
      _library.playlistRemoved.listen((id) => _enqueue(() => _pushPlaylistRemoved(id))),
    ]);
  }

  static const String defaultServerUrl = 'http://localhost:5200';

  /// A stream token is replaced once it has less than this left, so one handed out just now outlasts the longest track.
  static const Duration _streamTokenRefreshMargin = Duration(hours: 4);

  final LibraryService _library;
  final LibraryRepository _settings;
  final ServerStreamingClient _client;
  final AsyncLock _gate = AsyncLock();
  final AsyncLock _streamTokenGate = AsyncLock();
  final List<void Function()> _unsubscribers = [];

  // Changes to the account's data go to the server one at a time, in the order they were made.
  final Queue<Future<void> Function()> _pushQueue = Queue();
  bool _pushLoopRunning = false;
  (String token, DateTime expiresUtc)? _streamToken;
  String? _statusKey;
  List<Object?> _statusArgs = const [];

  String serverUrl = defaultServerUrl;
  ServerConnectionState state = ServerConnectionState.notConfigured;
  LibrarySource source = LibrarySource.none;
  UserInfo? currentUser;

  /// Raised whenever state, user or status message changes.
  final Event<void> stateChanged = Event<void>();

  /// The current status text in the active language; it follows language changes.
  String? get statusMessage => _statusKey == null ? null : Localizer.format(_statusKey!, _statusArgs);

  String? get authToken => _client.authToken;

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

  Future<void> initialize() async {
    final url = await _settings.getSetting('server_url', defaultServerUrl);
    serverUrl = url != null && url.isNotEmpty ? url : defaultServerUrl;
    source = LibrarySource.values.asNameMap()[await _settings.getSetting('library_source')] ?? LibrarySource.none;

    final token = await _settings.getSetting('auth_token');
    _client.authToken = token == null || token.isEmpty ? null : token;

    final hasLocal = _library.tracks.any((t) => t.isLocal);
    final hasServerTracks = _library.tracks.any((t) => !t.isLocal);
    if (hasLocal && (hasServerTracks || source == LibrarySource.server || _client.authToken != null)) {
      await _setSource(LibrarySource.hybrid);
    }

    _setState(
      source == LibrarySource.server || source == LibrarySource.hybrid
          ? ServerConnectionState.offline
          : ServerConnectionState.notConfigured,
      null,
    );
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
          await _forgetToken(); // a token is never sent to a different server
        }
        await _settings.setSetting('server_url', serverUrl);
      }

      _setState(ServerConnectionState.connecting, 'SessionConnecting', [serverUrl]);
      WiretuneLog.info('ServerSession', "Connecting to '$serverUrl'");

      if (await _client.checkSetupRequired(serverUrl)) {
        _setState(ServerConnectionState.setupRequired, 'SessionSetupRequired');
        return;
      }
      if (_client.authToken == null || _client.authToken!.isEmpty) {
        _setState(ServerConnectionState.loginRequired, 'SessionLoginRequired', [serverUrl]);
        return;
      }

      currentUser = await _client.getCurrentUser(serverUrl);
      await _refreshLibraryCore();
    }),
  );

  /// Runs a server operation and turns every failure into a session state the interface can show. The callers are
  /// fire-and-forget commands, where an escaping exception would end up unhandled, and the state must never be left
  /// at "connecting".
  Future<void> _guarded(Future<void> Function() operation) async {
    try {
      await operation();
    } on ServerUnauthorizedException {
      await _forgetToken();
      _setState(ServerConnectionState.loginRequired, 'SessionExpired');
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
          return Localizer.format('SessionRejectedWith', [e.message]);
        }

        _streamToken = null;
        _client.authToken = auth.token;
        currentUser = auth.user;
        await _guarded(() async {
          await _settings.setSetting('auth_token', rememberMe ? auth.token : '');
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
      await _forgetToken();
      await _library.removeServerTracks();
      await _setSource(_library.tracks.any((t) => t.isLocal) ? LibrarySource.local : LibrarySource.none);
      _setState(ServerConnectionState.loginRequired, 'SessionSignedOut');
    });
  }

  /// Downloads the server's track list again.
  Future<void> refreshLibrary() => _gate.synchronized(() => _guarded(_refreshLibraryCore));

  Future<List<UserInfo>> getUsers() => _client.getUsers(serverUrl);

  Future<UserInfo> registerUser(String username, String password) =>
      _client.registerUser(serverUrl, username, password);

  Future<void> deleteUser(String userId) => _client.deleteUser(serverUrl, userId);

  Future<ServerConfigInfo> getServerConfig() => _client.getServerConfig(serverUrl);

  Future<ServerConfigInfo> updateServerLibraryPath(String newPath) =>
      _client.updateServerLibraryPath(serverUrl, newPath);

  Future<ServerLibraryStatus> getLibraryStatus() => _client.getLibraryStatus(serverUrl);

  Future<void> triggerServerScan() => _client.triggerScan(serverUrl);

  /// Marks the local folder as active, switching to hybrid when the server is also connected or has tracks.
  Future<void> useLocalLibrary() async {
    final hasServer = isLoggedIn || _library.tracks.any((t) => !t.isLocal);
    await _setSource(hasServer ? LibrarySource.hybrid : LibrarySource.local);

    if (hasServer && state == ServerConnectionState.connected) {
      _setState(ServerConnectionState.connected, 'SessionConnectedHybrid', [
        _library.tracks.length,
        currentUser?.username,
        serverUrl,
      ]);
    } else if (!hasServer) {
      _setState(ServerConnectionState.notConfigured, 'SessionLocalInUse');
    }
  }

  Future<void> _refreshLibraryCore() async {
    // What the user changed so far must reach the server before its data is downloaded, or the download undoes it.
    await flushUserData(const Duration(seconds: 10));

    _setState(ServerConnectionState.connecting, 'SessionDownloading');
    final tracks = await _client.fetchTracks(serverUrl);
    final userData = await _client.getUserData(serverUrl);
    await _library.mergeServerTracks(tracks, userData);

    final hasLocal = _library.tracks.any((t) => t.isLocal);
    await _setSource(hasLocal ? LibrarySource.hybrid : LibrarySource.server);

    WiretuneLog.info(
      'ServerSession',
      "Loaded ${tracks.length} tracks from '$serverUrl'. Total library: ${_library.tracks.length} tracks.",
    );
    _setState(ServerConnectionState.connected, hasLocal ? 'SessionConnectedHybrid' : 'SessionConnected', [
      _library.tracks.length,
      currentUser?.username,
      serverUrl,
    ]);
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

  Future<void> _forgetToken() async {
    _streamToken = null;
    _client.authToken = null;
    currentUser = null;
    await _settings.setSetting('auth_token', '');
  }

  Future<void> _setSource(LibrarySource value) async {
    source = value;
    await _settings.setSetting('library_source', value.name);
  }

  /// [messageKey] is the key of the status text; the text is rendered on demand so that it follows language changes.
  void _setState(ServerConnectionState newState, String? messageKey, [List<Object?> args = const []]) {
    state = newState;
    _statusKey = messageKey;
    _statusArgs = args;
    _library.serverConnected = isLoggedIn;
    stateChanged.emit(null);
  }

  // ── The account's favourites, play counts and playlists ──

  /// Whether changes can be sent to the server now. Deliberately independent of [state]: a change made while connected
  /// is still sent when the session briefly shows "connecting" because of a refresh.
  bool get _canPush => currentUser != null && (_client.authToken ?? '').isNotEmpty;

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
      }
    });
    return sent;
  }

  Future<void> _pushFavorite(Track track) async {
    if (!_canPush) return;
    final favorite = track.isFavorite;
    final sent = await _sendChange(() => _client.setFavorite(serverUrl, track.id, favorite));
    // The server did not take it: show the star as it really is instead of pretending.
    if (!sent) await _library.setFavorite(track.id, !favorite);
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

  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    _unsubscribers.clear();
    _client.close();
  }
}
