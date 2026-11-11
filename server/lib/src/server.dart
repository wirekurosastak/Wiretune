// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:wiretune_core/wiretune_core.dart';

import 'album_lookup_service.dart';
import 'auth_service.dart';
import 'blend_service.dart';
import 'block_service.dart';
import 'credit_lookup_service.dart';
import 'config.dart';
import 'http_utils.dart';
import 'library_scan_service.dart';
import 'recommendation_service.dart';
import 'remote_hub.dart';
import 'setup_code.dart';
import 'transcoder.dart';
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
    this.albumLookups,
    this.creditLookups,
  );

  static const int _defaultBodyLimit = 64 * 1024;
  static const int _playlistBodyLimit = 4 * 1024 * 1024;

  /// The setting that holds the music folder an administrator chose in the player; it wins over the configured one.
  static const String _chosenMusicFolderKey = 'chosen_music_folder';

  final ServerOptions options;
  final ServerPaths paths;
  final DatabaseManager database;
  final LibraryRepository repository;
  final LibraryService library;
  final AuthService auth;
  final UserDataService userData;
  final SetupCode setupCode;
  final LibraryScanService scanner;

  /// Each album's genre and label, looked up online for the tracks whose files don't name them.
  final AlbumLookupService albumLookups;

  /// A track's credits, looked up online when a player asks.
  final CreditLookupService creditLookups;
  late final RemoteHub remote = RemoteHub()..blocks = blocks.blocks;

  /// Converts tracks for players that asked for less than the original (`?format=opus&bitrate=96`).
  late final Transcoder transcoder = Transcoder(p.join(paths.dataDirectory, 'Transcodes'));

  /// What the accounts recommend to each other.
  late final RecommendationService recommendations = RecommendationService(database);
  late final BlockService blocks = BlockService(database);

  /// The playlists mixed from two accounts' listening.
  late final BlendService blends = BlendService(database, userData, library, blocks.blocks);
  final _RateLimiter _authLimiter = _RateLimiter(10, const Duration(minutes: 1));
  HttpServer? _http;
  late final List<_Route> _routes = _buildRoutes();

  /// The track list as `/api/tracks` serves it (encoded); listed again after every scan, since a cover can change while
  /// the tracks stay the same.
  JsonDocument? _trackList;

  /// The artists' own pictures as `/api/artists/pictures` serves them (encoded): each one's version by artist ID.
  JsonDocument? _artistPictureList;

  /// The version of the lists the players were last told about.
  String? _announcedLibrary;

  /// The port the server listens on (useful when started on port 0).
  int get port => _http!.port;

  /// Opens the database and the library, then starts listening and scanning. [online] is what reaches the internet
  /// (the album lookups); tests give one of their own.
  static Future<WiretuneServer> start(ServerOptions options, {http.Client? online}) async {
    final dataDirectory = AppPaths.getDataDirectory(overridePath: options.dataDirectory, subdirectory: 'Server');
    WiretuneLog.initialize(path: p.join(dataDirectory, 'wiretune-server.log'), level: options.logLevel);
    WiretuneLog.info('Server', '=== Starting the Wiretune server ${WiretuneInfo.version} ===');
    WiretuneLog.info('Server', '${WiretuneInfo.copyright}. GNU AGPL v3, source: ${WiretuneInfo.sourceUrl}');

    // Before anything is opened: a certificate that can't be used stops the start with its own message.
    final tls = options.securityContext();

    final database = DatabaseManager(p.join(dataDirectory, 'wiretune-server.db'));
    database.initializeSchema();
    final repository = LibraryRepository(database);

    // A library folder chosen through the admin API wins over the configured one, so it survives restarts. One that is
    // missing right now (a share not mounted yet) is kept like a configured one: the scans wait for it, where falling
    // back to another folder would replace the index with that folder's tracks.
    final saved = repository.getSetting(_chosenMusicFolderKey);
    final paths = ServerPaths(
      saved != null && saved.trim().isNotEmpty ? saved : options.resolveMusicFolder(),
      dataDirectory,
      p.join(dataDirectory, 'Covers'),
    );
    WiretuneLog.info(
      'Server',
      "Library: '${paths.musicFolder}' (exists: ${Directory(paths.musicFolder).existsSync()}), data: '${paths.dataDirectory}'",
    );

    final library = LibraryService(repository, MetadataScanner(), coverCacheDirectory: paths.coverCacheDirectory);
    library.initialize();
    final auth = AuthService(database, repository.getOrAddSetting('jwt_secret', AuthService.generateSecret));
    final scanner = LibraryScanService(
      library,
      paths,
      interval: options.scanIntervalMinutes > 0 ? Duration(minutes: options.scanIntervalMinutes) : null,
    );

    final albums = AlbumLookupService(database, client: online);
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
      albums,
      CreditLookupService(database, enabled: () => albums.enabled, client: online),
    );

    if (!auth.hasAnyUsers()) {
      WiretuneLog.warn(
        'Server',
        'No administrator account exists yet. Create it in the player with the setup code ${server.setupCode.value}',
      );
    }
    // What the players may already have, so that the start-up scan tells them when it found something new.
    server._announcedLibrary = await server._libraryVersion();
    scanner.onScanned = server._scanned;
    library.onTracksMoved = server._tracksMoved;
    server.userData.blocks = server.blocks.blocks;

    final http = server._http = await shelf_io.serve(server.handler, options.host, options.port, securityContext: tls);
    http.autoCompress = false; // JSON is compressed by the handler, audio never
    http.idleTimeout = const Duration(seconds: 120);
    final host = options.host.contains(':') ? '[${options.host}]' : options.host;
    WiretuneLog.info('Server', 'Listening on http${tls == null ? '' : 's'}://$host:${http.port}');
    scanner.start();
    return server;
  }

  /// Gives the account named [username] (ignoring case) a new random password and ends its sessions, without the server
  /// running: `wiretune_server --reset-password <name>`, for an administrator who lost theirs. Returns the password;
  /// throws [FormatException] when the data folder has no database or no such account.
  static Future<String> resetPassword(ServerOptions options, String username) async {
    final dataDirectory = AppPaths.getDataDirectory(overridePath: options.dataDirectory, subdirectory: 'Server');
    final file = p.join(dataDirectory, 'wiretune-server.db');
    if (!File(file).existsSync()) {
      throw FormatException("There is no server database in '$dataDirectory'. Give the server's --data-dir.");
    }
    final database = DatabaseManager(file);
    try {
      database.initializeSchema();
      final auth = AuthService(
        database,
        LibraryRepository(database).getOrAddSetting('jwt_secret', AuthService.generateSecret),
      );
      final users = auth.getAllUsers();
      final user = users.where((u) => u.username.toLowerCase() == username.trim().toLowerCase()).firstOrNull;
      if (user == null) {
        throw FormatException(
          'There is no account named "$username". Accounts: ${users.map((u) => u.username).join(', ')}',
        );
      }
      final password = SetupCode.random(3);
      await auth.resetPassword(user.id, password);
      return password;
    } finally {
      database.close();
    }
  }

  Future<void> close() async {
    albumLookups.close();
    creditLookups.close();
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
      return errorResponse(413, ErrorCodes.bodyTooLarge, 'The request body is too large.');
    } on FormatException catch (e) {
      return errorResponse(400, ErrorCodes.invalidJson, 'The request body is not valid JSON: ${e.message}');
    } catch (e, s) {
      WiretuneLog.error('Server', 'Unhandled error on ${request.method} /${request.url.path}: $e', e, s);
      return errorResponse(500, ErrorCodes.internalError, 'An internal error occurred.');
    }
  }

  Future<Response> _dispatch(Request request) async {
    // Already percent-decoded, and only once: an ID may itself contain "%". Shelf answers 400 to a path that does not
    // decode before the request gets here.
    final path = request.url.pathSegments;
    final method = request.method == 'HEAD' ? 'GET' : request.method;
    // The address in a browser: whoever tries it sees that the server runs, and what to open it with.
    if (path.isEmpty && method == 'GET') {
      return Response.ok(
        'Wiretune server. It has no web page: connect with a Wiretune player.\n${WiretuneInfo.sourceUrl}\n',
      );
    }

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
    if (route == null) {
      return pathMatched ? Response(405) : errorResponse(404, ErrorCodes.unknownRoute, 'Not found.');
    }
    if (request.method == 'HEAD' && route.access != Access.media) return Response(405);

    Principal? principal;
    if (route.access != Access.anonymous) {
      final check = _authenticate(request, route.access == Access.media);
      principal = check.principal;
      if (principal == null) return unauthorized(check.refusal!);
      if (route.access == Access.admin && !principal.isAdmin) return forbidden();
    }

    if (route.rateLimited) {
      final wait = _authLimiter.acquire(_clientAddress(request));
      if (wait != null) {
        final seconds = (wait.inMilliseconds / 1000).ceil();
        return errorResponse(429, ErrorCodes.rateLimited, 'Too many attempts. Try again in a minute.', {
          'retryAfter': seconds,
        }).change(headers: {'retry-after': '$seconds'});
      }
    }

    return route.handler(_Call(request, params!, principal, route.bodyLimit ?? _defaultBodyLimit));
  }

  /// The account behind the request's token, or null. A stream token opens the media routes and nothing else, and it is
  /// the only kind a query string may carry (URLs end up in logs). Tokens live for up to 90 days, so every one is checked
  /// against the accounts ([AuthService.authenticate]): deleting an account or changing its password ends the access
  /// of the tokens issued before, and the role is always the account's present one.
  TokenCheck _authenticate(Request request, bool isMediaRoute) {
    String? token;
    var fromQuery = false;
    final header = request.headers['authorization'];
    if (header != null && header.toLowerCase().startsWith('bearer ')) {
      token = header.substring(7).trim();
    } else if (isMediaRoute) {
      token = request.url.queryParameters['token'];
      fromQuery = true;
    }
    if (token == null || token.isEmpty) return const TokenCheck.refused(ErrorCodes.signInRequired);

    final check = auth.authenticate(token);
    final principal = check.principal;
    if (principal == null) return check;
    if (principal.isStreamToken ? !isMediaRoute : fromQuery) return const TokenCheck.refused(ErrorCodes.tokenInvalid);
    return check;
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
    _Route('POST', '/api/auth/login-with-code', Access.anonymous, (call) async {
      final code = (await call.jsonObject())?['code'];
      if (code is! String || code.trim().isEmpty) {
        return errorResponse(400, ErrorCodes.invalidJson, 'The body is { "code" }.');
      }
      final result = auth.signInWithCode(code);
      return result == null ? unauthorized(ErrorCodes.signInCodeInvalid) : jsonResponse(result.toJson());
    }, rateLimited: true),

    // Authentication (signed in)
    _Route(
      'POST',
      '/api/auth/stream-token',
      Access.user,
      (call) => jsonResponse(auth.createStreamToken(call.principal!).toJson()),
    ),
    _Route(
      'POST',
      '/api/auth/sign-in-code',
      Access.user,
      (call) => jsonResponse(auth.createSignInCode(call.principal!).toJson()),
    ),
    _Route('POST', '/api/auth/change-password', Access.user, _changePassword, rateLimited: true),
    _Route('POST', '/api/auth/change-username', Access.user, _changeUsername, rateLimited: true),
    _Route('GET', '/api/auth/me', Access.user, (call) {
      final user = auth.getUser(call.userId);
      return user == null ? unauthorized(ErrorCodes.accountRemoved) : jsonResponse(user.toJson());
    }),
    _Route('GET', '/api/users', Access.admin, (_) => jsonResponse(auth.getAllUsers().map((u) => u.toJson()).toList())),
    _Route('POST', '/api/users', Access.admin, _addUser),
    _Route('POST', '/api/users/{userId}/password', Access.admin, _adminResetPassword),
    _Route('POST', '/api/users/{userId}/username', Access.admin, (call) => _rename(call, call.params['userId']!)),
    _Route('DELETE', '/api/users/{userId}', Access.admin, (call) {
      final userId = call.params['userId']!;
      if (call.userId == userId) {
        return errorResponse(400, ErrorCodes.cannotDeleteSelf, 'You cannot delete your own account.');
      }
      final partners = blends.partners(userId);
      final sharers = userData.sharingPartners(userId);
      if (!auth.deleteUser(userId)) return errorResponse(404, ErrorCodes.userNotFound, 'User not found.');
      remote.disconnectAccount(userId, 'The account was removed.');
      partners.forEach(remote.blendsChanged); // its Blends went
      for (final account in sharers) {
        remote.dataChanged(account); // and its shared playlists, and its invitations
        remote.playlistInvitesChanged(account);
      }
      return Response.ok(null);
    }),
    // Every account by its name, for the others to recommend to and listen together with
    _Route('GET', '/api/accounts', Access.user, (_) => jsonResponse([for (final a in auth.getAccounts()) a.toJson()])),
    _Route('GET', '/api/config', Access.admin, (_) => jsonResponse(_config.toJson())),
    _Route('POST', '/api/config/music-folder', Access.admin, _setMusicFolder),
    _Route('POST', '/api/config/online-lookups', Access.admin, (call) async {
      final on = (await call.jsonObject())?['enabled'];
      if (on is! bool) return errorResponse(400, ErrorCodes.invalidJson, 'The body is { "enabled": true or false }.');
      albumLookups.enabled = on;
      if (on) _lookUpAlbums();
      return jsonResponse(_config.toJson());
    }),
    _Route('POST', '/api/config/members-can-rename', Access.admin, (call) async {
      final allowed = (await call.jsonObject())?['enabled'];
      if (allowed is! bool) {
        return errorResponse(400, ErrorCodes.invalidJson, 'The body is { "enabled": true or false }.');
      }
      auth.membersCanRename = allowed;
      return jsonResponse(_config.toJson());
    }),

    // What a player needs to know of this server: an older one than the player lacks routes, and one without ffmpeg
    // sends every track as its file.
    _Route(
      'GET',
      '/api/server',
      Access.user,
      (call) async =>
          jsonResponse(ServerInfo(UpdateCheck.currentVersion, converts: await transcoder.isAvailable).toJson()),
    ),

    // Library
    _Route(
      'GET',
      '/api/library/status',
      Access.user,
      (call) => jsonResponse(
        ServerLibraryStatus(
          library.tracks.length,
          library.albums.length,
          library.artists.length,
          library.isScanning,
          scanner.lastScanAt,
          // The reason names the server's folders, which only an administrator sees.
          call.principal!.isAdmin ? scanner.lastScanError : null,
          call.principal!.isAdmin ? scanner.lastScanProblem : null,
        ).toJson(),
      ),
    ),
    _Route('POST', '/api/library/scan', Access.admin, (_) {
      scanner.requestScan();
      return jsonResponse({'message': 'Scan requested.'}, status: 202, headers: {'location': '/api/library/status'});
    }),
    _Route('GET', '/api/tracks', Access.user, (call) => versionedJson(call.request, _tracks)),
    _Route('GET', '/api/artists/pictures', Access.user, (call) => versionedJson(call.request, _artistPictures)),

    // Media
    _Route('GET', '/api/stream/{trackId}', Access.media, _stream),
    _Route(
      'GET',
      '/api/cover/album/{albumId}',
      Access.media,
      (call) => _cover(call.request, _coverTrack(call.params['albumId']!)),
    ),
    _Route('GET', '/api/cover/artist/{artistId}', Access.media, _artistPicture),
    _Route('GET', '/api/lyrics/{trackId}', Access.user, _lyrics),
    _Route('GET', '/api/tracks/{trackId}/credits', Access.user, (call) async {
      final track = library.getTrack(call.params['trackId']!);
      if (track == null) return errorResponse(404, ErrorCodes.notFound, 'Track not found.');
      return jsonResponse({
        'credits': [for (final credit in await creditLookups.creditsOf(track)) credit.toJson()],
      });
    }),

    // Remote control: a WebSocket per player
    _Route('GET', '/api/remote', Access.user, _remote),

    // The signed-in account's favourites, play counts, playlists and hidden items
    _Route(
      'GET',
      '/api/me/data',
      Access.user,
      (call) => versionedJson(call.request, JsonDocument(utf8.encode(jsonEncode(userData.get(call.userId).toJson())))),
    ),
    _Route('PUT', '/api/me/favorites/{trackId}', Access.user, (call) => _favorite(call, true)),
    _Route('DELETE', '/api/me/favorites/{trackId}', Access.user, (call) => _favorite(call, false)),
    _Route('PUT', '/api/me/hidden/{type}/{itemId}', Access.user, (call) => _setHidden(call, true)),
    _Route('DELETE', '/api/me/hidden/{type}/{itemId}', Access.user, (call) => _setHidden(call, false)),
    _Route('POST', '/api/me/plays/{trackId}', Access.user, (call) async {
      final trackId = call.params['trackId']!;
      final error = UserDataRules.validateId(trackId);
      if (error != null) return errorResponse(400, ErrorCodes.invalidId, error);
      // When it was played, from a player that tells of it later; a body without one means now.
      final stats = userData.recordPlay(call.userId, trackId, parseIsoUtc((await call.jsonObject())?['at']));
      return stats == null
          ? errorResponse(
              409,
              ErrorCodes.playCountsLimit,
              'An account can keep statistics for at most ${UserDataRules.maxTrackStats} tracks.',
              {'limit': UserDataRules.maxTrackStats},
            )
          : jsonResponse(stats.toJson());
    }),
    // How often the account played each track in a time, for its listening summary
    _Route('GET', '/api/me/plays', Access.user, (call) {
      final query = call.request.url.queryParameters;
      final from = parseIsoUtc(query['from']);
      final until = parseIsoUtc(query['to']);
      if (from == null || until == null || !from.isBefore(until)) {
        return errorResponse(400, ErrorCodes.invalidPeriod, 'Give "from" and "to" as ISO times, "from" first.');
      }
      final (:plays, :since) = userData.playsBetween(call.userId, from, until);
      return jsonResponse({'plays': plays, 'since': since == null ? null : formatIsoUtc(since)});
    }),
    // What the other accounts recommended to this one, and recommending
    _Route(
      'GET',
      '/api/me/recommendations',
      Access.user,
      (call) => jsonResponse([for (final r in recommendations.received(call.userId)) r.toJson()]),
    ),
    _Route('POST', '/api/me/recommendations', Access.user, _recommend),
    // The accounts this one blocked
    _Route(
      'GET',
      '/api/me/blocked',
      Access.user,
      (call) => jsonResponse([for (final a in blocks.blocked(call.userId)) a.toJson()]),
    ),
    _Route('PUT', '/api/me/blocked/{userId}', Access.user, (call) {
      final other = call.params['userId']!;
      if (!blocks.block(call.userId, other)) return errorResponse(404, ErrorCodes.userNotFound, 'User not found.');
      remote.blocked(call.userId, other);
      remote.recommendationsChanged(call.userId); // what it recommended went
      if (blends.end(call.userId, other)) {
        remote.blendsChanged(call.userId);
        remote.blendsChanged(other);
      }
      // The playlists either shared with the other go from it.
      if (userData.endSharing(call.userId, other)) {
        for (final account in [call.userId, other]) {
          remote.dataChanged(account);
          remote.playlistInvitesChanged(account);
        }
      }
      return jsonResponse({'userId': other, 'blocked': true});
    }),
    _Route('DELETE', '/api/me/blocked/{userId}', Access.user, (call) {
      blocks.unblock(call.userId, call.params['userId']!);
      return jsonResponse({'userId': call.params['userId'], 'blocked': false});
    }),
    // The Blends: playlists mixed from this account's listening and another's
    _Route(
      'GET',
      '/api/me/blends',
      Access.user,
      (call) => jsonResponse([for (final blend in blends.of(call.userId)) blend.toJson()]),
    ),
    _Route('POST', '/api/me/blends', Access.user, _inviteToBlend),
    _Route('DELETE', '/api/me/blends/{id}', Access.user, (call) {
      final other = blends.leave(call.userId, call.params['id']!);
      if (other == null) return errorResponse(404, ErrorCodes.blendNotFound, 'Blend not found.');
      remote.blendsChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
      remote.blendsChanged(other);
      return jsonResponse({'deleted': true});
    }),
    _Route('POST', '/api/me/recommendations/seen', Access.user, (call) {
      recommendations.markSeen(call.userId);
      remote.recommendationsChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
      return jsonResponse({'seen': true});
    }),
    _Route('DELETE', '/api/me/recommendations/{id}', Access.user, (call) {
      final to = recommendations.remove(call.userId, call.params['id']!);
      if (to == null) return errorResponse(404, ErrorCodes.recommendationNotFound, 'Recommendation not found.');
      // Dismissed by its recipient (whose other players follow), or taken back by its sender.
      remote.recommendationsChanged(
        to,
        except: to == call.userId ? call.request.headers[RemoteRules.deviceHeader] : null,
      );
      return jsonResponse({'deleted': true});
    }),
    _Route('PUT', '/api/me/playlists/{playlistId}', Access.user, _savePlaylist, bodyLimit: _playlistBodyLimit),
    _Route('DELETE', '/api/me/playlists/{playlistId}', Access.user, (call) {
      final playlistId = call.params['playlistId']!;
      // Told before it goes: the members of one deleted, or the owner and members of one left.
      final others = userData.playlistAccounts(call.userId, playlistId);
      final invited = userData.playlistsOf(call.userId).where((p) => p.id == playlistId).firstOrNull?.sharing.invited;
      if (!userData.deletePlaylist(call.userId, playlistId)) {
        return errorResponse(404, ErrorCodes.playlistNotFound, 'Playlist not found.');
      }
      _dataChanged(call);
      others.forEach(remote.dataChanged);
      for (final account in invited ?? const <AccountInfo>[]) {
        remote.playlistInvitesChanged(account.id);
      }
      return jsonResponse({'deleted': true});
    }),
    // Sharing a playlist: its owner invites another account or stops sharing with it; the account joins or declines
    _Route('PUT', '/api/me/playlists/{playlistId}/members/{userId}', Access.user, (call) {
      final playlistId = call.params['playlistId']!;
      final member = call.params['userId']!;
      if (member == call.userId || !auth.getAccounts().any((a) => a.id == member)) {
        return errorResponse(400, ErrorCodes.playlistMemberInvalid, 'Choose another account of this server.');
      }
      final shared = userData.sharePlaylist(call.userId, playlistId, member);
      if (shared == null) return errorResponse(404, ErrorCodes.playlistNotFound, 'Playlist not found.');
      if (!shared) {
        return errorResponse(
          409,
          ErrorCodes.playlistMembersLimit,
          'A playlist can be shared with at most ${UserDataRules.maxPlaylistMembers} accounts.',
          {'limit': UserDataRules.maxPlaylistMembers},
        );
      }
      _dataChanged(call); // whom it is shared with
      remote.playlistInvitesChanged(member);
      return jsonResponse({'userId': member, 'shared': true});
    }),
    _Route('DELETE', '/api/me/playlists/{playlistId}/members/{userId}', Access.user, (call) {
      final playlistId = call.params['playlistId']!;
      final member = call.params['userId']!;
      final others = userData.playlistAccounts(call.userId, playlistId);
      if (!userData.unsharePlaylist(call.userId, playlistId, member)) {
        return errorResponse(404, ErrorCodes.playlistNotFound, 'Playlist not found.');
      }
      _dataChanged(call);
      others.forEach(remote.dataChanged); // the member's playlist goes; the others' list of members changes
      remote.playlistInvitesChanged(member);
      return jsonResponse({'userId': member, 'shared': false});
    }),
    _Route(
      'GET',
      '/api/me/playlist-invites',
      Access.user,
      (call) => jsonResponse([for (final invite in userData.playlistInvites(call.userId)) invite.toJson()]),
    ),
    _Route('POST', '/api/me/playlist-invites/{playlistId}', Access.user, (call) {
      final playlistId = call.params['playlistId']!;
      final joined = userData.joinPlaylist(call.userId, playlistId);
      if (joined == null) return errorResponse(404, ErrorCodes.playlistInviteNotFound, 'Invitation not found.');
      // The joining player has it from the answer; the account's other players and everyone else with it are told.
      remote.dataChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
      remote.playlistInvitesChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
      userData.playlistAccounts(call.userId, playlistId).forEach(remote.dataChanged);
      return jsonResponse(joined.toJson());
    }),
    _Route('DELETE', '/api/me/playlist-invites/{playlistId}', Access.user, (call) {
      final owner = userData.declinePlaylist(call.userId, call.params['playlistId']!);
      if (owner == null) return errorResponse(404, ErrorCodes.playlistInviteNotFound, 'Invitation not found.');
      remote.playlistInvitesChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
      remote.dataChanged(owner); // whom it is shared with
      return jsonResponse({'declined': true});
    }),
  ];

  /// Recommends an artist, an album or a track of the library to other accounts: `{ "kind", "itemId", "to": [account
  /// IDs], "note" }`. Each of them is told at once.
  Future<Response> _recommend(_Call call) async {
    final body = await call.jsonObject();
    final kind = RecommendationKind.parse(body?['kind']);
    if (kind == null) {
      return errorResponse(400, ErrorCodes.invalidItemType, 'The kind must be artist, album or track.');
    }
    final itemId = _text(body, 'itemId');
    final idError = UserDataRules.validateId(itemId);
    if (idError != null) return errorResponse(400, ErrorCodes.invalidId, idError);
    final inLibrary = switch (kind) {
      RecommendationKind.track => library.getTrack(itemId!) != null,
      RecommendationKind.album => library.getAlbum(itemId!) != null,
      RecommendationKind.artist => library.getArtist(itemId!) != null,
    };
    if (!inLibrary) return errorResponse(404, ErrorCodes.notFound, 'It is not in the library.');
    final note = RecommendationRules.cleanNote(_text(body, 'note') ?? '');
    if (note.length > RecommendationRules.maxNoteLength) {
      return errorResponse(
        400,
        ErrorCodes.recommendationNoteTooLong,
        'A note can be at most ${RecommendationRules.maxNoteLength} characters.',
        {'max': RecommendationRules.maxNoteLength},
      );
    }
    final to = body?['to'];
    final accounts = {for (final account in auth.getAccounts()) account.id};
    final recipients = to is List ? {...to.whereType<String>()} : const <String>{};
    if (to is! List ||
        recipients.length != to.length ||
        recipients.isEmpty ||
        recipients.length > RecommendationRules.maxRecipients ||
        recipients.any((id) => id == call.userId || !accounts.contains(id))) {
      return errorResponse(
        400,
        ErrorCodes.recommendationRecipientsInvalid,
        'Choose 1 to ${RecommendationRules.maxRecipients} other accounts of this server.',
        {'max': RecommendationRules.maxRecipients},
      );
    }
    // An account that blocked the sender never gets it; the sender isn't told.
    final open = [
      for (final to in recipients)
        if (!blocks.blocks(to, call.userId)) to,
    ];
    final ids = open.isEmpty ? const <String>[] : recommendations.send(call.userId, open, kind, itemId, note);
    open.forEach(remote.recommendationsChanged);
    return jsonResponse({'ids': ids});
  }

  /// Invites another account to a Blend, or accepts its invitation: `{ "with": account ID }`. Answers with the Blend as
  /// the caller now has it. An account that blocks the caller isn't told; the answer is the same, an invitation that
  /// waits ([BlendService]).
  Future<Response> _inviteToBlend(_Call call) async {
    final other = _text(await call.jsonObject(), 'with');
    if (other == null || other == call.userId || !auth.getAccounts().any((a) => a.id == other)) {
      return errorResponse(400, ErrorCodes.blendAccountInvalid, 'Choose another account of this server.');
    }
    final id = blends.invite(call.userId, other);
    if (id == null) {
      return errorResponse(
        409,
        ErrorCodes.blendsLimit,
        'An account can be in at most ${BlendRules.maxBlends} Blends.',
        {'limit': BlendRules.maxBlends},
      );
    }
    // An account that blocks the other doesn't hear of it.
    remote.blendsChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);
    if (!blocks.blocks(other, call.userId)) remote.blendsChanged(other);
    final blend = blends.of(call.userId).where((b) => b.id == id).firstOrNull;
    // One the caller blocks the other in isn't listed: it waits, as the caller sees it.
    final username = auth.getAccounts().firstWhere((a) => a.id == other).username;
    return jsonResponse((blend ?? Blend(id, AccountInfo(other, username), BlendState.inviting)).toJson());
  }

  /// The text field [key] of a request body; null when it is missing or not text.
  static String? _text(Map<Object?, Object?>? body, String key) => switch (body?[key]) {
    final String value => value,
    _ => null,
  };

  /// Why the body's `newPassword` can't be the new password (a 400 answer), or null when it can.
  static Response? _newPasswordProblem(Map<Object?, Object?>? body) {
    final replacement = _text(body, 'newPassword');
    if (replacement == null) {
      return errorResponse(400, ErrorCodes.credentialsRequired, 'The new password is required.');
    }
    final error = AuthService.validatePassword(replacement);
    return error == null ? null : violationResponse(error);
  }

  Future<Response> _setup(_Call call) async {
    final body = await call.jsonObject();
    final username = _text(body, 'username');
    final password = _text(body, 'password');
    final error = AuthService.validateCredentials(username, password);
    if (error != null) return violationResponse(error);

    const setUp = 'The server is already set up. Sign in instead.';
    if (auth.hasAnyUsers()) return errorResponse(409, ErrorCodes.alreadySetUp, setUp);
    final code = body?['setupCode'];
    if (!setupCode.matches(code is String ? code : null)) {
      return errorResponse(
        403,
        ErrorCodes.setupCodeWrong,
        'The setup code is missing or wrong. The server prints it in its log when it starts.',
      );
    }

    final result = await auth.createAdmin(username!, password!);
    return result == null ? errorResponse(409, ErrorCodes.alreadySetUp, setUp) : jsonResponse(result.toJson());
  }

  Future<Response> _login(_Call call) async {
    final body = await call.jsonObject();
    final username = body?['username'];
    final password = body?['password'];
    if (username is! String || username.trim().isEmpty || password is! String || password.isEmpty) {
      return errorResponse(400, ErrorCodes.credentialsRequired, 'Username and password are required.');
    }
    final result = await auth.login(username, password, rememberMe: body?['rememberMe'] == true);
    return result == null ? unauthorized(ErrorCodes.wrongCredentials) : jsonResponse(result.toJson());
  }

  Future<Response> _changePassword(_Call call) async {
    final body = await call.jsonObject();
    // A signed-in player's word is enough: the current password isn't asked for.
    if (_newPasswordProblem(body) case final refusal?) return refusal;
    final renewed = await auth.changePassword(call.principal!, _text(body, 'newPassword')!);
    if (renewed == null) return errorResponse(404, ErrorCodes.userNotFound, 'User not found.');
    // The account's open remote-control connections were signed in with the old password; this player reconnects with
    // the token it gets here.
    remote.disconnectAccount(call.userId, 'The password changed.');
    return jsonResponse({'changed': true, ...renewed.toJson()});
  }

  /// The caller changes its own name: an administrator always, another account when the server lets members.
  Future<Response> _changeUsername(_Call call) async {
    if (!call.principal!.isAdmin && !auth.membersCanRename) {
      return errorResponse(403, ErrorCodes.renameNotAllowed, 'On this server only the administrator can change names.');
    }
    return _rename(call, call.userId);
  }

  /// Gives the account [userId] the body's `username`: `{ "username" }`.
  Future<Response> _rename(_Call call, String userId) async {
    final username = _text(await call.jsonObject(), 'username');
    if (AuthService.validateUsername(username) case final violation?) return violationResponse(violation);
    final (:outcome, :user) = auth.rename(userId, username!);
    switch (outcome) {
      case RenameOutcome.noAccount:
        return errorResponse(404, ErrorCodes.userNotFound, 'User not found.');
      case RenameOutcome.taken:
        return errorResponse(409, ErrorCodes.usernameTaken, 'Username already taken.');
      case RenameOutcome.renamed:
        remote.renamed(userId, user!.username);
        return jsonResponse(user.toJson());
    }
  }

  /// What an administrator sets about the server.
  ServerConfigInfo get _config =>
      ServerConfigInfo(paths.musicFolder, membersCanRename: auth.membersCanRename, lookUpOnline: albumLookups.enabled);

  Future<Response> _adminResetPassword(_Call call) async {
    final userId = call.params['userId']!;
    // Resetting would sign the administrator out everywhere, this request's token included.
    if (userId == call.userId) {
      return errorResponse(400, ErrorCodes.cannotResetOwnPassword, 'Change your own password with Change password.');
    }
    final body = await call.jsonObject();
    if (_newPasswordProblem(body) case final refusal?) return refusal;
    if (!await auth.resetPassword(userId, _text(body, 'newPassword')!)) {
      return errorResponse(404, ErrorCodes.userNotFound, 'User not found.');
    }
    remote.disconnectAccount(userId, 'The password was reset.');
    return jsonResponse({'changed': true});
  }

  Future<Response> _addUser(_Call call) async {
    final body = await call.jsonObject();
    final username = _text(body, 'username');
    final password = _text(body, 'password');
    final error = AuthService.validateCredentials(username, password);
    if (error != null) return violationResponse(error);
    final user = await auth.register(username!, password!);
    return user == null
        ? errorResponse(409, ErrorCodes.usernameTaken, 'Username already taken.')
        : jsonResponse(user.toJson());
  }

  Future<Response> _setMusicFolder(_Call call) async {
    final body = await call.jsonObject();
    final folder = body?['musicFolder'];
    if (folder is! String || folder.trim().isEmpty) {
      return errorResponse(400, ErrorCodes.folderRequired, 'The folder path must not be empty.');
    }

    final String fullPath;
    try {
      fullPath = AppPaths.fullPath(folder.trim());
    } catch (_) {
      return errorResponse(400, ErrorCodes.folderInvalid, 'The folder path is not valid.');
    }
    if (!Directory(fullPath).existsSync()) {
      return errorResponse(400, ErrorCodes.folderMissing, 'The folder does not exist: $fullPath', {'path': fullPath});
    }
    final problem = _musicFolderProblem(fullPath);
    if (problem != null) return violationResponse(problem);

    repository.setSetting(_chosenMusicFolderKey, fullPath);
    paths.musicFolder = fullPath;
    scanner.requestScan();
    return jsonResponse(_config.toJson());
  }

  /// Why the existing folder [fullPath] cannot be the music folder, or null. It must not be a whole disk or a system's
  /// virtual file system (a scan of either never ends), nor hold or lie inside the server's own data. Judged by where
  /// symbolic links lead, so a link cannot dress one up as an ordinary folder.
  RuleViolation? _musicFolderProblem(String fullPath) {
    final String real;
    try {
      real = AppPaths.fullPath(Directory(fullPath).resolveSymbolicLinksSync());
    } on FileSystemException {
      return RuleViolation(ErrorCodes.folderUnreadable, 'The folder cannot be read: $fullPath', {'path': fullPath});
    }
    if (p.rootPrefix(real) == real || p.dirname(real) == real) {
      return const RuleViolation(ErrorCodes.folderWholeDisk, 'A whole disk cannot be the music folder.');
    }
    const virtualRoots = ['/proc', '/sys', '/dev', '/run'];
    if (!Platform.isWindows && virtualRoots.any((root) => AppPaths.isPathUnderRoot(real, root))) {
      return const RuleViolation(ErrorCodes.folderSystem, 'A system folder cannot be the music folder.');
    }
    if (AppPaths.isPathUnderRoot(real, paths.dataDirectory) || AppPaths.isPathUnderRoot(paths.dataDirectory, real)) {
      return const RuleViolation(
        ErrorCodes.folderServerData,
        "The music folder cannot hold or lie inside the server's data folder.",
      );
    }
    return null;
  }

  /// The track's audio file, with range support; 404 when there is no such track or its file is gone. With `format`
  /// and `bitrate` in the query, the track as they ask, when the server can make it and it would be lighter than the
  /// file: else the file itself, so a player always gets something to play.
  Future<Response> _stream(_Call call) async {
    final request = call.request;
    final track = library.getTrack(call.params['trackId']!);
    if (track == null ||
        !AppPaths.isPathUnderRoot(track.filePath, paths.musicFolder) ||
        !File(track.filePath).existsSync()) {
      return errorResponse(404, ErrorCodes.notFound, 'Track not found.');
    }
    final query = request.url.queryParameters;
    final convert = TranscodeRequest.parse(query['format'], query['bitrate']);
    if (convert != null && !convert.isPointlessFor(track)) {
      final converted = await transcoder.convert(track, convert);
      if (converted != null) return fileResponse(request, converted, convert.format.mimeType);
    }
    return fileResponse(request, File(track.filePath), AudioFileTypes.mimeType(track.filePath));
  }

  JsonDocument get _tracks => _trackList ??= _listTracks();

  /// Each track as [Track.toJson] gives it, with the genre and the label its album was looked up for when its file
  /// names none ([albumLookups]), and with a cover the version of the album's cover, which the players put in its
  /// address: a changed cover gets a new one, and a player shows it at once.
  JsonDocument _listTracks() {
    final coverVersions = <String, String?>{};
    Map<String, Object?> json(Track track) {
      final facts = albumLookups.of(track.albumId);
      final details = facts?.label != null && track.details.label == null
          ? track.details.withLabel(facts!.label)
          : track.details;
      return {
        ...track.toJson(),
        if ((track.genre ?? '').isEmpty && facts?.genre != null) 'genre': facts!.genre,
        if (!details.isEmpty) 'details': details.toJson(),
        if (track.hasCoverArt)
          'coverVersion': coverVersions.putIfAbsent(track.albumId, () => _coverVersion(track.albumId)),
      };
    }

    final text = jsonEncode([for (final track in library.tracks) json(track)]);
    return JsonDocument(utf8.encode(text));
  }

  /// Changes with what [_cover] serves for the album: the size and time of the cover's file, or of the audio file
  /// when the picture is read from that.
  String? _coverVersion(String albumId) {
    final track = _coverTrack(albumId);
    if (track == null) return null;
    final cover = track.coverArtPath;
    return _fileVersion(cover != null && cover.isNotEmpty ? cover : track.filePath);
  }

  /// The size and time of the file at [path]; null when there is none.
  static String? _fileVersion(String path) {
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.size.toRadixString(36)}-${stat.modified.millisecondsSinceEpoch.toRadixString(36)}';
  }

  JsonDocument get _artistPictures => _artistPictureList ??= JsonDocument(
    utf8.encode(
      jsonEncode({
        for (final MapEntry(key: id, value: path) in library.artistPictureFiles.entries) id: ?_fileVersion(path),
      }),
    ),
  );

  /// The version of both lists the players download, which a scan may change.
  Future<String> _libraryVersion() async => '${await _tracks.etag}${await _artistPictures.etag}';

  /// The track whose picture is the album's cover.
  Track? _coverTrack(String albumId) => library.getAlbum(albumId)?.tracks.where((t) => t.hasCoverArt).firstOrNull;

  /// A scan found files that were moved or renamed: what the accounts have on them goes to the new track IDs, and the
  /// players of those accounts download it again.
  void _tracksMoved(Map<String, String> moved) {
    try {
      final accounts = userData.moveTracks(moved);
      WiretuneLog.info(
        'Server',
        '${moved.length} moved files; the data of ${accounts.length} accounts went with them.',
      );
      accounts.forEach(remote.dataChanged);
    } catch (e, s) {
      WiretuneLog.error('Server', 'Could not move the accounts\' data to the moved files: $e', e, s);
    }
  }

  /// A scan ended: when the lists the players get changed, they are told; the albums not looked up yet are.
  Future<void> _scanned() async {
    _artistPictureList = null;
    await _tracksChanged();
    _lookUpAlbums();
  }

  /// Looks up the albums not looked up yet, in the background.
  void _lookUpAlbums() => unawaited(albumLookups.run(library.albums, onLearned: () => unawaited(_tracksChanged())));

  /// The track list is made again; when it changed, the players are told.
  Future<void> _tracksChanged() async {
    _trackList = null;
    final version = await _libraryVersion();
    if (version == _announcedLibrary) return;
    _announcedLibrary = version;
    remote.libraryChanged();
  }

  Future<Response> _cover(Request request, Track? track) async {
    if (track == null || !AppPaths.isPathUnderRoot(track.filePath, paths.musicFolder)) return notFound();
    const cache = {'cache-control': 'private, max-age=86400'};

    final coverPath = track.coverArtPath;
    if (coverPath != null &&
        coverPath.isNotEmpty &&
        File(coverPath).existsSync() &&
        (AppPaths.isPathUnderRoot(coverPath, paths.coverCacheDirectory) ||
            AppPaths.isPathUnderRoot(coverPath, paths.musicFolder))) {
      return fileResponse(request, File(coverPath), ImageFormat.mimeTypeFromPath(coverPath), headers: cache);
    }

    final bytes = File(track.filePath).existsSync() ? await MetadataScanner.extractCoverArt(track.filePath) : null;
    if (bytes == null || bytes.isEmpty) return notFound();
    return Response.ok(bytes, headers: {...cache, 'content-type': ImageFormat.mimeType(bytes)});
  }

  /// An artist's own picture (`artist.jpg` in the music folder).
  Future<Response> _artistPicture(_Call call) async {
    final path = library.artistPictureFiles[call.params['artistId']!];
    if (path == null || !AppPaths.isPathUnderRoot(path, paths.musicFolder) || !File(path).existsSync()) {
      return notFound();
    }
    return fileResponse(
      call.request,
      File(path),
      ImageFormat.mimeTypeFromPath(path),
      headers: {'cache-control': 'private, max-age=86400'},
    );
  }

  /// Upgrades the request to a WebSocket and hands it to the hub. The sign-in token comes in the header like on every
  /// other route (never in the URL), and a request from a web page (which carries an `Origin`) is turned away: no page
  /// has business controlling the players, and a browser lets any page open a WebSocket to any address.
  Response _remote(_Call call) {
    final request = call.request;
    final headers = request.headers;
    final connection = headers['connection']?.toLowerCase().split(',').map((t) => t.trim()) ?? const [];
    if (headers['upgrade']?.toLowerCase() != 'websocket' || !connection.contains('upgrade')) {
      return errorResponse(
        426,
        ErrorCodes.notWebSocket,
        'This route speaks WebSocket only.',
      ).change(headers: {'upgrade': 'websocket', 'connection': 'Upgrade'});
    }
    if (headers.containsKey('origin')) {
      return errorResponse(403, ErrorCodes.originRefused, 'Web pages cannot control the players.');
    }
    final key = headers['sec-websocket-key'];
    if (key == null || key.trim().isEmpty || headers['sec-websocket-version'] != '13') {
      return errorResponse(400, ErrorCodes.notWebSocket, 'This is not a valid WebSocket handshake.');
    }

    final principal = call.principal!;
    if (!remote.canJoin(principal.userId)) {
      return errorResponse(429, ErrorCodes.tooManyConnections, 'Too many connections for this account.');
    }
    request.hijack((channel) {
      final socket = channel.sink as Socket;
      final accept = base64.encode(sha1.convert(utf8.encode('${key.trim()}$_webSocketGuid')).bytes);
      socket.add(
        utf8.encode(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        ),
      );
      remote.join(
        WebSocket.fromUpgradedSocket(socket, serverSide: true),
        principal,
        network: RemoteHub.networkOf(_clientAddress(request)),
      );
    });
  }

  /// RFC 6455's constant for the handshake's accept key.
  static const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  Future<Response> _lyrics(_Call call) async {
    final track = library.getTrack(call.params['trackId']!);
    if (track == null || !AppPaths.isPathUnderRoot(track.filePath, paths.musicFolder)) return notFound();
    final lyrics = await MetadataScanner.readLyrics(track.filePath);
    return lyrics == null ? notFound() : jsonResponse({'lyrics': lyrics});
  }

  /// Tells the account's other players (not the one that names itself in [RemoteRules.deviceHeader]) that its data
  /// changed. Play counts aren't announced: they change with every track and nothing shows them at once.
  void _dataChanged(_Call call) =>
      remote.dataChanged(call.userId, except: call.request.headers[RemoteRules.deviceHeader]);

  Response _favorite(_Call call, bool favorite) {
    final trackId = call.params['trackId']!;
    final error = UserDataRules.validateId(trackId);
    if (error != null) return errorResponse(400, ErrorCodes.invalidId, error);
    if (!userData.setFavorite(call.userId, trackId, favorite)) {
      return errorResponse(
        409,
        ErrorCodes.favoritesLimit,
        'An account can have at most ${UserDataRules.maxFavorites} favourites.',
        {'limit': UserDataRules.maxFavorites},
      );
    }
    _dataChanged(call);
    return jsonResponse({'trackId': trackId, 'isFavorite': favorite});
  }

  Response _setHidden(_Call call, bool hidden) {
    final type = call.params['type']!;
    final itemId = call.params['itemId']!;
    final kind = HiddenKind.parse(type);
    if (kind == null) {
      return errorResponse(
        400,
        ErrorCodes.invalidItemType,
        'Invalid item type: $type. Must be artist, album, or track.',
      );
    }
    final error = UserDataRules.validateId(itemId);
    if (error != null) return errorResponse(400, ErrorCodes.invalidId, error);
    if (!userData.setHidden(call.userId, kind, itemId, hidden)) {
      return errorResponse(
        409,
        ErrorCodes.hiddenLimit,
        'An account can have at most ${UserDataRules.maxHidden} hidden items.',
        {'limit': UserDataRules.maxHidden},
      );
    }
    _dataChanged(call);
    return jsonResponse({'itemType': kind.name, 'itemId': itemId, 'hidden': hidden});
  }

  Future<Response> _savePlaylist(_Call call) async {
    final playlistId = call.params['playlistId']!;
    final body = await call.jsonObject();
    PlaylistUpdate? update;
    try {
      update = body == null ? null : PlaylistUpdate.fromJson(body);
    } on FormatException {
      return errorResponse(400, ErrorCodes.playlistInvalid, 'The playlist is not valid.');
    }
    final error = UserDataService.validatePlaylist(playlistId, update);
    if (error != null) return violationResponse(error);

    final saved = userData.savePlaylist(call.userId, playlistId, update!);
    if (saved == null) {
      return errorResponse(
        409,
        ErrorCodes.playlistsLimit,
        'An account can have at most ${UserDataRules.maxPlaylists} playlists.',
        {'limit': UserDataRules.maxPlaylists},
      );
    }
    _dataChanged(call);
    userData.playlistAccounts(call.userId, playlistId).forEach(remote.dataChanged); // a shared one's
    return jsonResponse(saved.toJson());
  }
}
