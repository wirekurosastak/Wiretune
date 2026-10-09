// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:wiretune_core/wiretune_core.dart';

import 'auth_service.dart';
import 'config.dart';
import 'http_utils.dart';
import 'library_scan_service.dart';
import 'remote_hub.dart';
import 'setup_code.dart';
import 'user_data_service.dart';

/// Who may call a route.
enum Access {
  /// Anyone.
  anonymous,

  /// Any signed-in account (never a stream token).
  user,

  /// An administrator.
  admin,

  /// Any signed-in account, also with a stream token, also as `?token=` (audio and covers).
  media,
}

typedef _Handler = FutureOr<Response> Function(_Call call);

class _Route {
  _Route(this.method, String pattern, this.access, this.handler, {this.rateLimited = false, this.bodyLimit})
    : segments = pattern.split('/').where((s) => s.isNotEmpty).toList();

  final String method;
  final List<String> segments;
  final Access access;
  final _Handler handler;
  final bool rateLimited;
  final int? bodyLimit;

  /// The path parameters when [path] matches, null otherwise.
  Map<String, String>? match(List<String> path) {
    if (path.length != segments.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.startsWith('{') && segment.endsWith('}')) {
        params[segment.substring(1, segment.length - 1)] = path[i];
      } else if (segment != path[i]) {
        return null;
      }
    }
    return params;
  }
}

/// One request on its way through a route.
class _Call {
  _Call(this.request, this.params, this.principal, this.bodyLimit);

  final Request request;
  final Map<String, String> params;
  final Principal? principal;
  final int bodyLimit;

  String get userId => principal!.userId;

  Future<Map<Object?, Object?>?> jsonObject() async {
    final body = await readJsonBody(request, bodyLimit);
    if (body == null) return null;
    if (body is! Map) throw const FormatException('Expected a JSON object.');
    return body;
  }
}

/// Fixed-window rate limit per client address: [limit] requests per [window].
class _RateLimiter {
  _RateLimiter(this.limit, this.window);

  final int limit;
  final Duration window;
  final Map<String, (DateTime start, int count)> _windows = {};

  /// Null when the request may proceed, otherwise how long the caller has to wait.
  Duration? acquire(String key) {
    final now = DateTime.now();
    if (_windows.length > 10000) _windows.removeWhere((_, w) => now.difference(w.$1) >= window);
    final current = _windows[key];
    if (current == null || now.difference(current.$1) >= window) {
      _windows[key] = (now, 1);
      return null;
    }
    if (current.$2 >= limit) return window - now.difference(current.$1);
    _windows[key] = (current.$1, current.$2 + 1);
    return null;
  }
}

/// The Wiretune server: the library index of one music folder, accounts, per-account data and the HTTP API
/// (docs/api.md).
class WiretuneServer {
  WiretuneServer._(
    this.options,
    this.paths,
    this.database,
    this.repository,
    this.library,
    this.auth,
    this.userData,
    this.setupCode,
    this.scanner,
  );

  static const int _defaultBodyLimit = 64 * 1024;
  static const int _playlistBodyLimit = 4 * 1024 * 1024;

  /// The setting that holds the music folder an administrator chose in the player; it wins over the configured one.
  static const String _chosenLibraryPathKey = 'chosen_library_path';

  final ServerOptions options;
  final ServerPaths paths;
  final DatabaseManager database;
  final LibraryRepository repository;
  final LibraryService library;
  final AuthService auth;
  final UserDataService userData;
  final SetupCode setupCode;
  final LibraryScanService scanner;
  final RemoteHub remote = RemoteHub();
  final _RateLimiter _authLimiter = _RateLimiter(10, const Duration(minutes: 1));
  HttpServer? _http;
  late final List<_Route> _routes = _buildRoutes();

  /// The port the server listens on (useful when started on port 0).
  int get port => _http!.port;

