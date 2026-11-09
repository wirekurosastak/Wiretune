// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Shared playlists: an owner shares one with other accounts, who join it and change its tracks; only the owner
/// renames it, deletes it, or stops sharing it.
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late Api owner;
  late String ownerToken;
  late String ownerId;
  late Api guest;
  late UserInfo guestUser;
  late List<String> trackIds;

  setUp(() async {
    server = await ServerFixture.start();
    final (client, auth) = await setupAdmin(server);
    owner = client;
    ownerToken = auth.token;
    ownerId = auth.user.id;
    (guest, guestUser) = await registerGuest(server, owner);
    trackIds = [for (final t in await server.waitForTracks(owner, 3)) t['id'] as String];
    final created = await owner.put('/api/me/playlists/p1', {
      'name': 'Road trip',
      'trackIds': [trackIds[0]],
    });
    expect(created.statusCode, 200);
  });
  tearDown(() => server.close());

  Future<List<PlaylistData>> playlistsOf(Api client) async =>
      UserDataSnapshot.fromJson(json(await client.get('/api/me/data'))).playlists;
  Future<PlaylistData?> roadTrip(Api client) async =>
      (await playlistsOf(client)).where((p) => p.id == 'p1').firstOrNull;
  Future<List<PlaylistInvite>> invitesOf(Api client) async => [
    for (final i in json(await client.get('/api/me/playlist-invites')) as List) PlaylistInvite.fromJson(i),
  ];
  List<String> names(List<AccountInfo> accounts) => [for (final a in accounts) a.username];

  test(
    'a member joins, changes the tracks but not the name, and leaves; the owner stops sharing and deletes',
    () async {
      expect((await owner.put('/api/me/playlists/p1/members/${guestUser.id}')).statusCode, 200);
      expect(
        [for (final i in await invitesOf(guest)) (i.playlistId, i.name, i.owner.username, i.trackCount)],
        [('p1', 'Road trip', 'owner', 1)],
      );
      expect(await roadTrip(guest), isNull, reason: 'not before it joins');
      expect(names((await roadTrip(owner))!.sharing.invited), ['guest']);

      final joined = await guest.post('/api/me/playlist-invites/p1');
      expect(joined.statusCode, 200);
      expect(PlaylistData.fromJson(json(joined)).sharing.owner?.username, 'owner');
      expect(await invitesOf(guest), isEmpty);
      final sharing = (await roadTrip(owner))!.sharing;
      expect(names(sharing.members), ['guest']);
    expect((sharing.invited.length, sharing.owner), (0, null));

      // The guest adds a track; a new name is the owner's to give.
      final saved = await guest.put('/api/me/playlists/p1', {
        'name': 'Mine now',
        'trackIds': [trackIds[0], trackIds[1]],
      });
      expect(saved.statusCode, 200);
      final ownCopy = (await roadTrip(owner))!;
      expect(ownCopy.name, 'Road trip');
    expect(ownCopy.trackIds, [trackIds[0], trackIds[1]]);
      expect(server.server.database.connection.select('SELECT COUNT(*) AS n FROM user_playlists').first['n'], 1);

      // A third account joins: each member sees the owner and the others.
      final (third, thirdUser) = await registerGuest(server, owner, 'third');
      await owner.put('/api/me/playlists/p1/members/${thirdUser.id}');
      await third.post('/api/me/playlist-invites/p1');
      expect(names((await roadTrip(guest))!.sharing.members), ['third']);
      expect(names((await roadTrip(owner))!.sharing.members), ['guest', 'third']);

      // The guest leaves; the playlist stays the owner's and the third's.
      expect((await guest.delete('/api/me/playlists/p1')).statusCode, 200);
      expect(await roadTrip(guest), isNull);
      expect(names((await roadTrip(owner))!.sharing.members), ['third']);

      expect((await owner.delete('/api/me/playlists/p1/members/${thirdUser.id}')).statusCode, 200);
      expect(await roadTrip(third), isNull);
      await owner.put('/api/me/playlists/p1/members/${guestUser.id}');
      expect((await owner.delete('/api/me/playlists/p1')).statusCode, 200);
      expect((await invitesOf(guest)).length, 0);
    expect(await roadTrip(owner), isNull);
      expect(server.server.database.connection.select('SELECT COUNT(*) AS n FROM playlist_members').first['n'], 0);
    },
  );

  test(
    'only its owner shares a playlist, with other accounts, up to the limit; unknown invitations are not found',
    () async {
      Future<(int, String)> share(Api client, String playlistId, String to) async {
        final response = await client.put('/api/me/playlists/$playlistId/members/$to');
        return (response.statusCode, json(response)['code'] as String);
      }

      expect(await share(owner, 'p1', ownerId), (400, 'playlistMemberInvalid'));
      expect(await share(owner, 'p1', 'nobody'), (400, 'playlistMemberInvalid'));
      expect(await share(owner, 'nope', guestUser.id), (404, 'playlistNotFound'));
      expect(await share(guest, 'p1', ownerId), (404, 'playlistNotFound'), reason: "it isn't the guest's");
      expect(json(await guest.post('/api/me/playlist-invites/p1'))['code'], 'playlistInviteNotFound');
      expect(json(await guest.delete('/api/me/playlist-invites/p1'))['code'], 'playlistInviteNotFound');
      expect(json(await guest.delete('/api/me/playlists/p1'))['code'], 'playlistNotFound');

      // Turning it down: the owner sees it shared with nobody again.
      await owner.put('/api/me/playlists/p1/members/${guestUser.id}');
      expect((await guest.delete('/api/me/playlist-invites/p1')).statusCode, 200);
      expect((await roadTrip(owner))!.sharing.isEmpty, isTrue);

      final db = server.server.database.connection;
      for (var i = 0; i < UserDataRules.maxPlaylistMembers; i++) {
        db.execute('INSERT INTO playlist_members (owner_id, playlist_id, user_id, invited_at) VALUES (?, ?, ?, 0)', [
          ownerId,
          'p1',
          'gone-$i',
        ]);
      }
      expect(await share(owner, 'p1', guestUser.id), (409, 'playlistMembersLimit'));
    },
  );

  test('blocking ends the sharing either way, an invitation from a blocked owner never shows, and a deleted account '
      'takes its sharing', () async {
    await owner.put('/api/me/playlists/p1/members/${guestUser.id}');
    await guest.post('/api/me/playlist-invites/p1');
    expect((await guest.put('/api/me/blocked/$ownerId')).statusCode, 200);
    expect(await roadTrip(guest), isNull);
    expect((await roadTrip(owner))!.sharing.isEmpty, isTrue);

    await owner.put('/api/me/playlists/p1/members/${guestUser.id}');
    expect(await invitesOf(guest), isEmpty, reason: 'from an account it blocks');
    expect(json(await guest.post('/api/me/playlist-invites/p1'))['code'], 'playlistInviteNotFound');

    await guest.delete('/api/me/blocked/$ownerId');
    expect(await invitesOf(guest), hasLength(1));
    expect((await owner.delete('/api/users/${guestUser.id}')).statusCode, 200);
    expect(server.server.database.connection.select('SELECT COUNT(*) AS n FROM playlist_members').first['n'], 0);
  });

  test("the members' players hear of a change, the invited one's of its invitation", () async {
    final (_, guestAuth) = await login(server, 'guest', guestPassword);
    final guestPhone = await Peer.connect(server, guestAuth.token, 'guest-phone');
    final ownerPhone = await Peer.connect(server, ownerToken, 'owner-phone');
    addTearDown(() async {
      await guestPhone.close();
      await ownerPhone.close();
    });
    await until(() => guestPhone.ofType('devices').isNotEmpty && ownerPhone.ofType('devices').isNotEmpty);
    int heard(Peer peer, String type) => peer.ofType(type).length;

    await owner.put('/api/me/playlists/p1/members/${guestUser.id}');
    await until(() => heard(guestPhone, 'playlistInvitesChanged') == 1);
    final before = heard(ownerPhone, 'dataChanged'); // whom it is shared with changed
    await guest.send('POST', '/api/me/playlist-invites/p1', headers: {RemoteRules.deviceHeader: 'guest-phone'});
    await until(() => heard(ownerPhone, 'dataChanged') == before + 1, reason: 'a member joined');

    await owner.put('/api/me/playlists/p1', {
      'name': 'Road trip',
      'trackIds': [trackIds[2]],
    });
    await until(() => heard(guestPhone, 'dataChanged') == 1);
    expect((await roadTrip(guest))!.trackIds, [trackIds[2]]);
  });
}
