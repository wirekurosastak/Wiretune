// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../localization/localizer.dart';
import '../localization/strings.dart';
import '../models/library_models.dart';
import '../models/protocol.dart';
import '../models/remote.dart';

/// The server rejected the credentials (HTTP 401). [token] is the sign-in token the request carried, if any, and
/// [code] why ([ErrorCodes]: none sent, expired, the password changed, the account removed …).
class ServerUnauthorizedException implements Exception {
  const ServerUnauthorizedException([this.token, this.code]);

  final String? token;
  final String? code;

  @override
  String toString() => describeServerError(code) ?? Localizer.get('ErrorSignInRequired');
}

/// A server call failed. [statusCode] is null when no answer arrived (unreachable, timed out, connection cut). The
/// [message] is in the user's language when the server's [code] ([ErrorCodes]) is one this player knows.
class ServerRequestException implements Exception {
  const ServerRequestException(this.message, [this.statusCode, this.code]);

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}

/// The text in the user's language for an error [code] of the server ([ErrorCodes]), with the one detail it names
/// ([detail]: a path, a limit, a number of seconds); null for a code this player doesn't know.
String? describeServerError(String? code, [Object? detail]) {
  if (code == null || code.isEmpty) return null;
  final key = 'Error${code[0].toUpperCase()}${code.substring(1)}';
  return allStrings.containsKey(key) ? Localizer.format(key, [?detail]) : null;
}

/// Thin typed HTTP client for the Wiretune server REST API.
class ServerClient {
  ServerClient([http.Client? client]) : _ownsClient = client == null, _http = client ?? http.Client();

  static const Duration probeTimeout = Duration(seconds: 15); // initial reachability check
  static const Duration defaultTimeout = Duration(seconds: 30); // normal API calls
  static const Duration libraryTimeout = Duration(minutes: 3); // large library fetch

  final http.Client _http;
  final bool _ownsClient;

  String? authToken;

  /// This player's remote-control device ID, sent with each request ([RemoteRules.deviceHeader]): the server then tells
  /// the account's other players of the changes it makes, and not this one.
  String? deviceId;

  static String _notWiretune() => Localizer.get('ClientNotWiretune');

  static String _base(String baseUrl) => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  static String buildStreamUrl(String baseUrl, String trackId) =>
      '${_base(baseUrl)}/api/stream/${Uri.encodeComponent(trackId)}';

  /// The cover of a whole album, so that the tracks of one album share one image (and one download).
  static String buildAlbumCoverUrl(String baseUrl, String albumId) =>
      '${_base(baseUrl)}/api/cover/album/${Uri.encodeComponent(albumId)}';

  Future<bool> checkSetupRequired(String baseUrl) async {
    final element = await _send('GET', baseUrl, '/api/auth/setup-required', authorize: false, timeout: probeTimeout);
    if (element is! Map || element['setupRequired'] is! bool) throw ServerRequestException(_notWiretune(), 200);
    return element['setupRequired'] as bool;
  }

  Future<AuthResponse> setupAdmin(String baseUrl, String username, String password, [String? setupCode]) async =>
      _parse(
        AuthResponse.fromJson,
        await _send(
          'POST',
          baseUrl,
          '/api/auth/setup',
          body: {'username': username, 'password': password, 'setupCode': setupCode?.trim()},
          authorize: false,
        ),
      );

  Future<AuthResponse> login(String baseUrl, String username, String password, bool rememberMe) async => _parse(
    AuthResponse.fromJson,
    await _send(
      'POST',
      baseUrl,
      '/api/auth/login',
      body: {'username': username, 'password': password, 'rememberMe': rememberMe},
      authorize: false,
    ),
  );

  /// A short-lived token that opens only the audio and cover routes, for use in stream URLs.
  Future<StreamTokenResponse> getStreamToken(String baseUrl) async =>
      _parse(StreamTokenResponse.fromJson, await _send('POST', baseUrl, '/api/auth/stream-token'));

  Future<UserInfo> getCurrentUser(String baseUrl) async =>
      _parse(UserInfo.fromJson, await _send('GET', baseUrl, '/api/auth/me'));

  Future<ServerLibraryStatus> getLibraryStatus(String baseUrl) async =>
      _parse(ServerLibraryStatus.fromJson, await _send('GET', baseUrl, '/api/library/status'));