  /// Opens the database and the library, then starts listening and scanning.
  static Future<WiretuneServer> start(ServerOptions options) async {
    final dataDirectory = AppPaths.getDataDirectory(overridePath: options.dataDirectory, subdirectory: 'Server');
    WiretuneLog.initialize(path: p.join(dataDirectory, 'wiretune-server.log'), level: options.logLevel);
    WiretuneLog.info('Server', '=== Starting the Wiretune server ${WiretuneInfo.version} ===');
    WiretuneLog.info('Server', '${WiretuneInfo.copyright}. GNU AGPL v3, source: ${WiretuneInfo.sourceUrl}');

    final database = DatabaseManager(p.join(dataDirectory, 'wiretune-server.db'));
    database.initializeSchema();
    final repository = LibraryRepository(database);

    // A library folder chosen through the admin API wins over the configured one, so it survives restarts.
    final saved = await repository.getSetting(_chosenLibraryPathKey);
    String? savedRoot;
    if (saved != null && saved.trim().isNotEmpty) {
      if (Directory(saved).existsSync()) {
        savedRoot = saved;
      } else {
        WiretuneLog.warn('Server', "Saved library path '$saved' no longer exists; using the configured one instead.");
      }
    }
    final paths = ServerPaths(
      savedRoot ?? options.resolveLibraryRoot(),
      dataDirectory,
      p.join(dataDirectory, 'Covers'),
    );
    WiretuneLog.info(
      'Server',
      "Library: '${paths.libraryRoot}' (exists: ${Directory(paths.libraryRoot).existsSync()}), data: '${paths.dataDirectory}'",
    );

    final library = LibraryService(repository, MetadataScanner(), coverCacheDirectory: paths.coverCacheDirectory);
    await library.initialize();
    final auth = AuthService(database, await repository.getOrAddSetting('jwt_secret', AuthService.generateSecret));
    final scanner = LibraryScanService(
      library,
      paths,
      interval: options.scanIntervalMinutes > 0 ? Duration(minutes: options.scanIntervalMinutes) : null,
    );

    final server = WiretuneServer._(
      options,
      paths,
      database,
      repository,
      library,
      auth,
      UserDataService(database),
      SetupCode(options.setupCode),
      scanner,
    );

    if (!auth.hasAnyUsers()) {
      WiretuneLog.warn(
        'Server',
        'No administrator account exists yet. Create it in the player with the setup code ${server.setupCode.value}',
      );
    }

    final http = server._http = await shelf_io.serve(server.handler, options.host, options.port);
    http.autoCompress = false; // JSON is compressed by the handler, audio never
    http.idleTimeout = const Duration(seconds: 120);
    final host = options.host.contains(':') ? '[${options.host}]' : options.host;
    WiretuneLog.info('Server', 'Listening on http://$host:${http.port}');
    scanner.start();
    return server;
  }

  Future<void> close() async {
    await scanner.stop();
    await remote.close(); // their sockets left the HTTP server when they were upgraded
    await _http?.close(force: true);
    _http = null;
    database.close();
  }

  /// The whole HTTP API as a shelf handler.
  Future<Response> handler(Request request) async {
    try {
      final response = await _dispatch(request);
      return await compressJson(request, response);
    } on HijackException {
      rethrow; // a WebSocket took the connection over (remote control)
    } on BodyTooLargeException {
      return errorResponse(413, 'The request body is too large.');
    } on FormatException catch (e) {
      return errorResponse(400, 'The request body is not valid JSON: ${e.message}');
    } catch (e, s) {
      WiretuneLog.error('Server', 'Unhandled error on ${request.method} /${request.url.path}: $e', e, s);
      return errorResponse(500, 'An internal error occurred.');
    }
  }

