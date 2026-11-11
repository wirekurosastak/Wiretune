// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/src/artist_lookup_service.dart';
import 'package:wiretune_server/src/online.dart';
import 'package:wiretune_server/src/related_music_service.dart';
import 'package:wiretune_server/src/style_lookup_service.dart';

import 'support.dart';

/// What tells the players which music is alike: the artists Deezer's listeners relate, the styles MusicBrainz gives,
/// and the artists each account plays in the same sitting.
void main() {
  setUpAll(useTempDataDirectory);

  late DatabaseManager db;
  late LibraryService library;

  Track track(String id, String artist, String album, {TrackDetails details = const TrackDetails()}) => Track(
    id: id,
    title: 'Song $id',
    artist: artist,
    album: album,
    albumArtist: artist,
    filePath: '/music/$id.flac',
    details: details,
  );

  setUp(() {
    final folder = Directory.systemTemp.createTempSync('wiretune_related_');
    addTearDown(() => folder.deleteSync(recursive: true));
    db = DatabaseManager(p.join(folder.path, 'db.sqlite'))..initializeSchema();
    addTearDown(db.close);
    final repo = testRepository()
      ..replaceAllTracks([
        // Found by its album's barcode; by a track's ISRC; by the name, the one far better known; two of that name.
        track('a1', 'Alpha', 'Alpha One', details: const TrackDetails(barcode: '00602478496134')),
        track('b1', 'Beta', 'Beta One', details: const TrackDetails(isrc: 'GBAAA0000001')),
        track('c1', 'Gamma', 'Gamma One'),
        track('d1', 'Delta', 'Delta One'),
      ]);
    library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent')..initialize();
  });

  http.Response answer(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body ?? {'error': 'Not found'}), body == null ? 404 : status);

  group("Deezer's related artists", () {
    late List<String> asked;

    ArtistLookupService service() => ArtistLookupService(
      db,
      Deezer(
        MockClient((request) async {
          final path = request.url.hasQuery ? '${request.url.path}?${request.url.query}' : request.url.path;
          asked.add(path);
          final query = request.url.queryParameters['q'] ?? '';
          return answer(switch (request.url.path) {
            '/album/upc:0602478496134' => {
              'contributors': [
                {'id': 1, 'name': 'ALPHA'},
              ],
            },
            '/track/isrc:GBAAA0000001' => {
              'contributors': [
                {'id': 2, 'name': 'Beta'},
              ],
            },
            '/search/artist' when query.contains('Gamma') => {
              'data': [
                {'id': 3, 'name': 'Gamma', 'nb_fan': 90000},
                {'id': 30, 'name': 'Gamma', 'nb_fan': 12},
                {'id': 31, 'name': 'Gamma Tribute', 'nb_fan': 999999},
              ],
            },
            '/search/artist' when query.contains('Delta') => {
              'data': [
                {'id': 4, 'name': 'Delta', 'nb_fan': 5000},
                {'id': 40, 'name': 'Delta', 'nb_fan': 3000},
              ],
            },
            '/artist/1/related' => {
              'data': [
                for (final name in ['Beta', 'Omega', 'Psi']) {'name': name},
              ],
            },
            '/artist/2/related' => {'data': <Object>[]},
            '/artist/3/related' => {
              'data': [
                for (final name in ['Omega', 'Psi', 'Chi']) {'name': name},
              ],
            },
            _ => null,
          });
        }),
        pause: Duration.zero,
      ),
      enabled: () => true,
    );

    setUp(() => asked = []);

    test('each artist is found through a release of theirs, or an unmistakable name, and asked once', () async {
      final lookups = service();
      var learned = 0;
      await lookups.run(library.artists, onLearned: () => learned++);
      expect(lookups.relatedOf('alpha'), ['Beta', 'Omega', 'Psi']);
      expect(lookups.relatedOf('Gamma'), ['Omega', 'Psi', 'Chi'], reason: 'the far better known one');
      expect(lookups.relatedOf('Beta'), isNull, reason: 'Deezer relates nobody to it');
      expect(lookups.relatedOf('Delta'), isNull, reason: 'two of that name: neither is taken');
      expect(asked, isNot(contains(startsWith('/artist/40'))));
      expect(learned, greaterThan(0));

      // Kept: a new run, and a restart of the server, ask nothing.
      asked.clear();
      await lookups.run(library.artists, onLearned: () {});
      await service().run(library.artists, onLearned: () {});
      expect(asked, isEmpty);
      expect(service().relatedOf('alpha'), ['Beta', 'Omega', 'Psi']);
    });

    test("the library's artists are alike when Deezer relates one to the other, or both to the same artists", () async {
      final lookups = service();
      await lookups.run(library.artists, onLearned: () {});
      final styles = StyleLookupService(db, MusicBrainz(MockClient((_) async => answer(null))), enabled: () => true);
      final facts = RelatedMusicService(db, library, lookups, styles).facts();
      // Alpha lists Beta; Alpha and Gamma list the same two (Omega and Psi), artists the library doesn't have.
      expect(facts.similarArtists['alpha']!.keys, containsAll(['beta', 'gamma']));
      expect(facts.similarArtists['gamma']!.keys, ['alpha']);
      expect(facts.similarArtists['alpha']!['beta'], closeTo(1, 0.05), reason: 'first in its list');
      expect(facts.similarArtists.containsKey('delta'), isFalse);
      expect(facts.similarArtists['alpha']!.keys, isNot(contains('omega')), reason: 'only artists of the library');
    });
  });

  test(
    "MusicBrainz's genres of each album and its artists, by the release's barcode; busy, it is asked again",
    () async {
      final asked = <String>[];
      var busy = 1;
      final styles = StyleLookupService(
        db,
        MusicBrainz(
          MockClient((request) async {
            asked.add(request.url.path);
            final query = request.url.queryParameters['query'] ?? '';
            if (request.url.path == '/ws/2/release-group/rg-1' && busy-- > 0) return answer({'error': 'busy'}, 503);
            return answer(switch (request.url.path) {
              '/ws/2/release' when query == 'barcode:00602478496134' => {
                'releases': [
                  {
                    'title': 'Alpha One',
                    'release-group': {'id': 'rg-1'},
                    'artist-credit': [
                      {
                        'artist': {'id': 'ar-1', 'name': 'Alpha'},
                      },
                    ],
                  },
                ],
              },
              '/ws/2/release-group/rg-1' => {
                'genres': [
                  {'name': 'Synthwave', 'count': 5},
                  {'name': 'electronic', 'count': 2},
                  {'name': 'unused', 'count': 0},
                ],
              },
              '/ws/2/artist/ar-1' => {
                'genres': [
                  {'name': 'synth-pop', 'count': 3},
                ],
              },
              _ => null,
            });
          }),
          pause: Duration.zero,
          busyWaits: const [Duration.zero],
        ),
        enabled: () => true,
      );
      await styles.run(library.albums, onLearned: () {});
      final alpha = library.albums.firstWhere((a) => a.title == 'Alpha One');
      expect(styles.ofAlbum(alpha.id), [('synthwave', 5), ('electronic', 2)]);
      expect(styles.ofArtist('ALPHA'), [('synth-pop', 3)]);
      expect(asked.where((path) => path == '/ws/2/release-group/rg-1'), hasLength(2), reason: 'busy once');

      final lookups = ArtistLookupService(db, Deezer(MockClient((_) async => answer(null))), enabled: () => true);
      final facts = RelatedMusicService(db, library, lookups, styles).facts();
      expect(facts.albumStyles[alpha.id], {'synthwave': 5, 'electronic': 2});
      expect(facts.artistStyles['alpha'], {'synth-pop': 3});
    },
  );

  test("an account's artists played in the same sitting go together; the players get them, and the facts", () async {
    final root = Directory.systemTemp.createTempSync('wiretune_sittings_').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    for (final (file, artist) in [('a.wav', 'Alpha'), ('b.wav', 'Beta'), ('c.wav', 'Gamma'), ('d.wav', 'Delta')]) {
      writeWav(p.join(root, 'library', file), 44100, artist: artist, album: '$artist One', title: file);
    }
    final server = await ServerFixture.start(existingRoot: root);
    addTearDown(server.close);
    final (admin, _) = await setupAdmin(server);
    final ids = {for (final t in await server.waitForTracks(admin, 4)) (t['artist'] as String): t['id'] as String};
    final start = DateTime.now().toUtc().subtract(const Duration(days: 2));
    Future<void> play(String artist, Duration after) =>
        admin.post('/api/me/plays/${ids[artist]}', {'at': formatIsoUtc(start.add(after))});
    // Two sittings with Alpha and Beta together, one with Gamma and Delta; hours apart.
    await play('Alpha', Duration.zero);
    await play('Beta', const Duration(minutes: 4));
    await play('Alpha', const Duration(hours: 3));
    await play('Beta', const Duration(hours: 3, minutes: 5));
    await play('Gamma', const Duration(hours: 9));
    await play('Delta', const Duration(hours: 9, minutes: 6));

    final listening = await admin.get('/api/me/listening');
    final pairs = ListeningPairs.fromJson(json(listening));
    expect(pairs.artists['alpha']!.keys, ['beta']);
    expect(pairs.artists['alpha']!['beta'], greaterThan(pairs.artists['gamma']!['delta']!), reason: 'twice, not once');
    expect(pairs.artists['alpha']!.containsKey('gamma'), isFalse, reason: 'hours apart');
    final again = await admin.get('/api/me/listening', headers: {'if-none-match': listening.headers['etag']!});
    expect(again.statusCode, 304);

    final (guest, _) = await registerGuest(server, admin);
    expect(ListeningPairs.fromJson(json(await guest.get('/api/me/listening'))).artists, isEmpty, reason: 'its own');
    expect((await server.client().get('/api/me/listening')).statusCode, 401);

    final related = await admin.get('/api/library/related');
    expect(related.statusCode, 200);
    expect(RelatedMusicFacts.fromJson(json(related)).isEmpty, isTrue, reason: 'nothing looked up online here');
  });
}
