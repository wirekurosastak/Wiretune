// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/src/credit_lookup_service.dart';

import 'support.dart';

/// A track's credits: its tags' composer, and what MusicBrainz knows, asked once when a player wants them.
void main() {
  setUpAll(useTempDataDirectory);

  /// A MusicBrainz recording with a producer, a mixer, a guitarist, and its work's composer and lyricist.
  const recording = {
    'id': 'rec-1',
    'relations': [
      {
        'type': 'producer',
        'target-type': 'artist',
        'artist': {'name': 'Questlove'},
      },
      {
        'type': 'mix',
        'target-type': 'artist',
        'artist': {'name': 'Russell Elevado'},
      },
      {
        'type': 'instrument',
        'target-type': 'artist',
        'attributes': ['guitar'],
        'artist': {'name': 'Cody ChestnuTT'},
      },
      {
        'type': 'performance',
        'target-type': 'work',
        'work': {
          'relations': [
            {
              'type': 'composer',
              'artist': {'name': 'Cody ChestnuTT'},
            },
            {
              'type': 'lyricist',
              'artist': {'name': 'Black Thought'},
            },
          ],
        },
      },
      {
        'type': 'some-new-kind',
        'target-type': 'artist',
        'artist': {'name': 'Nobody'},
      },
    ],
  };

  late DatabaseManager db;
  late List<String> asked;
  var enabled = true;

  setUp(() {
    final folder = Directory.systemTemp.createTempSync('wiretune_credits_');
    addTearDown(() => folder.deleteSync(recursive: true));
    db = DatabaseManager(p.join(folder.path, 'db.sqlite'))..initializeSchema();
    addTearDown(db.close);
    asked = [];
    enabled = true;
  });

  CreditLookupService service() => CreditLookupService(
    db,
    enabled: () => enabled,
    pause: Duration.zero,
    client: MockClient((request) async {
      asked.add(request.url.path);
      final body = switch (request.url.path) {
        '/ws/2/isrc/USMC10201424' => {
          'recordings': [
            {'id': 'rec-1'},
          ],
        },
        '/ws/2/recording/rec-1' => recording,
        _ => null,
      };
      return http.Response(jsonEncode(body ?? {'error': 'Not Found'}), body == null ? 404 : 200);
    }),
  );

  test('found by ISRC: who wrote it, then who made the recording, with the instrument; asked only once', () async {
    final track = Track(
      id: 't1',
      details: const TrackDetails(isrc: 'USMC10201424', composer: 'Someone Else'),
    );
    final credits = await service().creditsOf(track);
    expect(credits, const [
      Credit(CreditRoles.composer, 'Cody ChestnuTT'),
      Credit(CreditRoles.lyricist, 'Black Thought'),
      Credit(CreditRoles.producer, 'Questlove'),
      Credit(CreditRoles.instrument, 'Cody ChestnuTT', detail: 'Guitar'),
      Credit(CreditRoles.mix, 'Russell Elevado'),
    ]);
    expect(asked, ['/ws/2/isrc/USMC10201424', '/ws/2/recording/rec-1']);

    // Kept: a second player's question asks MusicBrainz nothing.
    expect(await service().creditsOf(track), credits);
    expect(asked, hasLength(2));
  });

  test("the tags' composers when MusicBrainz isn't asked: lookups off, or no code to ask by", () async {
    enabled = false;
    final coded = Track(
      id: 't2',
      details: const TrackDetails(isrc: 'USMC10201424', composer: 'A. Writer; B. Writer'),
    );
    expect(await service().creditsOf(coded), const [
      Credit(CreditRoles.composer, 'A. Writer'),
      Credit(CreditRoles.composer, 'B. Writer'),
    ]);
    enabled = true;
    expect(await service().creditsOf(Track(id: 't3')), isEmpty);
    expect(asked, isEmpty);
  });

  test("a recording MusicBrainz doesn't know is asked again only after a while", () async {
    final track = Track(
      id: 't4',
      details: const TrackDetails(musicBrainzTrackId: 'unknown'),
    );
    expect(await service().creditsOf(track), isEmpty);
    expect(await service().creditsOf(track), isEmpty);
    expect(asked, ['/ws/2/recording/unknown']);
  });

  test("the server answers a track's credits, and an unknown track's with 404", () async {
    final server = await ServerFixture.start();
    addTearDown(server.close);
    final (admin, _) = await setupAdmin(server);
    final id = (await server.waitForTracks(admin, 3)).first['id'] as String;
    final answer = await admin.get('/api/tracks/$id/credits');
    expect(answer.statusCode, 200);
    expect(json(answer), {'credits': <Object?>[]}, reason: 'its file names no composer and no code');
    expect((await admin.get('/api/tracks/nope/credits')).statusCode, 404);
  });
}