  Future<Response> _dispatch(Request request) async {
    // Already percent-decoded, and only once: an ID may itself contain "%". Shelf answers 400 to a path that does not
    // decode before the request gets here.
    final path = request.url.pathSegments;
    final method = request.method == 'HEAD' ? 'GET' : request.method;

    _Route? route;
    Map<String, String>? params;
    var pathMatched = false;
    for (final candidate in _routes) {
      final match = candidate.match(path);
      if (match == null) continue;
      pathMatched = true;
      if (candidate.method == method) {
        route = candidate;
        params = match;
        break;
      }
    }
    if (route == null) return pathMatched ? Response(405) : notFound();
    if (request.method == 'HEAD' && route.access != Access.media) return Response(405);

    Principal? principal;
    if (route.access != Access.anonymous) {
      principal = _authenticate(request, route.access == Access.media);
      if (principal == null) return unauthorized();
      if (route.access == Access.admin && !principal.isAdmin) return forbidden();
    }

    if (route.rateLimited) {
      final wait = _authLimiter.acquire(_clientAddress(request));
      if (wait != null) {
        return jsonResponse(
          {'error': 'Too many attempts. Try again in a minute.'},
          status: 429,
          headers: {'retry-after': '${(wait.inMilliseconds / 1000).ceil()}'},
        );
      }
    }

    return route.handler(_Call(request, params!, principal, route.bodyLimit ?? _defaultBodyLimit));
  }

  /// The account behind the request's token, or null. A stream token opens the media routes and nothing else, and it is
  /// the only kind a query string may carry (URLs end up in logs). Tokens live for up to 90 days, so every one is checked
  /// against the accounts: deleting an account ends its access immediately.
  Principal? _authenticate(Request request, bool isMediaRoute) {
    String? token;
    var fromQuery = false;
    final header = request.headers['authorization'];
    if (header != null && header.toLowerCase().startsWith('bearer ')) {
      token = header.substring(7).trim();
    } else if (isMediaRoute) {
      token = request.url.queryParameters['token'];
      fromQuery = true;
    }
    if (token == null || token.isEmpty) return null;

    final principal = auth.validate(token);
    if (principal == null) return null;
    if (principal.isStreamToken ? !isMediaRoute : fromQuery) return null;
    if (!auth.userExists(principal.userId)) return null;
    return principal;
  }

  String _clientAddress(Request request) {
    if (options.trustProxy) {
      final forwarded = request.headers['x-forwarded-for'];
      // The last entry is the one the nearest proxy appended; the ones before it are whatever the client sent.
      final hops = forwarded?.split(',').map((h) => h.trim()).where((h) => h.isNotEmpty);
      if (hops != null && hops.isNotEmpty) return hops.last;
    }
    final info = request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : 'unknown';
  }

  // ── Routes ─────────────────────────────────────────────────────────────────────────────────────

