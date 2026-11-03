// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// What an account listens to goes on to ListenBrainz, when it has connected one.
void main() {
  late FakeListenBrainz listenBrainz;
  late ServerFixture server;
  late Api admin;
  late String adminId;
  late List<Map<String, dynamic>> tracks;

  setUp(() async {
    listenBrainz = await FakeListenBrainz.start();
    server = await ServerFixture.start(listenBrainzUrl: listenBrainz.url);
    final (client, auth) = await setupAdmin(server);
    admin = client;
    adminId = auth.user.id;
    tracks = await server.waitForTracks(admin, 3);
  });
  tearDown(() async {
    await server.close();
    await listenBrainz.close();
  });

  String id(String title) => tracks.firstWhere((t) => t['title'] == title)['id'] as String;
  Future<void> waitForListens(int count) =>
      until(() => listenBrainz.listens.length >= count, reason: 'ListenBrainz was sent ${listenBrainz.listens.length}');

  group('connecting', () {
    test('keeps the token for a name ListenBrainz knows, and says who it is', () async {
      expect(json(await admin.get('/api/me/listenbrainz')), {'connected': false, 'userName': null});

      final response = await admin.put('/api/me/listenbrainz', {'token': '  good-token '});
      expect(response.statusCode, 200);
      expect(json(response), {'connected': true, 'userName': 'listener'});
      expect(listenBrainz.lastToken, 'good-token');
      expect(json(await admin.get('/api/me/listenbrainz')), {'connected': true, 'userName': 'listener'});

      expect(json(await admin.delete('/api/me/listenbrainz')), {'connected': false, 'userName': null});
      expect(json(await admin.get('/api/me/listenbrainz')), {'connected': false, 'userName': null});
    });

    test('refuses a token ListenBrainz does not know, an empty one and a damaged one', () async {
      for (final token in ['wrong-token', '', 'two words', 'x' * 300]) {
        final response = await admin.put('/api/me/listenbrainz', {'token': token});
        expect(response.statusCode, 400, reason: token);
        expect(json(response)['code'], 'listenBrainzTokenInvalid');
      }
      expect((await admin.put('/api/me/listenbrainz', {})).statusCode, 400);
      expect(json(await admin.get('/api/me/listenbrainz'))['connected'], isFalse);
    });

    test('says when ListenBrainz cannot be reached, and keeps nothing', () async {
      await listenBrainz.close();
      final response = await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      expect(response.statusCode, 502);
      expect(json(response)['code'], 'listenBrainzUnreachable');
      expect(json(await admin.get('/api/me/listenbrainz'))['connected'], isFalse);
    });

    test('belongs to the account: another one is not connected by it', () async {
      final (guest, _) = await registerGuest(server, admin);
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      expect(json(await guest.get('/api/me/listenbrainz'))['connected'], isFalse);
      await guest.post('/api/me/plays/${id('01 First')}');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(listenBrainz.listens, isEmpty);
    });
  });

  group('listening', () {
    test('sends a play with what a listener site shows: artist, title, album, length and the player', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      final before = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await admin.post('/api/me/plays/${id('01 First')}');
      await waitForListens(1);

      expect(listenBrainz.submissions.single['listen_type'], 'single');
      final listen = listenBrainz.listens.single;
      expect(listen['listened_at'], inInclusiveRange(before - 1, before + 10));
      final metadata = listen['track_metadata'] as Map<String, dynamic>;
      expect(metadata['track_name'], '01 First');
      expect(metadata['artist_name'], 'Unknown artist');
      expect(metadata['release_name'], isNull, reason: 'an unknown album is not sent');
      final info = metadata['additional_info'] as Map<String, dynamic>;
      expect(info['media_player'], 'Wiretune');
      expect(info['media_player_version'], WiretuneInfo.version);
      expect(info['duration_ms'], isA<int>());
    });

    test('keeps every play for the statistics, and sends none before the account connected', () async {
      await admin.post('/api/me/plays/${id('01 First')}'); // before connecting
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(listenBrainz.listens, isEmpty, reason: 'what was played before is never sent');

      await admin.post('/api/me/plays/${id('02 Second')}');
      await waitForListens(1);
      final rows = server.server.database.connection.select('SELECT sent FROM user_listens ORDER BY id');
      expect(rows.map((r) => r['sent']), [2, 1], reason: 'one not to be sent, one sent');
    });

    test('sends nothing after disconnecting, and what waited is dropped', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      listenBrainz.submitStatus = 503;
      await admin.post('/api/me/plays/${id('01 First')}');
      await until(() => listenBrainz.attempts >= 1);
      await admin.delete('/api/me/listenbrainz');
      expect(server.server.scrobbler.waiting, 0);
      listenBrainz.submitStatus = 200;
      await server.server.scrobbler.flush();
      expect(listenBrainz.listens, isEmpty);
    });

    test('sends what waited, as one import, once ListenBrainz works again', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      listenBrainz.submitStatus = 503;
      for (final title in ['01 First', '02 Second', '01 Third']) {
        await admin.post('/api/me/plays/${id(title)}');
      }
      await until(() => listenBrainz.attempts >= 1 && server.server.scrobbler.waiting == 3);
      expect(listenBrainz.listens, isEmpty);

      listenBrainz.submitStatus = 200;
      await server.server.scrobbler.flush();
      expect(server.server.scrobbler.waiting, 0);
      expect(listenBrainz.submissions.map((s) => s['listen_type']), ['import']);
      expect(listenBrainz.listens.map((l) => (l['track_metadata'] as Map)['track_name']), [
        '01 First',
        '02 Second',
        '01 Third',
      ]);
    });

    test('tries again by itself, later each time, until it works', () async {
      final scrobbler = Scrobbler(
        server.server.database,
        server.server.library.getTrack,
        endpoint: Uri.parse(listenBrainz.url),
        firstRetry: const Duration(milliseconds: 100),
      );
      addTearDown(scrobbler.close);
      await scrobbler.connect(adminId, 'good-token');
      listenBrainz.submitStatus = 500;
      scrobbler.listened(adminId, id('01 First'));
      await until(() => listenBrainz.attempts >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 350)); // two retries have failed by now
      expect(listenBrainz.listens, isEmpty);
      listenBrainz.submitStatus = 200;
      await waitForListens(1);
      expect(scrobbler.waiting, 0);
    });

    test('disconnects the account when ListenBrainz takes its token back', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      listenBrainz.tokens.clear();
      await admin.post('/api/me/plays/${id('01 First')}');
      await until(() => server.server.scrobbler.connectedName(adminId) == null);
      expect(listenBrainz.listens, isEmpty);
    });

    test('drops a listen ListenBrainz refuses, instead of sending it for ever', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      listenBrainz.submitStatus = 400;
      await admin.post('/api/me/plays/${id('01 First')}');
      await until(() => server.server.scrobbler.waiting == 0);
      final rows = server.server.database.connection.select('SELECT sent FROM user_listens');
      expect(rows.single['sent'], 2);
    });

    test('forgets a track that has left the library', () async {
      await admin.put('/api/me/listenbrainz', {'token': 'good-token'});
      listenBrainz.submitStatus = 503;
      await admin.post('/api/me/plays/${id('01 First')}');
      await until(() => listenBrainz.attempts >= 1 && server.server.scrobbler.waiting == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // the attempt has ended
      server.server.database.connection.execute("UPDATE user_listens SET track_id = 'not-there'");
      listenBrainz.submitStatus = 200;
      await server.server.scrobbler.flush();
      expect(server.server.scrobbler.waiting, 0);
      expect(listenBrainz.listens, isEmpty);
    });
  });

  test('a deleted account takes its listens and connection with it', () async {
    final (guest, user) = await registerGuest(server, admin);
    await guest.put('/api/me/listenbrainz', {'token': 'good-token'});
    await guest.post('/api/me/plays/${id('01 First')}');
    await waitForListens(1);
    expect((await admin.delete('/api/users/${user.id}')).statusCode, 200);
    final db = server.server.database.connection;
    expect(db.select('SELECT 1 FROM user_listens WHERE user_id = ?', [user.id]), isEmpty);
    expect(db.select('SELECT 1 FROM user_listenbrainz WHERE user_id = ?', [user.id]), isEmpty);
  });

  test('the address of a ListenBrainz-compatible server is an http or https one', () {
    ServerOptions parse(List<String> args) => ServerOptions.fromArgs(ServerOptions.parser.parse(args), const {});
    expect(parse([]).listenBrainzUrl, isNull);
    expect(
      parse(['--listenbrainz-url', 'https://maloja.example/apis/listenbrainz']).listenBrainzUrl,
      contains('maloja'),
    );
    for (final bad in ['maloja.example', 'ftp://x', 'http://']) {
      expect(() => parse(['--listenbrainz-url', bad]), throwsA(isA<FormatException>()), reason: bad);
    }
  });
}
