// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:wiretune_core/testing.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

export 'package:wiretune_core/testing.dart';

const adminPassword = 'correct-horse-battery';
const guestPassword = 'guest-password';
const setupCode = 'test-setup-code';

/// A real server on a free port, over a generated music folder; one per test (setup works once per server).
class ServerFixture {
  ServerFixture._(this.root, this.server, this._ownsRoot);

  final String root;
  final WiretuneServer server;
  final bool _ownsRoot;

  /// Leaves the files behind on [close], e.g. to start a second server on the same data ("restart").
  bool keepFiles = false;

  String get libraryPath => p.join(root, 'library');
  String get dataPath => p.join(root, 'data');
  String get baseUrl => 'http://127.0.0.1:${server.port}';

  /// [existingRoot] reuses the folders of an earlier fixture (a restart); null creates fresh ones.
  static Future<ServerFixture> start({String? existingRoot, bool trustProxy = false}) async {
    WiretuneLog.writeToConsole = false;
    final root = existingRoot ?? Directory.systemTemp.createTempSync('wiretune_server_').path;
    if (existingRoot == null) {
      writeWav(p.join(root, 'library', 'Artist A', 'Album 1', '01 First.wav'), 44100);
      writeWav(p.join(root, 'library', 'Artist A', 'Album 1', '02 Second.wav'), 44100);
      writeWav(p.join(root, 'library', 'Artist B', 'Album 2', '01 Third.wav'), 96000);
      // A sibling folder whose name shares the library prefix must never be reachable.
      writeWav(p.join(root, 'library2', 'Outside.wav'), 44100);
    }
    final server = await WiretuneServer.start(
      ServerOptions(
        libraryPath: p.join(root, 'library'),
        dataDirectory: p.join(root, 'data'),
        scanIntervalMinutes: 0,
        setupCode: setupCode,
        host: '127.0.0.1',
        port: 0,
        trustProxy: trustProxy,
      ),
    );
    return ServerFixture._(root, server, existingRoot == null);
  }

  Api client([String? token]) => Api(baseUrl, token);

  Future<List<Map<String, dynamic>>> waitForTracks(Api client, int expected) async {
    for (var i = 0; i < 100; i++) {
      final response = await client.get('/api/tracks');
      final tracks = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      if (tracks.length == expected) return tracks;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('The server did not finish its scan.');
  }

  Future<void> close() async {
    await server.close();
    if (_ownsRoot && !keepFiles) {
      try {
        Directory(root).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// A small HTTP client for the API: JSON bodies, an optional bearer token.
class Api {
  Api(this.baseUrl, [this.token]);

  final String baseUrl;
  String? token;
  final http.Client _http = http.Client();

  Map<String, String> _headers(Map<String, String>? extra) => {
    if (token != null) 'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
    ...?extra,
  };

  Future<http.Response> get(String path, {Map<String, String>? headers}) =>
      _http.get(Uri.parse('$baseUrl$path'), headers: _headers(headers));

  Future<http.Response> post(String path, [Object? body]) =>
      _http.post(Uri.parse('$baseUrl$path'), headers: _headers(null), body: body == null ? null : jsonEncode(body));

  Future<http.Response> put(String path, [Object? body]) =>
      _http.put(Uri.parse('$baseUrl$path'), headers: _headers(null), body: body == null ? null : jsonEncode(body));

  Future<http.Response> delete(String path) => _http.delete(Uri.parse('$baseUrl$path'), headers: _headers(null));

  Future<http.StreamedResponse> send(String method, String path, {Map<String, String>? headers}) {
    final request = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(_headers(headers));
    return _http.send(request);
  }
}

dynamic json(http.Response response) => jsonDecode(utf8.decode(response.bodyBytes));

Future<(Api, AuthResponse)> setupAdmin(ServerFixture server) async {
  final client = server.client();
  final response = await client.post('/api/auth/setup', {
    'username': 'owner',
    'password': adminPassword,
    'setupCode': setupCode,
  });
  if (response.statusCode != 200) throw StateError('setup failed: ${response.statusCode} ${response.body}');
  final auth = AuthResponse.fromJson(json(response));
  client.token = auth.token;
  return (client, auth);
}

Future<(Api, AuthResponse)> login(
  ServerFixture server,
  String username,
  String password, {
  bool rememberMe = false,
}) async {
  final client = server.client();
  final response = await client.post('/api/auth/login', {
    'username': username,
    'password': password,
    'rememberMe': rememberMe,
  });
  if (response.statusCode != 200) throw StateError('login failed: ${response.statusCode}');
  final auth = AuthResponse.fromJson(json(response));
  client.token = auth.token;
  return (client, auth);
}

/// Creates a regular account through the admin's client and returns a client signed in as it.
Future<(Api, UserInfo)> registerGuest(ServerFixture server, Api admin, [String username = 'guest']) async {
  final created = await admin.post('/api/auth/register', {'username': username, 'password': guestPassword});
  if (created.statusCode != 200) throw StateError('register failed: ${created.statusCode}');
  final user = UserInfo.fromJson(json(created));
  final (client, _) = await login(server, username, guestPassword);
  return (client, user);
}