  List<_Route> _buildRoutes() => [
    // Authentication (anonymous)
    _Route(
      'GET',
      '/api/auth/setup-required',
      Access.anonymous,
      (_) => jsonResponse({'setupRequired': !auth.hasAnyUsers()}),
    ),
    _Route('POST', '/api/auth/setup', Access.anonymous, _setup, rateLimited: true),
    _Route('POST', '/api/auth/login', Access.anonymous, _login, rateLimited: true),

    // Authentication (signed in)
    _Route('POST', '/api/auth/register', Access.admin, _register),
    _Route(
      'POST',
      '/api/auth/stream-token',
      Access.user,
      (call) => jsonResponse(auth.createStreamToken(call.principal!.userId, call.principal!.username).toJson()),
    ),
    _Route('POST', '/api/auth/change-password', Access.user, _changePassword, rateLimited: true),
    _Route('GET', '/api/auth/me', Access.user, (call) {
      final user = auth.getUser(call.userId);
      return user == null ? unauthorized() : jsonResponse(user.toJson());
    }),
    _Route('GET', '/api/users', Access.admin, (_) => jsonResponse(auth.getAllUsers().map((u) => u.toJson()).toList())),
    _Route('POST', '/api/users/{userId}/password', Access.admin, _adminResetPassword),
    _Route('DELETE', '/api/users/{userId}', Access.admin, (call) {
      final userId = call.params['userId']!;
      if (call.userId == userId) {
        return errorResponse(400, 'You cannot delete your own account.');
      }
      if (!auth.deleteUser(userId)) return errorResponse(404, 'User not found.');
      remote.disconnectAccount(userId);
      return Response.ok(null);
    }),
    _Route('GET', '/api/config', Access.admin, (_) => jsonResponse(ServerConfigInfo(paths.libraryRoot).toJson())),
    _Route('POST', '/api/config/library-path', Access.admin, _updateLibraryPath),

    // Library
    _Route(
      'GET',
      '/api/library/status',
      Access.user,
      (_) => jsonResponse(
        ServerLibraryStatus(
          library.tracks.length,
          library.albums.length,
          library.artists.length,
          library.isScanning,
          scanner.lastScanCompletedUtc,
          scanner.lastScanError,
        ).toJson(),
      ),
    ),
    _Route('POST', '/api/library/scan', Access.admin, (_) {
      scanner.requestScan();
      return jsonResponse({'message': 'Scan requested.'}, status: 202, headers: {'location': '/api/library/status'});
    }),
    _Route('GET', '/api/tracks', Access.user, (call) {
      final q = call.request.url.queryParameters['q'];
      final tracks = isBlank(q) ? library.tracks : library.search(q!);
      return jsonResponse(tracks.map((t) => t.toJson()).toList());
    }),

    // Media
    _Route('GET', '/api/stream/{trackId}', Access.media, _stream),
    _Route('GET', '/api/cover/album/{albumId}', Access.media, (call) {
      final album = library.getAlbum(call.params['albumId']!);
      return _cover(call.request, album?.tracks.where((t) => t.hasCoverArt).firstOrNull);
    }),
    _Route(
      'GET',
      '/api/cover/{trackId}',
      Access.media,
      (call) => _cover(call.request, library.getTrack(call.params['trackId']!)),
    ),
    _Route('GET', '/api/lyrics/{trackId}', Access.user, _lyrics),

    // Remote control: a WebSocket per player
    _Route('GET', '/api/remote', Access.user, _remote),

    // The signed-in account's favourites, play counts, playlists and hidden items
    _Route('GET', '/api/me/data', Access.user, (call) => jsonResponse(userData.get(call.userId).toJson())),
    _Route('PUT', '/api/me/favorites/{trackId}', Access.user, (call) => _favorite(call, true)),
    _Route('DELETE', '/api/me/favorites/{trackId}', Access.user, (call) => _favorite(call, false)),
    _Route('PUT', '/api/me/hidden/{type}/{itemId}', Access.user, (call) => _setHidden(call, true)),
    _Route('DELETE', '/api/me/hidden/{type}/{itemId}', Access.user, (call) => _setHidden(call, false)),
    _Route('POST', '/api/me/plays/{trackId}', Access.user, (call) {
      final trackId = call.params['trackId']!;
      final error = UserDataRules.validateId(trackId);
      if (error != null) return errorResponse(400, error);
      final stats = userData.recordPlay(call.userId, trackId);
      return stats == null
          ? errorResponse(409, 'An account can keep statistics for at most ${UserDataRules.maxTrackStats} tracks.')
          : jsonResponse(stats.toJson());
    }),
    _Route('PUT', '/api/me/playlists/{playlistId}', Access.user, _savePlaylist, bodyLimit: _playlistBodyLimit),
    _Route('DELETE', '/api/me/playlists/{playlistId}', Access.user, (call) {
      return userData.deletePlaylist(call.userId, call.params['playlistId']!)
          ? jsonResponse({'deleted': true})
          : errorResponse(404, 'Playlist not found.');
    }),
  ];

  Future<Response> _setup(_Call call) async {
    final body = await call.jsonObject();
    final username = body?['username'] is String ? body!['username'] as String : null;
    final password = body?['password'] is String ? body!['password'] as String : null;
    final error = AuthService.validateCredentials(username, password);
    if (error != null) return errorResponse(400, error);

    if (auth.hasAnyUsers()) return errorResponse(409, 'The server is already set up. Sign in instead.');
    final code = body?['setupCode'];
    if (!setupCode.matches(code is String ? code : null)) {
      return errorResponse(403, 'The setup code is missing or wrong. The server prints it in its log when it starts.');
    }

    final result = await auth.createAdmin(username!, password!);
    return result == null
        ? errorResponse(409, 'The server is already set up. Sign in instead.')
        : jsonResponse(result.toJson());
  }

