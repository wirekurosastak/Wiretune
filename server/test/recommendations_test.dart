// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// What the accounts of a server recommend to each other: an artist, an album or a track, with a note.
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late Api admin;
  late String adminToken;
  late Api guest;
  late UserInfo guestUser;
  late List<Map<String, dynamic>> tracks;

  setUp(() async {
    server = await ServerFixture.start();
    final (client, auth) = await setupAdmin(server);
    admin = client;
    adminToken = auth.token;
    (guest, guestUser) = await registerGuest(server, admin);
    tracks = await server.waitForTracks(admin, 3);
  });
  tearDown(() => server.close());

  String trackId(int i) => tracks[i]['id'] as String;
  Future<List<Recommendation>> received(Api client) async => [
    for (final r in json(await client.get('/api/me/recommendations')) as List) Recommendation.fromJson(r),
  ];

  test('every account sees the others by name', () async {
    final accounts = [for (final a in json(await guest.get('/api/accounts')) as List) AccountInfo.fromJson(a)];
    expect(accounts.map((a) => a.username), ['guest', 'owner']);
    expect(accounts.first.toJson().keys, ['id', 'username'], reason: 'nothing more than the name');
  });

  test('a track, an album or an artist goes to the accounts chosen, newest first, with the note', () async {
    final track = tracks.first;
    var sent = await admin.post('/api/me/recommendations', {
      'kind': 'track',
      'itemId': track['id'],
      'to': [guestUser.id],
      'note': '  for the drive\u0007 ',
    });
    expect(sent.statusCode, 200);
    expect((json(sent)['ids'] as List), hasLength(1));
    final albumId = Track.fromJson(track).albumId;
    sent = await admin.post('/api/me/recommendations', {
      'kind': 'album',
      'itemId': albumId,
      'to': [guestUser.id],
    });
    expect(sent.statusCode, 200);

    final inbox = await received(guest);
    expect(inbox.map((r) => (r.kind, r.itemId, r.note, r.from.username, r.seen)), [
      (RecommendationKind.album, albumId, '', 'owner', false),
      (RecommendationKind.track, track['id'], 'for the drive', 'owner', false),
    ]);
    expect(await received(admin), isEmpty, reason: 'the sender keeps no copy');

    expect((await guest.post('/api/me/recommendations/seen')).statusCode, 200);
    expect((await received(guest)).every((r) => r.seen), isTrue);
  });

  test('refuses what is not in the library, a bad kind, a long note and recipients that are not others', () async {
    Future<(int, String?)> send(Map<String, Object?> body) async {
      final response = await admin.post('/api/me/recommendations', {
        'kind': 'track',
        'itemId': trackId(0),
        'to': [guestUser.id],
        ...body,
      });
      return (response.statusCode, response.statusCode == 200 ? null : json(response)['code'] as String);
    }

    expect(await send({'kind': 'playlist'}), (400, 'invalidItemType'));
    expect(await send({'itemId': ''}), (400, 'invalidId'));
    expect(await send({'itemId': 'nope'}), (404, 'notFound'));
    expect(await send({'kind': 'artist', 'itemId': 'nope'}), (404, 'notFound'));
    expect(await send({'note': 'x' * (RecommendationRules.maxNoteLength + 1)}), (400, 'recommendationNoteTooLong'));
    for (final to in [
      <String>[],
      ['nobody'],
      [guestUser.id, guestUser.id],
      'not a list',
    ]) {
      expect((await send({'to': to})).$2, 'recommendationRecipientsInvalid', reason: '$to');
    }
    final adminId = UserInfo.fromJson(json(await admin.get('/api/auth/me'))).id;
    expect(
      await send({
        'to': [adminId],
      }),
      (400, 'recommendationRecipientsInvalid'),
      reason: 'not to oneself',
    );
    expect(await received(guest), isEmpty);
  });

  test('the recipient dismisses one, the sender takes one back, and nobody else touches it', () async {
    final (other, _) = await registerGuest(server, admin, 'other');
    final sent = await admin.post('/api/me/recommendations', {
      'kind': 'track',
      'itemId': trackId(0),
      'to': [guestUser.id],
    });
    final id = (json(sent)['ids'] as List).single as String;
    expect((await other.delete('/api/me/recommendations/$id')).statusCode, 404);
    expect((await admin.delete('/api/me/recommendations/$id')).statusCode, 200, reason: "the sender's Undo");
    expect(await received(guest), isEmpty);

    final again = await admin.post('/api/me/recommendations', {
      'kind': 'track',
      'itemId': trackId(1),
      'to': [guestUser.id],
    });
    final second = (json(again)['ids'] as List).single as String;
    expect((await guest.delete('/api/me/recommendations/$second')).statusCode, 200);
    expect((await guest.delete('/api/me/recommendations/$second')).statusCode, 404);
  });

  test('an account keeps its newest ones, and they go with a deleted account', () async {
    final db = server.server.database.connection;
    final adminId = UserInfo.fromJson(json(await admin.get('/api/auth/me'))).id;
    db.execute('BEGIN');
    for (var i = 0; i < RecommendationRules.maxKept; i++) {
      db.execute(
        "INSERT INTO recommendations (id, from_user_id, to_user_id, item_type, item_id, sent_at) VALUES (?, ?, ?, 'track', ?, ?)",
        ['old-$i', adminId, guestUser.id, trackId(0), i],
      );
    }
    db.execute('COMMIT');
    await admin.post('/api/me/recommendations', {
      'kind': 'track',
      'itemId': trackId(2),
      'to': [guestUser.id],
    });
    final inbox = await received(guest);
    expect(inbox, hasLength(RecommendationRules.maxKept));
    expect(inbox.first.itemId, trackId(2));
    expect(inbox.any((r) => r.id == 'old-0'), isFalse, reason: 'the oldest made room');

    expect((await admin.delete('/api/users/${guestUser.id}')).statusCode, 200);
    expect(db.select('SELECT COUNT(*) AS n FROM recommendations').first['n'], 0);
  });

  test("the recipient's players hear of one at once; the bell opened on one tells its others", () async {
    final (_, guestAuth) = await login(server, 'guest', guestPassword);
    final phone = await Peer.connect(server, guestAuth.token, 'guest-phone');
    final desktop = await Peer.connect(server, guestAuth.token, 'guest-desktop');
    final owner = await Peer.connect(server, adminToken, 'owner-phone');
    addTearDown(() async {
      await phone.close();
      await desktop.close();
      await owner.close();
    });
    await until(() => phone.ofType('devices').isNotEmpty && desktop.ofType('devices').isNotEmpty);

    await admin.post('/api/me/recommendations', {
      'kind': 'track',
      'itemId': trackId(0),
      'to': [guestUser.id],
    });
    await until(
      () => phone.ofType('recommendationsChanged').length == 1 && desktop.ofType('recommendationsChanged').length == 1,
    );

    await guest.send('POST', '/api/me/recommendations/seen', headers: {RemoteRules.deviceHeader: 'guest-phone'});
    await until(() => desktop.ofType('recommendationsChanged').length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(phone.ofType('recommendationsChanged'), hasLength(1), reason: 'the phone opened it itself');
    expect(owner.ofType('recommendationsChanged'), isEmpty);
  });
}
