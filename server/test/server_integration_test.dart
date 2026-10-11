// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// One server instance per test (setup can only run once per server), so the tests stay independent.
void main() {
  late ServerFixture server;

  setUp(() async => server = await ServerFixture.start());
  tearDown(() async => server.close());

  test('first run requires setup and has no default administrator', () async {
    final client = server.client();
    expect(json(await client.get('/api/auth/setup-required'))['setupRequired'], isTrue);
    expect((await client.post('/api/auth/login', {'username': 'admin', 'password': 'admin'})).statusCode, 401);
  });

  test('setup rejects a weak password and succeeds exactly once under concurrency', () async {
    final client = server.client();
    expect(
      (await client.post('/api/auth/setup', {
        'username': 'owner',
        'password': 'short',
        'setupCode': setupCode,
      })).statusCode,
      400,
    );

    final attempts = await Future.wait([
      for (var i = 0; i < 5; i++)
        client.post('/api/auth/setup', {'username': 'owner$i', 'password': adminPassword, 'setupCode': setupCode}),
    ]);
    expect(attempts.where((r) => r.statusCode == 200), hasLength(1));
    expect(attempts.where((r) => r.statusCode == 409), hasLength(4));
  });

  test('the token opens the library, and /me returns the full account', () async {
    expect((await server.client().get('/api/tracks')).statusCode, 401);

    final (client, auth) = await setupAdmin(server);
    expect(auth.user.isAdmin, isTrue);

    final me = UserInfo.fromJson(json(await client.get('/api/auth/me')));
    expect(me.username, 'owner');
    expect(me.isAdmin, isTrue);

    final tracks = await server.waitForTracks(client, 3);
    expect(tracks.any((t) => t['format']['sampleRate'] == 96000), isTrue);
    expect(tracks.any((t) => t['title'] == 'Outside'), isFalse);
    expect(tracks.first['durationMs'], 1000);
  });

  test('streaming supports ranges, the header and the query token', () async {
    final (client, _) = await setupAdmin(server);
    final track = (await server.waitForTracks(client, 3)).first;

    final partial = await client.send('GET', '/api/stream/${track['id']}', headers: {'Range': 'bytes=0-1023'});
    final bytes = await partial.stream.toBytes();
    expect(partial.statusCode, 206);
    expect(bytes, hasLength(1024));
    expect(partial.headers['content-type'], 'audio/wav');
    expect(partial.headers['content-range'], startsWith('bytes 0-1023/'));

    final suffix = await client.send('GET', '/api/stream/${track['id']}', headers: {'Range': 'bytes=-100'});
    expect((suffix.statusCode, (await suffix.stream.toBytes()).length), (206, 100));

    final unsatisfiable = await client.send(
      'GET',
      '/api/stream/${track['id']}',
      headers: {'Range': 'bytes=999999999-'},
    );
    expect(unsatisfiable.statusCode, 416);

    final stream = StreamTokenResponse.fromJson(json(await client.post('/api/auth/stream-token'))).token;
    final viaQuery = await server.client().get('/api/stream/${track['id']}?token=${Uri.encodeComponent(stream)}');
    expect(viaQuery.statusCode, 200);
    expect(viaQuery.bodyBytes.length, 44 + 44100 * 4);

    expect((await client.get('/api/stream/does-not-exist')).statusCode, 404);
  });

  test('streaming refuses files outside the library folder', () async {
    final (client, _) = await setupAdmin(server);
    await server.waitForTracks(client, 3);

    // Inject a track that points at a sibling folder sharing the root's name prefix ("library2").
    final outsidePath = p.join(server.root, 'library2', 'Outside.wav');
    final outside = Track(id: 'outside', title: 'Outside', filePath: outsidePath);
    await server.server.library.replaceTracks([...server.server.library.tracks, outside]);

    expect(File(outsidePath).existsSync(), isTrue);
    expect((await client.get('/api/stream/outside')).statusCode, 404);

    // A symlink inside the library pointing outside must also be refused.
    final symlinkPath = p.join(server.libraryPath, 'symlink_outside.wav');
    Link(symlinkPath).createSync(outsidePath);
    final symlinked = Track(id: 'symlinked', title: 'Symlinked', filePath: symlinkPath);
    await server.server.library.replaceTracks([...server.server.library.tracks, symlinked]);
    expect((await client.get('/api/stream/symlinked')).statusCode, 404);
  });

  test('the admin policy protects registration and scanning', () async {
    final (admin, _) = await setupAdmin(server);

    final register = await admin.post('/api/auth/register', {'username': 'guest', 'password': guestPassword});
    expect(register.statusCode, 200);
    expect(UserInfo.fromJson(json(register)).isAdmin, isFalse);
    expect((await admin.post('/api/auth/register', {'username': 'GUEST', 'password': guestPassword})).statusCode, 409);

    final (guest, _) = await login(server, 'Guest', guestPassword);
    expect((await guest.post('/api/library/scan')).statusCode, 403);
    expect((await guest.post('/api/auth/register', {'username': 'x', 'password': 'xxxxxxxxxx'})).statusCode, 403);
    expect((await guest.get('/api/users')).statusCode, 403);
    expect((await guest.get('/api/tracks')).statusCode, 200);

    final scan = await admin.post('/api/library/scan');
    expect(scan.statusCode, 202);
    expect(json(scan)['message'], 'Scan requested.');

    expect(
      (await server.client().post('/api/auth/login', {'username': 'guest', 'password': 'not-the-password'})).statusCode,
      401,
    );
  });

  test('a deleted user loses access at once', () async {
    final (admin, _) = await setupAdmin(server);
    final created = UserInfo.fromJson(
      json(await admin.post('/api/auth/register', {'username': 'guest', 'password': guestPassword})),
    );
    final (guest, _) = await login(server, 'guest', guestPassword, rememberMe: true);
    expect((await guest.get('/api/tracks')).statusCode, 200);

    expect((await admin.delete('/api/users/${created.id}')).statusCode, 200);
    // The 90-day token is still cryptographically valid, but the account behind it is gone.
    expect((await guest.get('/api/tracks')).statusCode, 401);
  });

  test('an administrator cannot delete their own account; unknown accounts are 404', () async {
    final (admin, auth) = await setupAdmin(server);
    expect((await admin.delete('/api/users/${auth.user.id}')).statusCode, 400);
    expect((await admin.delete('/api/users/nobody')).statusCode, 404);
    final users = json(await admin.get('/api/users')) as List;
    expect(users.single['username'], 'owner');
  });

  test('a query token is accepted on the media routes only', () async {
    final (client, auth) = await setupAdmin(server);
    final track = (await server.waitForTracks(client, 3)).first;
    final anonymous = server.client();
    final issued = StreamTokenResponse.fromJson(json(await client.post('/api/auth/stream-token')));
    final stream = Uri.encodeComponent(issued.token);

    expect((await anonymous.get('/api/stream/${track['id']}?token=$stream')).statusCode, 200);
    expect((await anonymous.get('/api/cover/${track['id']}?token=$stream')).statusCode, 404); // let in; no cover

    // A token that leaked through a URL must not be usable against the rest of the API, whichever kind it is.
    for (final token in [stream, Uri.encodeComponent(auth.token)]) {
      for (final route in ['/api/tracks', '/api/auth/me', '/api/users']) {
        expect((await anonymous.get('$route?token=$token')).statusCode, 401, reason: route);
      }
    }
  });

  test('sign-in is rate limited with a readable error', () async {
    final client = server.client();
    late http.Response last;
    for (var i = 0; i < 12; i++) {
      last = await client.post('/api/auth/login', {'username': 'owner', 'password': 'wrong-password-$i'});
    }
    expect(last.statusCode, 429);
    expect(json(last)['error'], contains('Too many attempts'));
    expect(json(last)['code'], ErrorCodes.rateLimited);
    expect(json(last)['retryAfter'], int.parse(last.headers['retry-after']!));
    expect(last.headers['retry-after'], isNotNull);
  });

  test('passwords beyond what bcrypt can hash are rejected instead of truncated', () async {
    final client = server.client();
    Future<int> setup(String password) async => (await client.post('/api/auth/setup', {
      'username': 'owner',
      'password': password,
      'setupCode': setupCode,
    })).statusCode;

    expect(await setup('a' * (AuthRules.maxPasswordBytes + 1)), 400);
    expect(await setup('é' * 37), 400); // 74 bytes in UTF-8
    expect(await setup('a' * AuthRules.maxPasswordBytes), 200);
  });

  test('switching to an empty folder clears the index, but a vanished mount does not', () async {
    final (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);

    final empty = Directory(p.join(server.root, 'empty'))..createSync();
    expect((await admin.post('/api/config/library-path', {'newPath': empty.path})).statusCode, 200);
    await server.waitForTracks(admin, 0);

    expect((await admin.post('/api/config/library-path', {'newPath': server.libraryPath})).statusCode, 200);
    await server.waitForTracks(admin, 3);
    for (final entry in Directory(server.libraryPath).listSync()) {
      entry.deleteSync(recursive: true);
    }
    expect((await admin.post('/api/library/scan')).statusCode, 202);

    var status = ServerLibraryStatus.fromJson(json(await admin.get('/api/library/status')));
    for (var i = 0; i < 50 && status.lastScanError == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = ServerLibraryStatus.fromJson(json(await admin.get('/api/library/status')));
    }
    expect(status.trackCount, 3);
    expect(status.lastScanError, contains('empty'));
  });

  test('the library folder must exist and cannot be a sensitive system or data folder', () async {
    final (admin, _) = await setupAdmin(server);
    expect((await admin.post('/api/config/library-path', {'newPath': p.join(server.root, 'nope')})).statusCode, 400);
    expect((await admin.post('/api/config/library-path', {'newPath': '  '})).statusCode, 400);
    expect((await admin.post('/api/config/library-path', {'newPath': server.dataPath})).statusCode, 400);
    if (Platform.isLinux && Directory('/proc').existsSync()) {
      expect((await admin.post('/api/config/library-path', {'newPath': '/proc'})).statusCode, 400);
    }
    // A whole disk, a folder that holds the server's data, and a link that leads into it.
    expect((await admin.post('/api/config/library-path', {'newPath': p.rootPrefix(server.root)})).statusCode, 400);
    expect((await admin.post('/api/config/library-path', {'newPath': server.root})).statusCode, 400);
    if (!Platform.isWindows) {
      final link = Link(p.join(server.root, 'innocent'))..createSync(server.dataPath);
      expect((await admin.post('/api/config/library-path', {'newPath': link.path})).statusCode, 400);
    }
    expect(json(await admin.get('/api/config'))['libraryPath'], server.libraryPath);
  });

  test('JSON is compressed, ranged audio never', () async {
    final (client, _) = await setupAdmin(server);
    final track = (await server.waitForTracks(client, 3)).first;

    final raw = HttpClient()..autoUncompress = false;
    addTearDown(raw.close);
    final request = await raw.getUrl(Uri.parse('${server.baseUrl}/api/tracks'));
    request.headers
      ..set('Authorization', 'Bearer ${client.token}')
      ..set('Accept-Encoding', 'gzip');
    final response = await request.close();
    expect(response.headers.value('content-encoding'), 'gzip');
    final decoded = jsonDecode(utf8.decode(gzip.decode(await response.fold<List<int>>([], (a, b) => a..addAll(b)))));
    expect(decoded, hasLength(3));

    final audioRequest = await raw.getUrl(Uri.parse('${server.baseUrl}/api/stream/${track['id']}'));
    audioRequest.headers
      ..set('Authorization', 'Bearer ${client.token}')
      ..set('Accept-Encoding', 'gzip')
      ..set('Range', 'bytes=0-1023');
    final audio = await audioRequest.close();
    expect(audio.statusCode, 206);
    expect(audio.headers.value('content-encoding'), isNull);
    expect((await audio.fold<List<int>>([], (a, b) => a..addAll(b))).length, 1024);
  });

  test('unknown routes are 404, known routes with another method 405', () async {
    final (client, _) = await setupAdmin(server);
    expect((await client.get('/api/nothing-here')).statusCode, 404);
    expect((await client.delete('/api/tracks')).statusCode, 405);
  });

  test('bodies over the limit are refused', () async {
    final (client, _) = await setupAdmin(server);
    final response = await client.post('/api/auth/register', {'username': 'big', 'password': 'x' * (70 * 1024)});
    expect(response.statusCode, 413);
    final invalid = await http.post(Uri.parse('${server.baseUrl}/api/auth/login'), body: '{not json');
    expect(invalid.statusCode, 400);
  });
}