  Future<Response> _login(_Call call) async {
    final body = await call.jsonObject();
    final username = body?['username'];
    final password = body?['password'];
    if (username is! String || username.trim().isEmpty || password is! String || password.isEmpty) {
      return errorResponse(400, 'Username and password are required.');
    }
    final result = await auth.login(username, password, rememberMe: body?['rememberMe'] == true);
    return result == null ? unauthorized() : jsonResponse(result.toJson());
  }

  Future<Response> _changePassword(_Call call) async {
    final body = await call.jsonObject();
    final current = body?['currentPassword'];
    final replacement = body?['newPassword'];
    if (current is! String || current.isEmpty || replacement is! String) {
      return errorResponse(400, 'The current and the new password are required.');
    }
    final error = AuthService.validatePassword(replacement);
    if (error != null) return errorResponse(400, error);
    return await auth.changePassword(call.userId, current, replacement)
        ? jsonResponse({'changed': true})
        : errorResponse(403, 'The current password is wrong.');
  }

  Future<Response> _adminResetPassword(_Call call) async {
    final body = await call.jsonObject();
    final replacement = body?['newPassword'];
    if (replacement is! String) return errorResponse(400, 'A new password is required.');
    final error = AuthService.validatePassword(replacement);
    if (error != null) return errorResponse(400, error);
    final userId = call.params['userId']!;
    return await auth.resetPassword(userId, replacement)
        ? jsonResponse({'changed': true})
        : errorResponse(404, 'User not found.');
  }

  Future<Response> _register(_Call call) async {
    final body = await call.jsonObject();
    final username = body?['username'] is String ? body!['username'] as String : null;
    final password = body?['password'] is String ? body!['password'] as String : null;
    final error = AuthService.validateCredentials(username, password);
    if (error != null) return errorResponse(400, error);
    final user = await auth.register(username!, password!);
    return user == null ? errorResponse(409, 'Username already taken.') : jsonResponse(user.toJson());
  }

  Future<Response> _updateLibraryPath(_Call call) async {
    final body = await call.jsonObject();
    final newPath = body?['newPath'];
    if (newPath is! String || newPath.trim().isEmpty) return errorResponse(400, 'The folder path must not be empty.');

    String fullPath;
    try {
      fullPath = AppPaths.fullPath(newPath);
    } catch (_) {
      return errorResponse(400, 'The folder path is not valid.');
    }
    if (!Directory(fullPath).existsSync()) return errorResponse(400, 'The folder does not exist: $fullPath');

    if (Platform.isLinux) {
      const forbiddenRoots = ['/proc', '/sys', '/dev'];
      if (forbiddenRoots.any((b) => fullPath == b || p.isWithin(b, fullPath))) {
        return errorResponse(400, 'System directory cannot be used as library folder.');
      }
    }
    if (AppPaths.isPathUnderRoot(fullPath, paths.dataDirectory)) {
      return errorResponse(400, 'Server data directory cannot be used as library folder.');
    }

    await repository.setSetting(_chosenLibraryPathKey, fullPath);
    paths.libraryRoot = fullPath;
    scanner.requestScan();
    return jsonResponse(ServerConfigInfo(paths.libraryRoot).toJson());
  }

  Future<Response> _stream(_Call call) async {
    final track = library.getTrack(call.params['trackId']!);
    if (track == null ||
        !AppPaths.isPathUnderRoot(track.filePath, paths.libraryRoot) ||
        !File(track.filePath).existsSync()) {
      return errorResponse(404, 'Track not found.');
    }
    return fileResponse(call.request, File(track.filePath), AudioFileTypes.mimeType(track.filePath));
  }

  Future<Response> _cover(Request request, Track? track) async {
    if (track == null || !AppPaths.isPathUnderRoot(track.filePath, paths.libraryRoot)) return notFound();
    const cache = {'cache-control': 'private, max-age=86400'};

    final coverPath = track.coverArtPath;
    if (coverPath != null &&
        coverPath.isNotEmpty &&
        File(coverPath).existsSync() &&
        (AppPaths.isPathUnderRoot(coverPath, paths.coverCacheDirectory) ||
            AppPaths.isPathUnderRoot(coverPath, paths.libraryRoot))) {
      return fileResponse(request, File(coverPath), ImageFormat.mimeTypeFromPath(coverPath), headers: cache);
    }

    final bytes = File(track.filePath).existsSync() ? await MetadataScanner().extractCoverArt(track.filePath) : null;
    if (bytes == null || bytes.isEmpty) return notFound();
    return Response.ok(bytes, headers: {...cache, 'content-type': ImageFormat.mimeType(bytes)});
  }

