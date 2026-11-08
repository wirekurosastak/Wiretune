// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Related artists and similar albums, from what the tracks say: who they credit together, the genre, the era.
void main() {
  setUpAll(useTempDataDirectory);

  late LibraryService library;

  /// The library, with the genres or without any.
  LibraryService build({bool genres = true}) {
    Track track(String id, String artist, String album, {List<String>? artists, String? genre, int? year}) => Track(
      id: id,
      title: 'Song $id',
      artist: artist,
      artists: artists,
      album: album,
      albumArtist: artist,
      genre: genres ? genre : null,
      releaseYear: year,
      filePath: '/music/$id.flac',
    );
    final repo = testRepository()
      ..replaceAllTracks([
        // The Roots: an album with Cody ChestnuTT as a guest; Cody's own album; Common has The Roots as a guest.
        track('r1', 'The Roots', 'Phrenology', artists: ['The Roots', 'Cody ChestnuTT'], genre: 'Hip Hop', year: 2002),
        track('r2', 'The Roots', 'Phrenology', genre: 'Hip Hop', year: 2002),
        track('c1', 'Cody ChestnuTT', 'The Headphone Masterpiece', genre: 'Soul', year: 2002),
        track(
          'm1',
          'Common',
          'Like Water for Chocolate',
          artists: ['Common', 'The Roots'],
          genre: 'Hip Hop',
          year: 2000,
        ),
        // Same genre, near in time; same genre, far in time; another genre, no credits.
        track('o1', 'Outkast', 'Stankonia', genre: 'Hip Hop', year: 2000),
        track('w1', 'Wu-Tang Clan', 'Enter the Wu-Tang', genre: 'hip hop', year: 1993),
        track('n1', 'Norah Jones', 'Come Away With Me', genre: 'Jazz', year: 2002),
        track('r3', 'The Roots', 'Things Fall Apart', genre: 'Hip Hop', year: 1999),
      ]);
    return LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent')..initialize();
  }

  setUp(() => library = build());

  Artist artist(String name) => library.artists.firstWhere((a) => a.name == name);
  Album album(String title) => library.albums.firstWhere((a) => a.title == title);

  test("an artist's guests and the artists it was a guest of come first, then its genre, the nearer in time first", () {
    final related = Related.artists(artist('The Roots'), library.artists, library.tracks);
    // Cody and Common are both credited with The Roots, and share the genre; Cody's album came out the same year.
    expect(related.map((a) => a.name), ['Cody ChestnuTT', 'Common', 'Outkast', 'Wu-Tang Clan']);
    expect(related.map((a) => a.name), isNot(contains('Norah Jones')), reason: 'only the era is shared');
    expect(related.map((a) => a.name), isNot(contains('The Roots')));
  });

  test("without genres, only the names credited together relate artists", () {
    library = build(genres: false);
    expect(Related.artists(artist('The Roots'), library.artists, library.tracks).map((a) => a.name), [
      'Cody ChestnuTT',
      'Common',
    ]);
  });

  test("an album's similar ones are other artists': credited together, then the same genre; More by is its own", () {
    expect(Related.moreBy(album('Phrenology'), library.albums).map((a) => a.title), ['Things Fall Apart']);
    final similar = Related.albums(album('Phrenology'), library.albums).map((a) => a.title).toList();
    expect(similar.first, 'The Headphone Masterpiece', reason: 'its guest');
    expect(similar, containsAll(['Like Water for Chocolate', 'Stankonia', 'Enter the Wu-Tang']));
    expect(similar, isNot(contains('Things Fall Apart')), reason: 'More by has it');
    expect(similar, isNot(contains('Come Away With Me')));
    expect(similar.indexOf('Stankonia'), lessThan(similar.indexOf('Enter the Wu-Tang')), reason: 'nearer in time');
  });

  test('a row is worked out once for each artist and album the library makes', () {
    final roots = artist('The Roots');
    final first = Related.artistsOf(roots, library.artists, library.tracks);
    expect(identical(Related.artistsOf(roots, const [], const []), first), isTrue);
  });
}
