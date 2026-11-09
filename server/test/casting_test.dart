// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/src/remote_hub.dart';

import 'support.dart';

/// Casting to another account's player: one that lets others play on it is seen by the server's other accounts (with
/// whose it is), gets their commands (with who sent them), and tells them what it plays; one that doesn't isn't, nor
/// one when either account blocked the other.
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late String ownerToken;
  late String guestToken;
  late Api guest;

  setUp(() async {
    server = await ServerFixture.start();
    final (admin, auth) = await setupAdmin(server);
    ownerToken = auth.token;
    await registerGuest(server, admin);
    final (client, signedIn) = await login(server, 'guest', guestPassword);
    guest = client;
    guestToken = signedIn.token;
  });
  tearDown(() => server.close());

  Future<Peer> connect(String token, String id, {String sharing = 'off', String? from}) async {
    final peer = await Peer.connect(server, token, id, name: id, sharing: sharing, from: from);
    addTearDown(peer.close);
    await until(() => peer.ofType('devices').isNotEmpty);
    return peer;
  }

  List<Map<Object?, Object?>> listed(Peer peer) =>
      (peer.ofType('devices').last['devices'] as List).cast<Map<Object?, Object?>>();

  test(
    "a shared player is seen, played on and heard by the other accounts; another account's command says whose",
    () async {
      final tv = await connect(guestToken, 'guest-tv', sharing: 'any');
      final desk = await connect(ownerToken, 'owner-desk');

      await until(() => listed(desk).any((d) => d['id'] == 'guest-tv'));
      expect(listed(desk).single['account'], containsPair('username', 'guest'));
      expect(listed(tv), isEmpty, reason: "the owner's desk isn't shared");

      desk.send({'type': 'command', 'to': 'guest-tv', 'command': const RemoteCommand(RemoteAction.pause).toJson()});
      await until(() => tv.ofType('command').isNotEmpty);
      expect(tv.ofType('command').single['account'], containsPair('username', 'owner'));

      tv.send({'type': 'state', 'state': const RemotePlayback(playing: true).toJson()});
      await until(() => desk.ofType('state').isNotEmpty);
      expect(desk.ofType('state').last['device'], 'guest-tv');
    },
  );

  test("a player that doesn't share, or whose account blocked the sender's, is neither seen nor played on", () async {
    final phone = await connect(guestToken, 'guest-phone');
    final desk = await connect(ownerToken, 'owner-desk');
    expect(listed(desk), isEmpty);
    desk.send({'type': 'command', 'to': 'guest-phone', 'command': const RemoteCommand(RemoteAction.pause).toJson()});

    final tv = await connect(guestToken, 'guest-tv', sharing: 'unhidden');
    await until(() => listed(desk).any((d) => d['id'] == 'guest-tv'));
    final owner = UserInfo.fromJson(json(await (server.client(ownerToken)).get('/api/auth/me')));
    expect((await guest.put('/api/me/blocked/${owner.id}')).statusCode, 200);
    await until(() => listed(desk).isEmpty);
    desk.send({'type': 'command', 'to': 'guest-tv', 'command': const RemoteCommand(RemoteAction.pause).toJson()});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect([...phone.ofType('command'), ...tv.ofType('command')], isEmpty);
  });

  test("an account that blocked a player's account no longer sees it, plays on it or hears what it plays", () async {
    final tv = await connect(guestToken, 'guest-tv', sharing: 'unhidden');
    final desk = await connect(ownerToken, 'owner-desk');
    await until(() => listed(desk).any((d) => d['id'] == 'guest-tv'));
    final guestId = UserInfo.fromJson(json(await guest.get('/api/auth/me'))).id;
    expect((await server.client(ownerToken).put('/api/me/blocked/$guestId')).statusCode, 200);
    await until(() => listed(desk).isEmpty);

    tv.send({'type': 'state', 'state': const RemotePlayback(playing: true).toJson()});
    desk.send({'type': 'command', 'to': 'guest-tv', 'command': const RemoteCommand(RemoteAction.pause).toJson()});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(tv.ofType('command'), isEmpty);
    expect(desk.ofType('state'), isEmpty);
  });

  test("another account's player is there only on the same network; the account's own are, from anywhere", () async {
    await server.close();
    server = await ServerFixture.start(trustProxy: true);
    final (admin, auth) = await setupAdmin(server);
    ownerToken = auth.token;
    await registerGuest(server, admin);
    guestToken = (await login(server, 'guest', guestPassword)).$2.token;

    // The guest's television at home; the owner's computer in another home, its phone in the guest's.
    final tv = await connect(guestToken, 'guest-tv', sharing: 'any', from: '203.0.113.5');
    final desk = await connect(ownerToken, 'owner-desk', from: '198.51.100.7');
    final phone = await connect(ownerToken, 'owner-phone', from: '203.0.113.5');
    await until(() => listed(phone).any((d) => d['id'] == 'guest-tv'));
    expect(listed(desk).map((d) => d['id']), [
      'owner-phone',
    ], reason: 'its own phone, but no television of another home');
    desk.send({'type': 'command', 'to': 'guest-tv', 'command': const RemoteCommand(RemoteAction.pause).toJson()});
    tv.send({'type': 'state', 'state': const RemotePlayback(playing: true).toJson()});
    await until(() => phone.ofType('state').any((m) => m['device'] == 'guest-tv'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(tv.ofType('command'), isEmpty);
    expect(desk.ofType('state').where((m) => m['device'] == 'guest-tv'), isEmpty);
  });

  test("a player's network: the server's side is one, a home's public address another", () {
    for (final address in [
      '127.0.0.1',
      '::1',
      '10.1.2.3',
      '172.20.0.9',
      '192.168.1.40',
      '169.254.3.3',
      '100.101.102.103',
      'fd7a:115c:a1e0::5',
      'fe80::1',
      '::ffff:192.168.1.7',
    ]) {
      expect(RemoteHub.networkOf(address), RemoteHub.local, reason: address);
    }
    expect(RemoteHub.networkOf('203.0.113.5'), '203.0.113.5');
    expect(RemoteHub.networkOf('::ffff:203.0.113.5'), '203.0.113.5');
    expect(RemoteHub.networkOf('172.32.0.1'), '172.32.0.1', reason: 'past 172.16/12');
    expect(RemoteHub.networkOf('2001:db8:1:2:aaaa::1'), RemoteHub.networkOf('2001:db8:1:2:bbbb::9'), reason: 'one /64');
    expect(RemoteHub.networkOf('2001:db8:1:2::1'), isNot(RemoteHub.networkOf('2001:db8:1:3::1')));
  });
}
