import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// First-run protection, what the library routes reveal, stream tokens and restarts.
void main() {
  group('with a server', () {
    late ServerFixture server;
    setUp(() async => server = await ServerFixture.start());
    tearDown(() async => server.close());

    test('setup needs the setup code that the operator sees', () async {
      final client = server.client();
      Future<int> setup(String? code) async => (await client.post('/api/auth/setup', {
        'username': 'owner',
        'password': adminPassword,
        'setupCode': code,
      })).statusCode;

      // A caller that does not know the code (or an older player that sends none) cannot become administrator.
      expect(await setup(null), 403);
      expect(await setup('WRONG-CODE'), 403);
      expect(json(await client.get('/api/auth/setup-required'))['setupRequired'], isTrue);
      // Case, spaces and dashes do not matter when the code is typed by hand.
      expect(await setup(' TEST setup-code '), 200);
    });

    test('a finished setup answers conflict, even with a wrong code', () async {
      await setupAdmin(server);
      final again = await server.client().post('/api/auth/setup', {
        'username': 'intruder',
        'password': adminPassword,
        'setupCode': 'WRONG',
      });
      expect(again.statusCode, 409);
    });

    test('the library routes never expose server paths', () async {
      final (client, _) = await setupAdmin(server);
      await server.waitForTracks(client, 3);

      final folderName = server.root.split('/').last;
      for (final route in ['/api/tracks', '/api/albums', '/api/artists', '/api/tracks?q=first']) {
        final body = (await client.get(route)).body;
        expect(body, isNot(contains(folderName)));
        expect(body.toLowerCase(), isNot(contains('coverartpath')));
      }

      // Older players key their database on a unique, non-empty filePath: it stays, as a placeholder.
      final tracks = json(await client.get('/api/tracks')) as List;
      for (final t in tracks) {
        expect(t['filePath'], 'server:${t['id']}');
      }
    });

    test('tracks still carry everything a player needs', () async {
      final (client, _) = await setupAdmin(server);
      final tracks = (await server.waitForTracks(client, 3)).map(Track.fromJson).toList();
      for (final t in tracks) {
        expect(t.title, isNotEmpty);
        expect(t.duration, greaterThan(Duration.zero));
        expect(t.fileSizeBytes, greaterThan(0));
        expect(t.fileModifiedUtc, isNotNull);
        expect(t.format.sampleRate, greaterThan(0));
      }
      expect(tracks.any((t) => t.format.sampleRate == 96000), isTrue);
    });

    test('a stream token opens the media routes and nothing else', () async {
      final (admin, auth) = await setupAdmin(server);
      final track = (await server.waitForTracks(admin, 3)).first;

      final response = await admin.post('/api/auth/stream-token');
      expect(response.statusCode, 200);
      final issued = StreamTokenResponse.fromJson(json(response));
      expect(issued.token, isNot(auth.token));
      final now = DateTime.now().toUtc();
      expect(issued.expiresAt.isAfter(now.add(const Duration(hours: 1))), isTrue);
      expect(issued.expiresAt.isBefore(now.add(const Duration(hours: 9))), isTrue);

      final media = server.client();
      final token = Uri.encodeComponent(issued.token);
      expect((await media.get('/api/stream/${track['id']}?token=$token')).statusCode, 200);
      expect((await media.get('/api/cover/${track['id']}?token=$token')).statusCode, isNot(401));

      // Not on the management API (even as a header), and not to mint more tokens.
      media.token = issued.token;
      for (final route in ['/api/tracks', '/api/me/data', '/api/auth/me', '/api/users', '/api/config']) {
        expect((await media.get(route)).statusCode, 401, reason: route);
      }
      expect((await media.post('/api/auth/stream-token')).statusCode, 401);
      expect((await media.post('/api/auth/register', {'username': 'x', 'password': 'xxxxxxxxxx'})).statusCode, 401);

      // Players that predate stream tokens still stream with the sign-in token.
      final legacy = await server.client().get('/api/stream/${track['id']}?token=${Uri.encodeComponent(auth.token)}');
      expect(legacy.statusCode, 200);
    });

    test("an administrator's stream token never carries the admin role", () async {
      final (admin, _) = await setupAdmin(server);
      final issued = StreamTokenResponse.fromJson(json(await admin.post('/api/auth/stream-token')));
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(issued.token.split('.')[1])));
      expect(payload, isNot(contains('admin')));
      expect(payload, contains('"wt_scope":"stream"'));
    });

    test('a stream token stops working when the account is deleted', () async {
      final (admin, _) = await setupAdmin(server);
      final track = (await server.waitForTracks(admin, 3)).first;
      final (guest, guestInfo) = await registerGuest(server, admin);

      final issued = StreamTokenResponse.fromJson(json(await guest.post('/api/auth/stream-token')));
      final url = '/api/stream/${track['id']}?token=${Uri.encodeComponent(issued.token)}';
      expect((await server.client().get(url)).statusCode, 200);

      await admin.delete('/api/users/${guestInfo.id}');
      expect((await server.client().get(url)).statusCode, 401);
    });

    test('tokens are signed like the C# server signed them', () async {
      final (_, auth) = await setupAdmin(server);
      final parts = auth.token.split('.');
      final header = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      expect(header, {'alg': 'HS256', 'typ': 'JWT'});
      expect(claims['iss'], 'WiretuneServer');
      expect(claims['aud'], 'WiretuneClient');
      expect(claims[AuthService.nameIdClaim], auth.user.id);
      expect(claims[AuthService.nameClaim], 'owner');
      expect(claims[AuthService.roleClaim], 'admin');
    });
  });

  test('the setup code is generated when not configured, and compared leniently', () {
    final pattern = RegExp(r'^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$');
    final generated = SetupCode(null);
    expect(generated.value, matches(pattern));
    expect(generated.matches(generated.value), isTrue);
    expect(generated.matches(generated.value.toLowerCase().replaceAll('-', ' ')), isTrue);
    expect(generated.matches(null), isFalse);
    expect(generated.matches(''), isFalse);
    expect(generated.matches('AAAA-AAAA'), isFalse);

    // Two servers do not share a code, and an unusable configured value is not accepted as "no code".
    expect(SetupCode(null).value, isNot(generated.value));
    for (final unusable in ['', '  ', '----']) {
      final made = SetupCode(unusable);
      expect(made.value, matches(pattern));
      expect(made.matches(''), isFalse);
    }

    final chosen = SetupCode('Open-Sesame');
    expect(chosen.value, 'Open-Sesame');
    expect(chosen.matches('OPEN SESAME'), isTrue);
  });

  test('a restart keeps accounts and tokens, and setup stays closed', () async {
    final first = await ServerFixture.start();
    first.keepFiles = true;
    final (_, auth) = await setupAdmin(first);
    await first.close();

    final restarted = await ServerFixture.start(existingRoot: first.root);
    addTearDown(() async {
      await restarted.close();
      first.keepFiles = false;
      await first.close().catchError((_) {});
    });

    // The token signed before the restart is still valid: the signing key lives in the database.
    expect((await restarted.client(auth.token).get('/api/auth/me')).statusCode, 200);
    expect(json(await restarted.client().get('/api/auth/setup-required'))['setupRequired'], isFalse);
  });

  test('a library folder chosen by the admin survives a restart', () async {
    final first = await ServerFixture.start();
    first.keepFiles = true;
    final (admin, _) = await setupAdmin(first);
    final other = '${first.root}/library2';
    expect((await admin.post('/api/config/library-path', {'newPath': other})).statusCode, 200);
    await first.close();

    final second = await ServerFixture.start(existingRoot: first.root);
    addTearDown(() async {
      await second.close();
      first.keepFiles = false;
      await first.close().catchError((_) {});
    });
    final (admin2, _) = await login(second, 'owner', adminPassword);
    expect(json(await admin2.get('/api/config'))['libraryPath'], AppPaths.fullPath(other));
  });

  test('the JWT verifier refuses tampering, other issuers and expired tokens', () {
    final jwt = Jwt('secret');
    final token = jwt.sign({
      'iss': 'WiretuneServer',
      'aud': 'WiretuneClient',
      'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
    });
    expect(jwt.verify(token, issuer: 'WiretuneServer', audiences: {'WiretuneClient'}), isNotNull);
    expect(Jwt('other').verify(token, issuer: 'WiretuneServer', audiences: {'WiretuneClient'}), isNull);
    expect(jwt.verify(token, issuer: 'Someone', audiences: {'WiretuneClient'}), isNull);
    expect(jwt.verify(token, issuer: 'WiretuneServer', audiences: {'WiretuneStream'}), isNull);
    expect(jwt.verify('${token}x', issuer: 'WiretuneServer', audiences: {'WiretuneClient'}), isNull);
    expect(
      jwt.verify(
        token,
        issuer: 'WiretuneServer',
        audiences: {'WiretuneClient'},
        now: DateTime.now().add(const Duration(minutes: 5)),
      ),
      isNull,
    );
    expect(
      jwt.verify(
        token,
        issuer: 'WiretuneServer',
        audiences: {'WiretuneClient'},
        now: DateTime.now().add(const Duration(minutes: 2)),
      ),
      isNotNull, // within the two minutes of clock skew
    );
  });

  group('malformed input and passwords', () {
    late ServerFixture server;
    setUp(() async => server = await ServerFixture.start());
    tearDown(() async => server.close());

    test('values of the wrong type are a 400, not a 500', () async {
      final client = server.client();
      final setup = await client.post('/api/auth/setup', {'username': 42, 'password': true, 'setupCode': 7});
      expect(setup.statusCode, 400);

      final (admin, _) = await setupAdmin(server);
      final register = await admin.post('/api/auth/register', {
        'username': ['x'],
        'password': 1,
      });
      expect(register.statusCode, 400);
    });

    test('a path is decoded once, and no escape in it is a 500', () async {
      final (admin, _) = await setupAdmin(server);

      // The players encode an ID once; a "%" in it has to arrive as a "%", not be decoded a second time.
      for (final id in ['a%41', '50%off']) {
        final saved = await admin.put('/api/me/playlists/${Uri.encodeComponent(id)}', {'name': id});
        expect((saved.statusCode, json(saved)['id']), (200, id));
      }
      expect((await admin.delete('/api/me/playlists/${Uri.encodeComponent('50%off')}')).statusCode, 200);

      // "%25zz" decodes to "%zz", which is a valid name, not a broken escape.
      expect((await server.client().get('/api/nothing%25zz')).statusCode, 404);
      expect((await server.client().get('/api/stream/%25zz')).statusCode, 401);
      expect((await admin.get('/api/stream/%25zz')).statusCode, 404);
      // Escapes that are not UTF-8 never reach a route.
      expect((await admin.get('/api/stream/%E0%A4')).statusCode, 400);
    });

    test('range numbers too large for an integer lie past the end of the file', () async {
      final (admin, _) = await setupAdmin(server);
      final track = (await server.waitForTracks(admin, 3)).first;
      final length = track['fileSizeBytes'] as int;
      const huge = '99999999999999999999999';

      Future<(int, String?)> ranged(String range) async {
        final response = await admin.send('GET', '/api/stream/${track['id']}', headers: {'Range': 'bytes=$range'});
        await response.stream.drain<void>();
        return (response.statusCode, response.headers['content-range']);
      }

      expect(await ranged('$huge-'), (416, 'bytes */$length'));
      expect(await ranged('0-$huge'), (206, 'bytes 0-${length - 1}/$length'));
      expect(await ranged('-$huge'), (206, 'bytes 0-${length - 1}/$length'));
    });

    test('behind a proxy, the address the proxy appended is the one that is limited', () async {
      server.server.options.forwardedHeaders = true;
      Future<int> attempt(String forwardedFor) async => (await http.post(
        Uri.parse('${server.baseUrl}/api/auth/login'),
        headers: {'x-forwarded-for': forwardedFor},
      )).statusCode;

      // The entries before the last are whatever the client wrote into the header, so they must not open new windows.
      for (var i = 0; i < 10; i++) {
        expect(await attempt('203.0.113.$i, 198.51.100.7'), 400); // no credentials: refused, but counted
      }
      expect(await attempt('203.0.113.99, 198.51.100.7'), 429);
      expect(await attempt('198.51.100.8'), 400); // another client of the same proxy
    });

    test('a password changes only with the current one', () async {
      final (admin, _) = await setupAdmin(server);
      const replacement = 'a-brand-new-password';

      final wrong = await admin.post('/api/auth/change-password', {
        'currentPassword': 'not-it',
        'newPassword': replacement,
      });
      expect(wrong.statusCode, 403);

      final weak = await admin.post('/api/auth/change-password', {
        'currentPassword': adminPassword,
        'newPassword': 'short',
      });
      expect(weak.statusCode, 400);

      final changed = await admin.post('/api/auth/change-password', {
        'currentPassword': adminPassword,
        'newPassword': replacement,
      });
      expect(changed.statusCode, 200);

      final anonymous = await server.client().post('/api/auth/change-password', {
        'currentPassword': replacement,
        'newPassword': adminPassword,
      });
      expect(anonymous.statusCode, 401);

      final (_, auth) = await login(server, 'owner', replacement);
      expect(auth.user.username, 'owner');
    });
  });
}
