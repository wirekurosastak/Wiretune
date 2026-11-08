// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Blocking another account (its recommendations and invites stop reaching this one, and it isn't told), and changing
/// an account's name (an administrator's for anyone, a member's own when the server lets members).
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late Api admin;
  late String adminToken;
  late Api guest;
  late UserInfo guestUser;
  late String guestToken;
  late String trackId;

  setUp(() async {
    server = await ServerFixture.start();
    final (client, auth) = await setupAdmin(server);
    admin = client;
    adminToken = auth.token;
    (guest, guestUser) = await registerGuest(server, admin);
    guestToken = (await login(server, 'guest', guestPassword)).$2.token;
    trackId = (await server.waitForTracks(admin, 3)).first['id'] as String;
  });
  tearDown(() => server.close());

  Future<String> adminId() async => UserInfo.fromJson(json(await admin.get('/api/auth/me'))).id;
  Future<List<Recommendation>> received(Api client) async => [
    for (final r in json(await client.get('/api/me/recommendations')) as List) Recommendation.fromJson(r),
  ];
  Future<List<String>> blockedBy(Api client) async => [
    for (final a in json(await client.get('/api/me/blocked')) as List) AccountInfo.fromJson(a).username,
  ];
  Future<int> recommend(Api from, String to) async => (await from.post('/api/me/recommendations', {
    'kind': 'track',
    'itemId': trackId,
    'to': [to],
  })).statusCode;

  group('blocking', () {
    test("a blocked account's recommendations stop coming, and those it sent go; it isn't told", () async {
      final owner = await adminId();
      expect(await recommend(admin, guestUser.id), 200);
      expect(await received(guest), hasLength(1));

      final blocked = await guest.put('/api/me/blocked/$owner');
      expect(blocked.statusCode, 200);
      expect(await blockedBy(guest), ['owner']);
      expect(await received(guest), isEmpty, reason: 'what it sent before goes too');

      // Sending still looks as if it went.
      expect(await recommend(admin, guestUser.id), 200);
      expect(await received(guest), isEmpty);
      expect(await blockedBy(admin), isEmpty, reason: 'blocking is one way');

      // Unblocked, new ones come again; the ones from before the block don't come back.
      expect((await guest.delete('/api/me/blocked/$owner')).statusCode, 200);
      expect(await blockedBy(guest), isEmpty);
      expect(await received(guest), isEmpty);
      expect(await recommend(admin, guestUser.id), 200);
      expect(await received(guest), hasLength(1));
    });

    test('only another account of the server can be blocked', () async {
      expect((await guest.put('/api/me/blocked/${guestUser.id}')).statusCode, 404, reason: 'not itself');
      expect((await guest.put('/api/me/blocked/nobody')).statusCode, 404);
      expect(await blockedBy(guest), isEmpty);
    });

    test('an account that blocked the host never hears of its invite to listen together', () async {
      final owner = await adminId();
      final host = await Peer.connect(server, adminToken, 'desk');
      addTearDown(host.close);
      final phone = await Peer.connect(server, guestToken, 'phone');
      addTearDown(phone.close);
      await until(() => host.ofType('devices').isNotEmpty && phone.ofType('listenInvites').isNotEmpty);
      List<Object?> invites() => (phone.ofType('listenInvites').last['invites'] as List?) ?? const [];

      // Invited first, then blocked: the open invite goes.
      host.send({
        'type': 'listenStart',
        'invite': [guestUser.id],
      });
      await until(() => invites().isNotEmpty);
      expect((await guest.put('/api/me/blocked/$owner')).statusCode, 200);
      await until(() => invites().isEmpty);

      // Invited again while blocked: nothing comes.
      final seen = phone.ofType('listenInvites').length;
      host.send({
        'type': 'listenInvite',
        'invite': [guestUser.id],
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(phone.ofType('listenInvites'), hasLength(seen));
      expect(invites(), isEmpty);
    });

    test('a deleted account leaves no blocks behind', () async {
      expect((await guest.put('/api/me/blocked/${await adminId()}')).statusCode, 200);
      expect((await admin.delete('/api/users/${guestUser.id}')).statusCode, 200);
      expect(await registerGuest(server, admin), isNotNull);
      final (again, _) = await login(server, 'guest', guestPassword);
      expect(await blockedBy(again), isEmpty);
    });
  });

  group('renaming', () {
    Future<(int, String?)> renameSelf(Api client, String name) async {
      final answer = await client.post('/api/auth/change-username', {'username': name});
      return (answer.statusCode, answer.statusCode == 200 ? null : json(answer)['code'] as String);
    }

    test("an administrator renames anyone; the account keeps everything, and signs in with the new name", () async {
      expect(await recommend(admin, guestUser.id), 200);
      final renamed = await admin.post('/api/users/${guestUser.id}/username', {'username': '  Anna '});
      expect(renamed.statusCode, 200);
      expect(UserInfo.fromJson(json(renamed)).username, 'Anna');

      // Its old sign-in still works, under the new name; so does signing in with the new name, not the old one.
      expect(UserInfo.fromJson(json(await guest.get('/api/auth/me'))).username, 'Anna');
      expect(await received(guest), hasLength(1), reason: 'what it was recommended stays');
      expect((await login(server, 'anna', guestPassword)).$2.user.username, 'Anna');
      await expectLater(login(server, 'guest', guestPassword), throwsA(anything));

      // Friends see the new name.
      final accounts = [for (final a in json(await admin.get('/api/accounts')) as List) AccountInfo.fromJson(a)];
      expect(accounts.map((a) => a.username), contains('Anna'));
    });

    test("a name another account has, ignoring case, or a blank or too long one, is refused", () async {
      Future<(int, String?)> rename(String name) async {
        final answer = await admin.post('/api/users/${guestUser.id}/username', {'username': name});
        return (answer.statusCode, answer.statusCode == 200 ? null : json(answer)['code'] as String);
      }

      expect(await rename('OWNER'), (409, ErrorCodes.usernameTaken));
      expect(await rename('   '), (400, ErrorCodes.credentialsRequired));
      expect(await rename('x' * (AuthRules.maxUsernameLength + 1)), (400, ErrorCodes.usernameInvalid));
      expect(await rename('Guest'), (200, null), reason: 'its own name in other letters');
      expect((await admin.post('/api/users/nobody/username', {'username': 'x'})).statusCode, 404);
      expect((await guest.post('/api/users/${guestUser.id}/username', {'username': 'x'})).statusCode, 403);
    });

    test('a member renames itself only when the administrator lets members; an administrator always can', () async {
      ServerConfigInfo config(Object? body) => ServerConfigInfo.fromJson(body);
      expect(config(json(await admin.get('/api/config'))).membersCanRename, isFalse, reason: 'off at first');
      expect(UserInfo.fromJson(json(await guest.get('/api/auth/me'))).canRename, isFalse);
      expect(await renameSelf(guest, 'Anna'), (403, ErrorCodes.renameNotAllowed));
      expect(UserInfo.fromJson(json(await admin.get('/api/auth/me'))).canRename, isTrue);
      expect(await renameSelf(admin, 'Boss'), (200, null));

      final allowed = await admin.post('/api/config/members-can-rename', {'enabled': true});
      expect(config(json(allowed)).membersCanRename, isTrue);
      expect(UserInfo.fromJson(json(await guest.get('/api/auth/me'))).canRename, isTrue);
      expect(await renameSelf(guest, 'Anna'), (200, null));
      expect(await renameSelf(guest, 'boss'), (409, ErrorCodes.usernameTaken));
      expect((await guest.post('/api/config/members-can-rename', {'enabled': false})).statusCode, 403);
      expect((await admin.post('/api/config/members-can-rename', {'enabled': 'yes'})).statusCode, 400);
    });

    test("the account's players hear of the new name, and its listening group shows it", () async {
      await admin.post('/api/config/members-can-rename', {'enabled': true});
      final host = await Peer.connect(server, adminToken, 'desk');
      addTearDown(host.close);
      final phone = await Peer.connect(server, guestToken, 'phone');
      addTearDown(phone.close);
      await until(() => host.ofType('devices').isNotEmpty && phone.ofType('devices').isNotEmpty);
      host.send({
        'type': 'listenStart',
        'invite': [guestUser.id],
      });
      await until(() => (phone.ofType('listenInvites').lastOrNull?['invites'] as List?)?.isNotEmpty ?? false);
      phone.send({
        'type': 'listenJoin',
        'group': (phone.ofType('listenInvites').last['invites'] as List).single['group'],
      });
      await until(() => phone.ofType('listen').lastOrNull?['group'] != null);

      expect(await renameSelf(guest, 'Anna'), (200, null));
      await until(() => phone.ofType('accountChanged').isNotEmpty);
      String? memberName() =>
          ((host.ofType('listen').last['group'] as Map)['members'] as List).single['username'] as String?;
      await until(() => memberName() == 'Anna');
      expect(host.ofType('accountChanged'), isEmpty, reason: "another account's players aren't told");
    });
  });
}