  Future<List<UserInfo>> getUsers(String baseUrl) async {
    final list = await _send('GET', baseUrl, '/api/users');
    if (list is! List) throw ServerRequestException(_notWiretune(), 200);
    return list.map((u) => _parse(UserInfo.fromJson, u)).toList();
  }

  Future<UserInfo> registerUser(String baseUrl, String username, String password) async => _parse(
    UserInfo.fromJson,
    await _send('POST', baseUrl, '/api/auth/register', body: {'username': username, 'password': password}),
  );

  Future<void> deleteUser(String baseUrl, String userId) =>
      _send('DELETE', baseUrl, '/api/users/${Uri.encodeComponent(userId)}');

  /// Changes the signed-in account's password. The server ends the sessions signed in with the old one and answers
  /// with a new token for this one.
  Future<AuthResponse> changePassword(String baseUrl, String currentPassword, String newPassword) async => _parse(
    AuthResponse.fromJson,
    await _send(
      'POST',
      baseUrl,
      '/api/auth/change-password',
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    ),
  );

  Future<void> adminResetPassword(String baseUrl, String userId, String newPassword) =>
      _send('POST', baseUrl, '/api/users/${Uri.encodeComponent(userId)}/password', body: {'newPassword': newPassword});

  Future<ServerConfigInfo> getServerConfig(String baseUrl) async =>
      _parse(ServerConfigInfo.fromJson, await _send('GET', baseUrl, '/api/config'));

  Future<ServerConfigInfo> saveServerFolder(String baseUrl, String folder) async => _parse(
    ServerConfigInfo.fromJson,
    await _send('POST', baseUrl, '/api/config/music-folder', body: {'musicFolder': folder}),
  );

  Future<void> triggerScan(String baseUrl) => _send('POST', baseUrl, '/api/library/scan');

  // ── The signed-in account's favourites, play statistics and playlists ──

  /// Everything the server keeps for the account: favourites, play statistics and playlists.
  Future<UserDataSnapshot> getUserData(String baseUrl) async =>
      _parse(UserDataSnapshot.fromJson, await _send('GET', baseUrl, '/api/me/data'));

  Future<void> setFavorite(String baseUrl, String trackId, bool favorite) =>
      _send(favorite ? 'PUT' : 'DELETE', baseUrl, '/api/me/favorites/${Uri.encodeComponent(trackId)}');

  Future<void> setHidden(String baseUrl, HiddenKind kind, String id, bool hidden) =>
      _send(hidden ? 'PUT' : 'DELETE', baseUrl, '/api/me/hidden/${kind.name}/${Uri.encodeComponent(id)}');

  Future<TrackPlayStats> recordPlay(String baseUrl, String trackId) async =>
      _parse(TrackPlayStats.fromJson, await _send('POST', baseUrl, '/api/me/plays/${Uri.encodeComponent(trackId)}'));

  /// Creates or replaces a playlist of the account with the given one.
  Future<void> savePlaylist(String baseUrl, Playlist playlist) => _send(
    'PUT',
    baseUrl,
    '/api/me/playlists/${Uri.encodeComponent(playlist.id)}',
    body: PlaylistUpdate(playlist.name, playlist.description, List.of(playlist.trackIds)).toJson(),
  );

  /// Deletes a playlist of the account; one the server no longer has counts as deleted.
  Future<void> deletePlaylist(String baseUrl, String playlistId) async {
    try {
      await _send('DELETE', baseUrl, '/api/me/playlists/${Uri.encodeComponent(playlistId)}');
    } on ServerRequestException catch (e) {
      if (e.statusCode != 404) rethrow; // already gone otherwise
    }
  }

