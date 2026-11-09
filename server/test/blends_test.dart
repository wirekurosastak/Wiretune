// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The Blends: one account invites another, and once it accepts both have a playlist mixed from their listening.
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late Api admin;
  late String adminToken;
  late String adminId;
  late Api guest;
  late UserInfo guestUser;
  late Map<String, Track> tracks; // by title, without the number

  setUp(() async {
    server = await ServerFixture.start();
    final (client, auth) = await setupAdmin(server);
    admin = client;
    adminToken = auth.token;
    adminId = auth.user.id;
    (guest, guestUser) = await registerGuest(server, admin);
    tracks = {
      for (final t in await server.waitForTracks(admin, 3))
        (t['title'] as String).replaceFirst(RegExp(r'^\d+ '), ''): Track.fromJson(t),
    };
  });
  tearDown(() => server.close());

  String id(String title) => tracks[title]!.id;
  Future<List<Blend>> blendsOf(Api client) async => [
    for (final b in json(await client.get('/api/me/blends')) as List) Blend.fromJson(b),
  ];
  Future<void> play(Api client, String title, int times) async {
    for (var i = 0; i < times; i++) {
      expect((await client.post('/api/me/plays/${id(title)}')).statusCode, 200);
    }
  }

  test('an invitation waits until the other accepts; then both have the mix, without what either hides', () async {
    final sent = await admin.post('/api/me/blends', {'with': guestUser.id});
    expect(sent.statusCode, 200);
    final blend = Blend.fromJson(json(sent));
    expect((blend.other.username, blend.state, blend.trackIds.length), ('guest', BlendState.inviting, 0));
    expect(
      [for (final b in await blendsOf(guest)) (b.id, b.other.username, b.state)],
      [(blend.id, 'owner', BlendState.invited)],
    );
    expect((await admin.post('/api/me/blends', {'with': guestUser.id})).statusCode, 200, reason: 'again: the same');
    expect(await blendsOf(admin), hasLength(1));

    // The owner plays First most and loves Second; the guest plays Third most, and First once.
    await play(admin, 'First', 3);
    await admin.put('/api/me/favorites/${id('Second')}');
    await play(guest, 'Third', 2);
    await play(guest, 'First', 1);

    final accepted = Blend.fromJson(json(await guest.post('/api/me/blends', {'with': adminId})));
    expect((accepted.id, accepted.state), (blend.id, BlendState.active));
    // What both play, then the owner's, then the guest's.
    expect(accepted.trackIds, [id('First'), id('Second'), id('Third')]);
    expect((await blendsOf(admin)).single.trackIds, accepted.trackIds, reason: 'the same mix for both');

    // The guest hides First: neither of them gets it in the Blend.
    expect((await guest.put('/api/me/hidden/track/${id('First')}')).statusCode, 200);
    expect((await blendsOf(admin)).single.trackIds, [id('Second'), id('Third')]);
    expect((await blendsOf(guest)).single.trackIds, [id('Second'), id('Third')]);
    // Its whole artist (the test files have no tags: one artist for all).
    final artist = artistIdOf(tracks['Third']!.primaryArtist);
    expect((await admin.put('/api/me/hidden/artist/$artist')).statusCode, 200);
    expect((await blendsOf(guest)).single.trackIds, isEmpty);
  });

  test('either one leaves, which ends it for both; nobody else can, and the rules hold', () async {
    final blend = Blend.fromJson(json(await admin.post('/api/me/blends', {'with': guestUser.id})));
    final (third, _) = await registerGuest(server, admin, 'third');
    expect((await third.delete('/api/me/blends/${blend.id}')).statusCode, 404);
    expect(await blendsOf(third), isEmpty);

    Future<(int, String)> invite(Api client, Object? to) async {
      final response = await client.post('/api/me/blends', {'with': to});
      return (response.statusCode, json(response)['code'] as String);
    }

    expect(await invite(admin, adminId), (400, 'blendAccountInvalid'));
    expect(await invite(admin, 'nobody'), (400, 'blendAccountInvalid'));
    expect(await invite(admin, 7), (400, 'blendAccountInvalid'));

    expect((await guest.delete('/api/me/blends/${blend.id}')).statusCode, 200, reason: 'turning it down');
    expect([...await blendsOf(admin), ...await blendsOf(guest)], isEmpty);
    expect(json(await admin.delete('/api/me/blends/${blend.id}'))['code'], 'blendNotFound');

    // At the limit, a new one is refused.
    final db = server.server.database.connection;
    for (var i = 0; i < BlendRules.maxBlends; i++) {
      db.execute('INSERT INTO blends (id, inviter_id, invitee_id, invited_at) VALUES (?, ?, ?, 0)', [
        'b$i',
        adminId,
        'gone-$i',
      ]);
    }
    expect(await invite(admin, guestUser.id), (409, 'blendsLimit'));
  });

  test('blocking ends a Blend, an invitation waits while blocked, and a deleted account takes its Blends', () async {
    await admin.post('/api/me/blends', {'with': guestUser.id});
    await guest.post('/api/me/blends', {'with': adminId});
    expect((await guest.put('/api/me/blocked/$adminId')).statusCode, 200);
    expect([...await blendsOf(admin), ...await blendsOf(guest)], isEmpty);

    // The owner, blocked, invites again: its invitation waits, as far as it can tell; the guest never sees it.
    final sent = await admin.post('/api/me/blends', {'with': guestUser.id});
    expect((sent.statusCode, Blend.fromJson(json(sent)).state), (200, BlendState.inviting));
    expect((await blendsOf(admin)).single.state, BlendState.inviting);
    expect(await blendsOf(guest), isEmpty);
    await guest.post('/api/me/blends', {'with': adminId});
    expect((await blendsOf(admin)).single.state, BlendState.inviting, reason: 'not accepted while blocked');

    await guest.delete('/api/me/blocked/$adminId');
    expect((await blendsOf(guest)).single.state, BlendState.invited);
    await guest.post('/api/me/blends', {'with': adminId});
    expect((await blendsOf(admin)).single.state, BlendState.active);
    expect((await admin.delete('/api/users/${guestUser.id}')).statusCode, 200);
    expect(server.server.database.connection.select('SELECT COUNT(*) AS n FROM blends').first['n'], 0);
  });

  test("both accounts' players hear of an invitation, an acceptance and a leaving", () async {
    final (_, guestAuth) = await login(server, 'guest', guestPassword);
    final guestPhone = await Peer.connect(server, guestAuth.token, 'guest-phone');
    final ownerPhone = await Peer.connect(server, adminToken, 'owner-phone');
    addTearDown(() async {
      await guestPhone.close();
      await ownerPhone.close();
    });
    await until(() => guestPhone.ofType('devices').isNotEmpty && ownerPhone.ofType('devices').isNotEmpty);
    int heard(Peer peer) => peer.ofType('blendsChanged').length;

    final blend = Blend.fromJson(json(await admin.post('/api/me/blends', {'with': guestUser.id})));
    await until(() => heard(guestPhone) == 1 && heard(ownerPhone) == 1);
    await guest.post('/api/me/blends', {'with': adminId});
    await until(() => heard(guestPhone) == 2 && heard(ownerPhone) == 2);
    await admin.send('DELETE', '/api/me/blends/${blend.id}', headers: {RemoteRules.deviceHeader: 'owner-phone'});
    await until(() => heard(guestPhone) == 3);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(heard(ownerPhone), 2, reason: 'the phone that left knows');
  });
}