  /// Upgrades the request to a WebSocket and hands it to the hub. The sign-in token comes in the header like on every
  /// other route (never in the URL), and a request from a web page (which carries an `Origin`) is turned away: no page
  /// has business controlling the players, and a browser lets any page open a WebSocket to any address.
  Response _remote(_Call call) {
    final request = call.request;
    final headers = request.headers;
    final connection = headers['connection']?.toLowerCase().split(',').map((t) => t.trim()) ?? const [];
    if (headers['upgrade']?.toLowerCase() != 'websocket' || !connection.contains('upgrade')) {
      return jsonResponse(
        {'error': 'This route speaks WebSocket only.'},
        status: 426,
        headers: {'upgrade': 'websocket', 'connection': 'Upgrade'},
      );
    }
    if (headers.containsKey('origin')) return forbidden();
    final key = headers['sec-websocket-key'];
    if (key == null || key.trim().isEmpty || headers['sec-websocket-version'] != '13') {
      return errorResponse(400, 'This is not a valid WebSocket handshake.');
    }

    final principal = call.principal!;
    if (!remote.canJoin(principal.userId)) return errorResponse(429, 'Too many connections for this account.');
    request.hijack((channel) {
      final socket = channel.sink as Socket;
      final accept = base64.encode(sha1.convert(utf8.encode('${key.trim()}$_webSocketGuid')).bytes);
      socket.add(
        utf8.encode(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        ),
      );
      remote.join(WebSocket.fromUpgradedSocket(socket, serverSide: true), principal);
    });
  }

  /// RFC 6455's constant for the handshake's accept key.
  static const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  Future<Response> _lyrics(_Call call) async {
    final track = library.getTrack(call.params['trackId']!);
    if (track == null || !AppPaths.isPathUnderRoot(track.filePath, paths.libraryRoot)) return notFound();
    final lyrics = await MetadataScanner.readLyrics(track.filePath);
    return lyrics == null ? notFound() : jsonResponse({'lyrics': lyrics});
  }

  Response _favorite(_Call call, bool favorite) {
    final trackId = call.params['trackId']!;
    final error = UserDataRules.validateId(trackId);
    if (error != null) return errorResponse(400, error);
    return userData.setFavorite(call.userId, trackId, favorite)
        ? jsonResponse({'trackId': trackId, 'isFavorite': favorite})
        : errorResponse(409, 'An account can have at most ${UserDataRules.maxFavorites} favourites.');
  }

  Response _setHidden(_Call call, bool hidden) {
    final type = call.params['type']!;
    final itemId = call.params['itemId']!;
    if (type != 'artist' && type != 'album' && type != 'track') {
      return errorResponse(400, 'Invalid item type: $type. Must be artist, album, or track.');
    }
    final error = UserDataRules.validateId(itemId);
    if (error != null) return errorResponse(400, error);
    return userData.setHidden(call.userId, type, itemId, hidden)
        ? jsonResponse({'type': type, 'itemId': itemId, 'hidden': hidden})
        : errorResponse(409, 'An account can have at most ${UserDataRules.maxHidden} hidden items.');
  }

  Future<Response> _savePlaylist(_Call call) async {
    final playlistId = call.params['playlistId']!;
    final body = await call.jsonObject();
    PlaylistUpdate? update;
    try {
      update = body == null ? null : PlaylistUpdate.fromJson(body);
    } on Object {
      return errorResponse(400, 'The playlist is not valid.');
    }
    final error = UserDataService.validatePlaylist(playlistId, update);
    if (error != null) return errorResponse(400, error);

    final saved = userData.savePlaylist(call.userId, playlistId, update!);
    return saved == null
        ? errorResponse(409, 'An account can have at most ${UserDataRules.maxPlaylists} playlists.')
        : jsonResponse(saved.toJson());
  }
}
