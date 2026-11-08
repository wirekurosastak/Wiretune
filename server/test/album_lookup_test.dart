// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/src/album_lookup_service.dart';

import 'support.dart';

/// The server looks each album up on Deezer once, and gives the tracks whose files name no genre or label the album's.
void main() {
  setUpAll(useTempDataDirectory);

  test(
    "an album found by its title and artist lends its genre and label to its tracks; one not found doesn't",
    () async {
      final asked = <String>[];
      // Two albums with tags, and an untagged file, which makes an album of no name to look for.
      final root = Directory.systemTemp.createTempSync('wiretune_lookup_').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      for (final (file, album) in [('a1.wav', 'Album 1'), ('a2.wav', 'Album 1'), ('b1.wav', 'Album 2')]) {
        writeWav(p.join(root, 'library', file), 44100, artist: 'Artist A', album: album, title: file);
      }
      writeWav(p.join(root, 'library', 'untagged.wav'), 44100);
      final server = await ServerFixture.start(
        existingRoot: root,
        deezer: (path) {
          asked.add(path);
          final query = Uri.parse('https://api.deezer.com$path').queryParameters['q'] ?? '';
          if (path.startsWith('/search/album') && query.contains('Album 1')) {
            return {
              'data': [
                {
                  'id': 7,
                  'title': 'ALBUM 1',
                  'artist': {'name': 'artist a'},
                },
              ],
            };
          }
          if (path == '/album/7') {
            return {
              'genres': {
                'data': [
                  {'name': 'Rock'},
                  {'name': 'Indie'},
                ],
              },
              'label': 'Some Label',
            };
          }
          return null;
        },
      );
      addTearDown(server.close);
      final (admin, _) = await setupAdmin(server);
      final before = await server.waitForTracks(admin, 4);
      expect(before.every((t) => t['genre'] == null), isTrue, reason: 'the files name no genre');

      // The lookups run after the scan, in the background.
      late List<Track> tracks;
      for (var i = 0; i < 50; i++) {
        tracks = [for (final t in await server.waitForTracks(admin, 4)) Track.fromJson(t)];
        if (tracks.any((t) => t.genre != null) && asked.where((p) => p.startsWith('/search/album')).length == 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final track in tracks) {
        final found = track.album == 'Album 1';
        expect(track.genre, found ? 'Rock' : null, reason: track.album);
        expect(track.details.label, found ? 'Some Label' : null, reason: track.album);
      }
      expect(asked.where((p) => p.startsWith('/search/album')), hasLength(2), reason: 'each album once: $asked');

      // Turned off, it asks no more; what it found stays.
      var config = ServerConfigInfo.fromJson(json(await admin.get('/api/config')));
      expect(config.lookUpAlbums, isTrue, reason: 'on at first');
      config = ServerConfigInfo.fromJson(json(await admin.post('/api/config/album-lookups', {'enabled': false})));
      expect(config.lookUpAlbums, isFalse);
      expect([for (final t in await server.waitForTracks(admin, 4)) Track.fromJson(t).genre].whereType<String>(), [
        'Rock',
        'Rock',
      ]);
    },
  );

  test("a barcode is tried as tagged and as Deezer's 13- and 12-digit forms", () {
    expect(AlbumLookupService.barcodeForms('00602478496134'), ['00602478496134', '0602478496134', '602478496134']);
    expect(AlbumLookupService.barcodeForms('00044003362253'), ['00044003362253', '0044003362253', '044003362253']);
    expect(AlbumLookupService.barcodeForms('3617383692257'), ['3617383692257'], reason: 'a 13-digit EAN as it is');
    expect(AlbumLookupService.barcodeForms('n/a'), isEmpty);
  });

  test('names are the same but for case, accents and punctuation', () {
    expect(AlbumLookupService.sameName('Beyoncé', 'BEYONCE'), isTrue);
    expect(AlbumLookupService.sameName('AC/DC', 'ACDC'), isTrue);
    expect(AlbumLookupService.sameName('Album 1', 'Album 2'), isFalse);
  });
}