  /// The lyrics of a server track, or null when it has none.
  Future<String?> getLyrics(String baseUrl, String trackId) async {
    try {
      final element = await _send('GET', baseUrl, '/api/lyrics/${Uri.encodeComponent(trackId)}');
      return element is Map && element['lyrics'] is String ? element['lyrics'] as String : null;
    } on ServerRequestException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Fetches the server library. Stream and cover URLs are token-free; authorisation is added at playback time. The
  /// tracks of an album point to the album's cover, so each cover is downloaded and cached once, not once per track.
  Future<List<Track>> fetchTracks(String baseUrl) async {
    final list = await _send('GET', baseUrl, '/api/tracks', timeout: libraryTimeout);
    if (list is! List) throw ServerRequestException(_notWiretune(), 200);
    return [for (final item in list) serverTrack(baseUrl, item)];
  }

  /// A track of the server's listing ([Track.toJson]'s form), with its stream and cover URLs.
  Track serverTrack(String baseUrl, Object? json) {
    final track = _parse(Track.fromJson, json);
    track.streamUrl = buildStreamUrl(baseUrl, track.id);
    track.coverArtPath = track.hasCoverArt ? buildAlbumCoverUrl(baseUrl, track.albumId) : null;
    return track;
  }

  static T _parse<T>(T Function(Object?) parse, Object? json) {
    if (json == null) throw ServerRequestException(Localizer.get('ClientEmptyResponse'), 200);
    try {
      return parse(json);
    } on FormatException {
      throw ServerRequestException(_notWiretune(), 200);
    } on TypeError {
      throw ServerRequestException(_notWiretune(), 200);
    }
  }

  /// Sends one request and returns the decoded JSON body (null for an empty one). Every failure becomes a
  /// [ServerUnauthorizedException] or a [ServerRequestException].
  Future<Object?> _send(
    String method,
    String baseUrl,
    String path, {
    Object? body,
    bool authorize = true,
    Duration timeout = defaultTimeout,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(_base(baseUrl) + path);
    } on FormatException catch (e) {
      throw ServerRequestException(e.message);
    }

    final request = http.Request(method, uri)..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final token = authToken;
    if (authorize && token != null && token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    final device = deviceId;
    if (authorize && device != null && device.isNotEmpty) request.headers[RemoteRules.deviceHeader] = device;

    final deadline = DateTime.now().add(timeout);
    http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw ServerRequestException(Localizer.format('ClientTimeout', [timeout.inSeconds]));
    } on SocketException catch (e) {
      throw ServerRequestException(
        e.osError?.message.isNotEmpty == true ? '${e.message}: ${e.osError!.message}' : e.message,
      );
    } on HandshakeException catch (e) {
      throw ServerRequestException(e.message);
    } on http.ClientException catch (e) {
      throw ServerRequestException(e.message);
    } on HttpException catch (e) {
      throw ServerRequestException(e.message);
    }

    List<int> bytes;
    try {
      final remaining = deadline.difference(DateTime.now());
      bytes = await response.stream.toBytes().timeout(remaining.isNegative ? Duration.zero : remaining);
    } on TimeoutException {
      throw ServerRequestException(Localizer.format('ClientBodyTimeout', [timeout.inSeconds]));
    } on Exception catch (e) {
      // The connection dropped after the headers arrived, e.g. a server restart in the middle of the library download.
      throw ServerRequestException(Localizer.format('ClientConnectionCutOff', ['$e']));
    }

    if (response.statusCode == 401) {
      throw ServerUnauthorizedException(authorize ? token : null, _errorBody(bytes)?['code'] as String?);
    }
    if (response.statusCode < 200 || response.statusCode > 299) {
      final (message, code) = _error(response, bytes);
      throw ServerRequestException(message, response.statusCode, code);
    }

    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw ServerRequestException(_notWiretune(), response.statusCode);
    }
  }

  /// What went wrong, as the user should read it, and the server's code for it: the code's text in the user's
  /// language, else the server's own text, else the HTTP status.
  static (String, String?) _error(http.StreamedResponse response, List<int> bytes) {
    final body = _errorBody(bytes);
    final code = body?['code'] is String ? body!['code'] as String : null;
    final detail = body?['path'] ?? body?['limit'] ?? body?['max'] ?? body?['min'] ?? body?['retryAfter'];
    final message =
        describeServerError(code, detail) ??
        (body?['error'] is String ? body!['error'] as String : null) ??
        'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'.trim();
    return (message, code);
  }

  /// The JSON object of an error answer (`{ "error", "code", … }`), or null.
  static Map<Object?, Object?>? _errorBody(List<int> bytes) {
    try {
      final element = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return element is Map ? element : null;
    } catch (_) {
      return null; // not a JSON error body
    }
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
