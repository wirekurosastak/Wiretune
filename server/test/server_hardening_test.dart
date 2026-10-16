// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

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

      // A caller that does not know the code cannot become administrator.
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
      final body = (await client.get('/api/tracks')).body;
      expect(body, isNot(contains(folderName)));
      expect(body.toLowerCase(), isNot(contains('path')));
    });

    test('tracks still carry everything a player needs', () async {
      final (client, _) = await setupAdmin(server);
      final tracks = (await server.waitForTracks(client, 3)).map(Track.fromJson).toList();
      for (final t in tracks) {
        expect(t.title, isNotEmpty);
        expect(t.duration, greaterThan(Duration.zero));
        expect(t.fileSizeBytes, greaterThan(0));
        expect(t.fileModifiedAt, isNotNull);
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
      final cover = '/api/cover/album/${Track.fromJson(track).albumId}?token=$token';
      expect((await media.get(cover)).statusCode, 404); // let in; no cover

      // Not on the management API (even as a header), and not to mint more tokens.
      media.token = issued.token;
      for (final route in ['/api/tracks', '/api/me/data', '/api/auth/me', '/api/users', '/api/config']) {
        expect((await media.get(route)).statusCode, 401, reason: route);
      }
      expect((await media.post('/api/auth/stream-token')).statusCode, 401);
      expect((await media.post('/api/auth/register', {'username': 'x', 'password': 'xxxxxxxxxx'})).statusCode, 401);

      // A sign-in token opens the media routes in a header (covers are loaded that way), never in a URL.
      final inUrl = await server.client().get('/api/stream/${track['id']}?token=${Uri.encodeComponent(auth.token)}');
      expect(inUrl.statusCode, 401);
      expect((await server.client(auth.token).get('/api/stream/${track['id']}')).statusCode, 200);
    });

    test("an administrator's stream token never carries the admin role", () async {
      final (admin, _) = await setupAdmin(server);
      final issued = StreamTokenResponse.fromJson(json(await admin.post('/api/auth/stream-token')));
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(issued.token.split('.')[1])));
      expect(payload, isNot(contains('admin')));
      expect(payload, contains('"aud":"wiretune-stream"'));
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

    test('a token carries the account and its token version, and nothing more', () async {
      final (_, auth) = await setupAdmin(server);
      final parts = auth.token.split('.');
      final header = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      expect(header, {'alg': 'HS256', 'typ': 'JWT'});
      expect(claims.keys, unorderedEquals(['sub', 'name', 'aud', 'ver', 'exp']));
      expect(claims['sub'], auth.user.id);
      expect(claims['name'], 'owner');
      expect(claims['ver'], 0);
      expect(claims['aud'], AuthService.audience);
    });

    test('the role is the account\'s present one, not what the token was issued with', () async {
      final (admin, _) = await setupAdmin(server);
      expect((await admin.get('/api/users')).statusCode, 200);
      server.server.database.connection.execute('UPDATE users SET is_admin = 0');
      expect((await admin.get('/api/users')).statusCode, 403);
      expect(UserInfo.fromJson(json(await admin.get('/api/auth/me'))).isAdmin, isFalse);
    });

    test('a token signed before token versions existed still opens the API', () async {
      final (admin, auth) = await setupAdmin(server);
      final secret = (server.server.repository.getSetting('jwt_secret'))!;
      final old = Jwt(secret).sign({
        'sub': auth.user.id,
        'name': 'owner',
        'role': 'admin',
        'aud': AuthService.audience,
        'exp': DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      });
      expect((await server.client(old).get('/api/users')).statusCode, 200);

      // Once the password changes, it is a token of the old password like any other.
      expect(
        (await admin.post('/api/auth/change-password', {
          'currentPassword': adminPassword,
          'newPassword': 'a-brand-new-password',
        })).statusCode,
        200,
      );
      expect((await server.client(old).get('/api/auth/me')).statusCode, 401);
    });

    test('a password change ends every other session; the caller carries on with a new token', () async {
      final (phone, auth) = await setupAdmin(server);
      final track = (await server.waitForTracks(phone, 3)).first;
      final (desktop, _) = await login(server, 'owner', adminPassword, rememberMe: true);
      final streamToken = StreamTokenResponse.fromJson(json(await desktop.post('/api/auth/stream-token'))).token;
      final streamUrl = '/api/stream/${track['id']}?token=${Uri.encodeComponent(streamToken)}';
      expect((await server.client().get(streamUrl)).statusCode, 200);

      final changed = await phone.post('/api/auth/change-password', {
        'currentPassword': adminPassword,
        'newPassword': 'a-brand-new-password',
      });
      expect(changed.statusCode, 200);
      expect(json(changed)['changed'], isTrue);
      final renewed = AuthResponse.fromJson(json(changed));
      expect(renewed.user.id, auth.user.id);
      // As long as the token it replaces, no longer: changing a password does not extend a session.
      expect(renewed.expiresAt.difference(auth.expiresAt).inSeconds.abs(), lessThanOrEqualTo(1));

      expect((await desktop.get('/api/auth/me')).statusCode, 401);
      expect((await server.client().get(streamUrl)).statusCode, 401);
      expect((await phone.get('/api/auth/me')).statusCode, 401);
      expect((await server.client(renewed.token).get('/api/auth/me')).statusCode, 200);
    });

    test("an administrator's reset ends the account's sessions, but not for their own account", () async {
      final (admin, auth) = await setupAdmin(server);
      final (guest, guestInfo) = await registerGuest(server, admin);
      expect((await guest.get('/api/auth/me')).statusCode, 200);

      final reset = await admin.post('/api/users/${guestInfo.id}/password', {'newPassword': 'reset-by-admin'});
      expect(reset.statusCode, 200);
      expect((await guest.get('/api/auth/me')).statusCode, 401);
      final (_, again) = await login(server, 'guest', 'reset-by-admin');
      expect(again.user.id, guestInfo.id);

      final own = await admin.post('/api/users/${auth.user.id}/password', {'newPassword': 'reset-by-admin'});
      expect(own.statusCode, 400);
      expect((await admin.get('/api/auth/me')).statusCode, 200);
      expect((await admin.post('/api/users/nobody/password', {'newPassword': 'reset-by-admin'})).statusCode, 404);
      expect((await guest.post('/api/users/${auth.user.id}/password', {'newPassword': 'x' * 12})).statusCode, 401);
    });

    test(
      'every refusal says why with a code: a 401 tells a missing, foreign, expired, outdated or orphaned token apart',
      () async {
        final (admin, auth) = await setupAdmin(server);
        final (guest, guestInfo) = await registerGuest(server, admin);
        Future<(int, Object?)> me(String? token) async {
          final response = await server.client(token).get('/api/auth/me');
          return (response.statusCode, json(response)['code']);
        }

        expect(await me(null), (401, ErrorCodes.signInRequired));
        expect(await me('not.a.token'), (401, ErrorCodes.tokenInvalid));
        final secret = (server.server.repository.getSetting('jwt_secret'))!;
        final expired = Jwt(secret).sign({
          'sub': auth.user.id,
          'name': 'owner',
          'aud': AuthService.audience,
          'exp': DateTime.now().toUtc().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
        });
        expect(await me(expired), (401, ErrorCodes.sessionExpired));

        final oldGuestToken = guest.token;
        await admin.post('/api/users/${guestInfo.id}/password', {'newPassword': 'reset-by-admin'});
        expect(await me(oldGuestToken), (401, ErrorCodes.passwordChanged));
        final (again, _) = await login(server, 'guest', 'reset-by-admin');
        await admin.delete('/api/users/${guestInfo.id}');
        expect(await me(again.token), (401, ErrorCodes.accountRemoved));

        final wrong = await server.client().post('/api/auth/login', {'username': 'owner', 'password': 'nope-nope'});
        expect((wrong.statusCode, json(wrong)['code']), (401, ErrorCodes.wrongCredentials));
        expect(wrong.headers['www-authenticate'], 'Bearer');
      },
    );

    test('refusals carry the code and the numbers or path their message names', () async {
      final (admin, _) = await setupAdmin(server);
      final (guest, _) = await registerGuest(server, admin);

      final adminOnly = await guest.get('/api/users');
      expect((adminOnly.statusCode, json(adminOnly)['code']), (403, ErrorCodes.adminOnly));

      final disk = await admin.post('/api/config/music-folder', {'musicFolder': '/'});
      expect((disk.statusCode, json(disk)['code']), (400, ErrorCodes.folderWholeDisk));
      final missing = await admin.post('/api/config/music-folder', {'musicFolder': '${server.root}/nope'});
      expect(json(missing)['code'], ErrorCodes.folderMissing);
      expect(json(missing)['path'], '${server.root}/nope');

      final taken = await admin.post('/api/auth/register', {'username': 'GUEST', 'password': guestPassword});
      expect((taken.statusCode, json(taken)['code']), (409, ErrorCodes.usernameTaken));
      final short = await admin.post('/api/auth/register', {'username': 'x', 'password': 'short'});
      expect((json(short)['code'], json(short)['min']), (ErrorCodes.passwordTooShort, AuthRules.minPasswordLength));

      final name = await guest.put('/api/me/playlists/p1', {'name': 'n' * 300, 'trackIds': <String>[]});
      expect(
        (json(name)['code'], json(name)['max']),
        (ErrorCodes.playlistNameTooLong, UserDataRules.maxPlaylistNameLength),
      );
      final unknown = await guest.delete('/api/me/playlists/none');
      expect((unknown.statusCode, json(unknown)['code']), (404, ErrorCodes.playlistNotFound));
      final wrongCode = await server.client().post('/api/auth/setup', {
        'username': 'x',
        'password': adminPassword,
        'setupCode': 'wrong',
      });
      expect(json(wrongCode)['code'], ErrorCodes.alreadySetUp);
    });

    test('only an administrator sees why a scan failed, which names the server\'s folders', () async {
      final (admin, _) = await setupAdmin(server);
      final (guest, _) = await registerGuest(server, admin);
      await server.waitForTracks(admin, 3);
      server.server.scanner.lastScanError = 'Library folder does not exist: /srv/secret';
      expect(
        ServerLibraryStatus.fromJson(json(await admin.get('/api/library/status'))).lastScanError,
        contains('/srv'),
      );
      expect(ServerLibraryStatus.fromJson(json(await guest.get('/api/library/status'))).lastScanError, isNull);
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

  test(
    'a library folder chosen by the admin is kept when it is missing at start-up, e.g. an unmounted share',
    () async {
      final first = await ServerFixture.start();
      first.keepFiles = true;
      final (admin, _) = await setupAdmin(first);
      final share = Directory('${first.root}/share')..createSync();
      writeWav('${share.path}/Artist/Album/01 Track.wav', 44100);
      expect((await admin.post('/api/config/music-folder', {'musicFolder': share.path})).statusCode, 200);
      await first.waitForTracks(admin, 1);
      await first.close();

      share.renameSync('${first.root}/unmounted');
      final second = await ServerFixture.start(existingRoot: first.root);
      addTearDown(() async {
        await second.close();
        first.keepFiles = false;
        await first.close().catchError((_) {});
      });
      final (admin2, _) = await login(second, 'owner', adminPassword);
      expect(json(await admin2.get('/api/config'))['musicFolder'], AppPaths.fullPath(share.path));
      // The scan waits for the share instead of putting the configured folder (three tracks) in its place.
      for (var i = 0; i < 100 && second.server.scanner.lastScanError == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(second.server.scanner.lastScanError, contains('does not exist'));
      expect(json(await admin2.get('/api/library/status'))['trackCount'], 1);
    },
  );

  test('a library folder chosen by the admin survives a restart', () async {
    final first = await ServerFixture.start();
    first.keepFiles = true;
    final (admin, _) = await setupAdmin(first);
    final other = '${first.root}/library2';
    expect((await admin.post('/api/config/music-folder', {'musicFolder': other})).statusCode, 200);
    await first.close();

    final second = await ServerFixture.start(existingRoot: first.root);
    addTearDown(() async {
      await second.close();
      first.keepFiles = false;
      await first.close().catchError((_) {});
    });
    final (admin2, _) = await login(second, 'owner', adminPassword);
    expect(json(await admin2.get('/api/config'))['musicFolder'], AppPaths.fullPath(other));
  });

  test('the JWT verifier refuses tampering, other audiences and expired tokens', () {
    final jwt = Jwt('secret');
    final now = DateTime.now();
    final token = jwt.sign({'aud': 'wiretune', 'exp': now.millisecondsSinceEpoch ~/ 1000 + 60});
    expect(jwt.verify(token, audiences: {'wiretune'}), isNotNull);
    expect(Jwt('other').verify(token, audiences: {'wiretune'}), isNull);
    expect(jwt.verify(token, audiences: {'wiretune-stream'}), isNull);
    expect(jwt.verify('${token}x', audiences: {'wiretune'}), isNull);
    expect(jwt.verify(token, audiences: {'wiretune'}, now: now.add(const Duration(seconds: 59))), isNotNull);
    expect(jwt.verify(token, audiences: {'wiretune'}, now: now.add(const Duration(seconds: 61))), isNull);
    expect(jwt.verify(jwt.sign({'aud': 'wiretune'}), audiences: {'wiretune'}), isNull); // no expiry: no token
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
      final proxied = await ServerFixture.start(trustProxy: true);
      addTearDown(proxied.close);
      Future<int> attempt(String forwardedFor) async => (await http.post(
        Uri.parse('${proxied.baseUrl}/api/auth/login'),
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
      final old = await server.client().post('/api/auth/login', {'username': 'owner', 'password': adminPassword});
      expect(old.statusCode, 401);

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
