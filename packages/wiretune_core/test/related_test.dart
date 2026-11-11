// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Which music is alike: Related artists, Similar albums and Autoplay, from the tracks themselves (credits, genre, era,
/// tempo), from what the server learned online, and from what the account plays together.
void main() {
  setUpAll(useTempDataDirectory);

  Track track(
    String id,
    String artist,
    String album, {
    List<String>? artists,
    String? genre,
    int? year,
    int? bpm,
    int number = 1,
  }) => Track(
    id: id,
    title: 'Song $id',
    artist: artist,
    artists: artists,
    album: album,
    albumArtist: artist,
    genre: genre,
    releaseYear: year,
    bpm: bpm,
    trackNumber: number,
    filePath: '/music/$id.flac',
  );

  LibraryService libraryOf(List<Track> tracks) {
    final repo = testRepository()..replaceAllTracks(tracks);
    return LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent')..initialize();
  }

  group('from the tracks alone', () {
    late LibraryService library;

    LibraryService build({bool genres = true}) => libraryOf([
      // The Roots: an album with Cody ChestnuTT as a guest; Cody's own album; Common has The Roots as a guest.
      track(
        'r1',
        'The Roots',
        'Phrenology',
        artists: ['The Roots', 'Cody ChestnuTT'],
        genre: genres ? 'Hip Hop' : null,
        year: 2002,
      ),
      track('r2', 'The Roots', 'Phrenology', genre: genres ? 'Hip Hop' : null, year: 2002, number: 2),
      track('c1', 'Cody ChestnuTT', 'The Headphone Masterpiece', genre: genres ? 'Soul' : null, year: 2002),
      track(
        'm1',
        'Common',
        'Like Water for Chocolate',
        artists: ['Common', 'The Roots'],
        genre: genres ? 'Hip Hop' : null,
        year: 2000,
      ),
      // Same genre, near in time; same genre, far in time; another genre, no credits.
      track('o1', 'Outkast', 'Stankonia', genre: genres ? 'Hip Hop' : null, year: 2000),
      track('w1', 'Wu-Tang Clan', 'Enter the Wu-Tang', genre: genres ? 'hip-hop' : null, year: 1993),
      track('n1', 'Norah Jones', 'Come Away With Me', genre: genres ? 'Jazz' : null, year: 2002),
      track('r3', 'The Roots', 'Things Fall Apart', genre: genres ? 'Hip Hop' : null, year: 1999),
    ]);

    setUp(() => library = build());

    Artist artist(String name) => library.artists.firstWhere((a) => a.name == name);
    Album album(String title) => library.albums.firstWhere((a) => a.title == title);
    List<String> related(String name) => [for (final a in library.related.artistsLike(artist(name))) a.name];

    test('those credited together come first, then the genre alone, the nearer in time first', () {
      // Common has The Roots on a track and shares the genre; Cody ChestnuTT is a guest on a hip-hop track of theirs;
      // Outkast and Wu-Tang only share the genre ("hip-hop" is the same), Wu-Tang from further back.
      expect(related('The Roots'), ['Common', 'Cody ChestnuTT', 'Outkast', 'Wu-Tang Clan']);
      expect(related('The Roots'), isNot(contains('Norah Jones')), reason: 'only the era is shared');
    });

    test('without genres, only the names credited together relate artists', () {
      library = build(genres: false);
      expect(related('The Roots'), ['Cody ChestnuTT', 'Common']);
    });

    test(
      "an album's similar ones are other artists': its guests' and its hosts', then the genre; More by is its own",
      () {
        expect([for (final a in library.related.moreBy(album('Phrenology'))) a.title], ['Things Fall Apart']);
        final similar = [for (final a in library.related.albumsLike(album('Phrenology'))) a.title];
        // The Roots are a guest on Common's album, hip hop too; Cody ChestnuTT is a guest on this one.
        expect(similar.take(2), ['Like Water for Chocolate', 'The Headphone Masterpiece']);
        expect(similar, containsAll(['Stankonia', 'Enter the Wu-Tang']), reason: 'the genre');
        expect(similar, isNot(contains('Things Fall Apart')), reason: 'More by has it');
        expect(similar, isNot(contains('Come Away With Me')));
        expect(similar.indexOf('Stankonia'), lessThan(similar.indexOf('Enter the Wu-Tang')), reason: 'nearer in time');
      },
    );

    test('the rows are worked out once for each library, and anew when it changes', () {
      final roots = artist('The Roots');
      final first = library.related.artistsLike(roots);
      expect(identical(library.related.artistsLike(roots), first), isTrue);
      library.setRelatedMusic(
        facts: const RelatedMusicFacts(
          similarArtists: {
            'the roots': {'norah jones': 1},
          },
        ),
      );
      expect(related('The Roots').first, 'Norah Jones', reason: 'what the server learned');
    });
  });

  test("a style few artists have relates them more than one all of them have", () {
    final library = libraryOf([
      for (final (i, name) in ['A', 'B', 'C', 'D', 'E', 'F'].indexed) track('$i', name, 'Album $name', genre: 'Pop'),
    ]);
    library.setRelatedMusic(
      facts: const RelatedMusicFacts(
        artistStyles: {
          'a': {'synthwave': 10, 'pop': 2},
          'b': {'synthwave': 6},
          'c': {'pop': 9},
        },
      ),
    );
    final related = library.related;
    expect(related.artistSimilarity('a', 'b'), greaterThan(related.artistSimilarity('c', 'd')));
    expect(related.artistSimilarity('c', 'd'), lessThan(0.5), reason: 'everyone is pop: that says little');
    expect(related.artistsLike(library.artists.first).first.name, 'B');
  });

  test("Deezer's listeners and the account's own listening relate artists the tags know nothing of", () {
    final library = libraryOf([
      for (final name in ['A', 'B', 'C', 'D']) track(name, name, 'Album $name'),
    ]);
    final a = library.artists.firstWhere((x) => x.name == 'A');
    expect(library.related.artistsLike(a), isEmpty, reason: 'nothing links them');

    library.setRelatedMusic(
      facts: const RelatedMusicFacts(
        similarArtists: {
          'a': {'b': 0.9},
        },
      ),
    );
    expect([for (final x in library.related.artistsLike(a)) x.name], ['B']);
    // Either way round: what B is like, A is like.
    expect([for (final x in library.related.artistsLike(library.artists[1])) x.name], ['A']);

    library.setRelatedMusic(
      pairs: const ListeningPairs({
        'c': {'a': 0.7},
      }),
    );
    expect([for (final x in library.related.artistsLike(a)) x.name], ['B', 'C']);
    // Both signs together outweigh either.
    library.setRelatedMusic(
      pairs: const ListeningPairs({
        'c': {'a': 0.7},
        'b': {'a': 0.3},
      }),
    );
    expect(library.related.artistSimilarity('a', 'b'), greaterThan(library.related.artistSimilarity('a', 'c')));
  });

  test("the listening pairs are the signed-in account's: another account doesn't see them", () {
    final library = libraryOf([
      for (final name in ['A', 'B']) track(name, name, 'Album $name'),
    ]);
    library.setCurrentUser('anna');
    library.setRelatedMusic(
      pairs: const ListeningPairs({
        'a': {'b': 0.8},
      }),
    );
    expect(library.related.artistSimilarity('a', 'b'), greaterThan(0));
    library.setCurrentUser('ben');
    expect(library.related.artistSimilarity('a', 'b'), 0);
    library.setCurrentUser('anna');
    expect(library.related.artistSimilarity('a', 'b'), greaterThan(0), reason: 'kept on the device');
  });

  test('the genre of a tag is split where it names several, but R&B is one', () {
    expect(RelatedMusic.styleNames('Rap/Hip Hop'), ['rap', 'hip hop']);
    expect(RelatedMusic.styleNames('Soul & Funk'), ['soul', 'funk']);
    expect(RelatedMusic.styleNames('R&B'), ['r&b']);
    expect(RelatedMusic.styleNames('Drum and Bass; Hip-Hop'), ['drum and bass', 'hip hop']);
  });

  group('Autoplay', () {
    /// Three artists alike (A, B and C, by Deezer), each with two albums of three tracks, and Z, like nobody.
    late LibraryService library;

    setUp(() {
      library = libraryOf([
        for (final name in ['A', 'B', 'C', 'Z'])
          for (final album in [1, 2])
            for (final n in [1, 2, 3]) track('$name$album$n', name, '$name album $album', number: n, year: 2010),
      ]);
      library.setRelatedMusic(
        facts: const RelatedMusicFacts(
          similarArtists: {
            'a': {'b': 0.9, 'c': 0.8},
            'b': {'c': 0.7},
          },
        ),
      );
    });

    List<Track> albumOf(String id) => library.albums.firstWhere((a) => a.tracks.any((t) => t.id == id)).tracks;
    String artistOf(Track t) => t.artist;

    test(
      'goes on with what is alike, never the queue again, never what is hidden, never two of one artist in a row',
      () {
        final queue = albumOf('A11');
        library.setHidden(HiddenKind.album, library.getTrack('B11')!.albumId, true);
        for (var seed = 0; seed < 20; seed++) {
          final next = library.related.autoplay(
            queue,
            random: math.Random(seed),
            taste: Taste(isHidden: library.isTrackHidden),
          );
          expect(next, isNotEmpty);
          expect(next.map((t) => t.id), isNot(anyElement(startsWith('Z'))), reason: 'Z is like none of them');
          expect(next.map((t) => t.id), isNot(anyElement(isIn(queue.map((t) => t.id)))));
          expect(next.map((t) => t.id), isNot(anyElement(startsWith('B1'))), reason: 'hidden');
          for (var i = 1; i < next.length; i++) {
            expect(artistOf(next[i]), isNot(artistOf(next[i - 1])), reason: 'seed $seed: ${next.map((t) => t.id)}');
          }
          expect(next.length, lessThanOrEqualTo(RelatedMusic.autoplayCount));
        }
      },
    );

    test('keeps away from what played in the last days, and from the artists just skipped', () {
      final queue = albumOf('A11');
      final now = DateTime.now().toUtc();
      var firstB = 0;
      var firstSkipped = 0;
      for (var seed = 0; seed < 40; seed++) {
        final rested = library.related.autoplay(
          queue,
          random: math.Random(seed),
          taste: Taste(lastPlayedAt: (t) => t.artist == 'B' ? now.subtract(const Duration(hours: 2)) : null),
        );
        if (rested.first.artist == 'B') firstB++;
        final skipping = library.related.autoplay(
          queue,
          random: math.Random(seed),
          taste: const Taste(skippedArtists: {'b'}),
        );
        if (skipping.first.artist == 'B') firstSkipped++;
      }
      expect(firstB, lessThan(4), reason: 'B, the closest, was played two hours ago');
      expect(firstSkipped, lessThan(4), reason: 'B was skipped');
    });

    test('leans towards loved tracks, and mixes in some never played', () {
      final queue = albumOf('A11');
      var loved = 0;
      var unloved = 0;
      var withNew = 0;
      for (var seed = 0; seed < 20; seed++) {
        final next = library.related.autoplay(
          queue,
          random: math.Random(seed),
          count: 6,
          taste: Taste(
            isFavorite: (t) => t.id == 'C21',
            // Everything but C's first album was played before.
            playCount: (t) => t.id.startsWith('C1') ? 0 : 5,
          ),
        );
        if (next.take(3).any((t) => t.id == 'C21')) loved++;
        if (next.take(3).any((t) => t.id == 'C22')) unloved++;
        if (next.any((t) => t.id.startsWith('C1'))) withNew++;
      }
      expect(loved, greaterThan(unloved + 3), reason: 'the loved track comes early far more often than its neighbour');
      expect(withNew, greaterThan(11), reason: 'most batches have something never played');
    });

    test('a library with one artist only still goes on with it', () {
      final one = libraryOf([
        track('a1', 'Miles Davis', 'Kind of Blue'),
        track('b1', 'Miles Davis', 'Milestones'),
        track('b2', 'Miles Davis', 'Milestones', number: 2),
      ]);
      final next = one.related.autoplay([one.getTrack('a1')!]);
      expect({for (final t in next) t.id}, {'b1', 'b2'});
    });
  });
}
