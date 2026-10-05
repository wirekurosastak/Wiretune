// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../models/protocol.dart';

/// The server rejected the credentials (HTTP 401).
class ServerUnauthorizedException implements Exception {
  const ServerUnauthorizedException();

  @override
  String toString() => 'The server rejected the credentials.';
}

/// A server call failed. [statusCode] is null when no answer arrived (unreachable, timed out, connection cut).
class ServerRequestException implements Exception {
  const ServerRequestException(this.message, [this.statusCode]);

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Thin typed HTTP client for the Wiretune server REST API.
class ServerStreamingClient {
  ServerStreamingClient([http.Client? client]) : _ownsClient = client == null, _http = client ?? http.Client();

  static const Duration probeTimeout = Duration(seconds: 15); // initial reachability check
  static const Duration defaultTimeout = Duration(seconds: 30); // normal API calls
  static const Duration libraryTimeout = Duration(minutes: 3); // large library fetch

  final http.Client _http;
  final bool _ownsClient;

  String? authToken;

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

  Future<ServerConfigInfo> getServerConfig(String baseUrl) async =>
      _parse(ServerConfigInfo.fromJson, await _send('GET', baseUrl, '/api/config'));

  Future<ServerConfigInfo> updateServerLibraryPath(String baseUrl, String newPath) async => _parse(
    ServerConfigInfo.fromJson,
    await _send('POST', baseUrl, '/api/config/library-path', body: {'newPath': newPath}),
  );

  Future<void> triggerScan(String baseUrl) => _send('POST', baseUrl, '/api/library/scan');

  // ── The signed-in account's favourites, play statistics and playlists ──

  /// Everything the server keeps for the account: favourites, play statistics and playlists.
  Future<UserDataSnapshot> getUserData(String baseUrl) async =>
      _parse(UserDataSnapshot.fromJson, await _send('GET', baseUrl, '/api/me/data'));

  Future<void> setFavorite(String baseUrl, String trackId, bool favorite) =>
      _send(favorite ? 'PUT' : 'DELETE', baseUrl, '/api/me/favorites/${Uri.encodeComponent(trackId)}');

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
    final tracks = <Track>[];
    for (final item in list) {
      final track = _parse(Track.fromJson, item);
      track.streamUrl = buildStreamUrl(baseUrl, track.id);
      track.coverArtPath = track.hasCoverArt ? buildAlbumCoverUrl(baseUrl, track.albumId) : null;
      tracks.add(track);
    }
    return tracks;
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

    if (response.statusCode == 401) throw const ServerUnauthorizedException();
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw ServerRequestException(_errorMessage(response, bytes), response.statusCode);
    }

    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw ServerRequestException(_notWiretune(), response.statusCode);
    }
  }

  static String _errorMessage(http.StreamedResponse response, List<int> bytes) {
    try {
      final element = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (element is Map && element['error'] is String) return element['error'] as String;
    } catch (_) {
      // Not a JSON error body.
    }
    return 'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}'.trim();
  }

  void close() {
    if (_ownsClient) _http.close();
  }
}
