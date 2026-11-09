// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

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

  Future<Peer> connect(String token, String id, {String sharing = 'off'}) async {
    final peer = await Peer.connect(server, token, id, name: id, sharing: sharing);
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
}
