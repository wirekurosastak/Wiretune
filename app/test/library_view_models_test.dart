// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/view_models/library_view_models.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The album list's quality sort, and the genre filter of the album and artist lists.
void main() {
  setUpAll(() {
    final dir = useTempDataDirectory();
    // The artist list asks for pictures; these tests never reach the real service.
    ArtistPictureService.instance
      ..client = MockClient((_) async => http.Response('{}', 404))
      ..cacheFileOverride = p.join(dir.path, 'artist_pictures.json')
      ..resetForTests();
  });
  setUp(() => Localizer.instance.setLanguage('en'));

  Track track(String id, String album, {String artist = 'Artist', String? genre, AudioFormat? format}) =>
      TestSupport.makeTrack(id, 'Track $id', artist: artist, album: album)
        ..genre = genre
        ..format = format ?? const AudioFormat(codec: 'FLAC', sampleRate: 44100, bitsPerSample: 16, isLossless: true);

  const hiRes = AudioFormat(codec: 'FLAC', sampleRate: 96000, bitsPerSample: 24, isLossless: true);
  const hiResLow = AudioFormat(codec: 'FLAC', sampleRate: 48000, bitsPerSample: 24, isLossless: true);
  const mp3 = AudioFormat(codec: 'MP3', sampleRate: 44100, bitrateKbps: 320, isLossless: false);

  Future<LibraryService> library(List<Track> tracks) async {
    final library = createLibrary(tracks);
    await library.initialize();
    return library;
  }

  List<String> titles(AlbumsViewModel albums) => [for (final a in albums.displayedAlbums) a.title];

  test('sorting by quality puts the best albums first, an album counting as its weakest track', () async {
    final lib = await library([
      track('1', 'Lossy', format: mp3),
      track('2', 'Studio 96', format: hiRes),
      track('3', 'Studio 48', format: hiResLow),
      track('4', 'CD'),
      // A hi-res track beside a CD one: the album is only as good as the CD one.
      track('5', 'Mixed', format: hiRes),
      track('6', 'Mixed'),
    ]);
    final albums = AlbumsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    albums.setSortField(AlbumSortField.quality);
    expect(albums.isSortDescending, isTrue);
    expect(titles(albums), ['Studio 96', 'Studio 48', 'CD', 'Mixed', 'Lossy']);
    expect(albums.sortQualityLabel, 'Quality ↓');

    albums.setSortField(AlbumSortField.quality);
    expect(titles(albums), ['Lossy', 'CD', 'Mixed', 'Studio 48', 'Studio 96']);
  });

  test('sorting albums by artist sorts alphabetically by artist name', () async {
    final lib = await library([
      track('1', 'Album Z', artist: 'Miles Davis'),
      track('2', 'Album A', artist: 'Miles Davis'),
      track('3', 'Nevermind', artist: 'Nirvana'),
      track('4', 'Abbey Road', artist: 'The Beatles'),
    ]);
    final albums = AlbumsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    albums.setSortField(AlbumSortField.artist);
    expect(albums.isSortDescending, isFalse);
    expect(titles(albums), ['Album A', 'Album Z', 'Nevermind', 'Abbey Road']);
    expect(albums.sortArtistLabel, 'Artist ↑');

    albums.setSortField(AlbumSortField.artist);
    expect(albums.isSortDescending, isTrue);
    expect(titles(albums), ['Abbey Road', 'Nevermind', 'Album A', 'Album Z']);
    expect(albums.sortArtistLabel, 'Artist ↓');
  });

  test(
    'the genre filter narrows albums and artists to those with a track of the genre, in any capitalisation',
    () async {
      final lib = await library([
        track('1', 'Kind of Blue', artist: 'Miles Davis', genre: 'Jazz'),
        track('2', 'Bitches Brew', artist: 'Miles Davis', genre: 'jazz'),
        track('3', 'Nevermind', artist: 'Nirvana', genre: 'Rock'),
        track('4', 'Untagged', artist: 'Someone'),
      ]);
      final player = PlayerViewModel(TestSupport.createEngine(), lib);
      final albums = AlbumsViewModel(lib, player);
      final artists = ArtistsViewModel(lib, player);

      // One entry per genre, however its tracks capitalise it.
      expect([for (final g in albums.genres) g.toLowerCase()], ['jazz', 'rock']);
      expect(artists.genres, albums.genres);

      albums.setGenre('JAZZ');
      artists.setGenre('Rock');
      expect(titles(albums), ['Bitches Brew', 'Kind of Blue']);
      expect([for (final a in artists.displayedArtists) a.name], ['Nirvana']);

      albums.setGenre(null);
      expect(albums.displayedAlbums, hasLength(4));
    },
  );

  test('a library without genres offers no filter', () async {
    final lib = await library([track('1', 'One'), track('2', 'Two')]);
    final player = PlayerViewModel(TestSupport.createEngine(), lib);
    expect(AlbumsViewModel(lib, player).genres, isEmpty);
    expect(ArtistsViewModel(lib, player).genres, isEmpty);
  });

  test(
    'the tracks sort by title, artist, album, date added or quality; the active field flips its direction',
    () async {
      final lib = await library([
        track('1', 'B Album', artist: 'Zed')
          ..title = 'Beta'
          ..dateAdded = DateTime.utc(2026, 1, 3),
        track('2', 'A Album', artist: 'Abba', format: hiRes)
          ..title = 'Gamma'
          ..dateAdded = DateTime.utc(2026, 1, 1),
        track('3', 'C Album', artist: 'Moby', format: mp3)
          ..title = 'Alpha'
          ..dateAdded = DateTime.utc(2026, 1, 2),
      ]);
      final tracks = TracksViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));
      List<String> titles() => [for (final t in tracks.displayedTracks) t.title];

      expect(titles(), ['Alpha', 'Beta', 'Gamma']); // ABC default
      tracks.setSortField(TrackSortField.title);
      expect(titles(), ['Gamma', 'Beta', 'Alpha']);
      tracks.setSortField(TrackSortField.artist);
      expect(titles(), ['Gamma', 'Alpha', 'Beta']);
      tracks.setSortField(TrackSortField.added); // the newest first
      expect(titles(), ['Beta', 'Alpha', 'Gamma']);
      tracks.setSortField(TrackSortField.quality); // the best first
      expect(titles(), ['Gamma', 'Beta', 'Alpha']);
      tracks.setSortField(TrackSortField.album);
      expect(titles(), ['Gamma', 'Beta', 'Alpha']);
    },
  );

  test('the favourites can sort by date added with newest first', () async {
    final lib = await library([
      track('1', 'Album')
        ..title = 'C'
        ..isFavorite = true
        ..favoritedAt = DateTime.utc(2026, 1, 1),
      track('2', 'Album')
        ..title = 'B'
        ..isFavorite = true
        ..favoritedAt = DateTime.utc(2026, 3, 1),
      track('3', 'Album')
        ..title = 'A'
        ..isFavorite = true,
      track('4', 'Album'),
    ]);
    final favorites = FavoritesViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    expect([for (final t in favorites.favoriteTracks) t.id], ['2', '1', '3']); // Date added newest first default
    expect(favorites.sortLabel(TrackSortField.added), 'Added ↓');
    favorites.setSortField(TrackSortField.title);
    expect([for (final t in favorites.favoriteTracks) t.id], ['3', '2', '1']);

    await lib.toggleFavorite('4'); // marked just now: the newest
    favorites.setSortField(TrackSortField.added);
    expect(favorites.favoriteTracks.first.id, '4');
  });

  test('sort fields maintain a consistent relative order across views', () {
    expect(TrackSortField.values, [
      TrackSortField.title,
      TrackSortField.artist,
      TrackSortField.album,
      TrackSortField.year,
      TrackSortField.added,
      TrackSortField.quality,
    ]);
    expect(AlbumSortField.values, [
      AlbumSortField.title,
      AlbumSortField.artist,
      AlbumSortField.year,
      AlbumSortField.added,
      AlbumSortField.quality,
    ]);
    expect(ArtistSortField.values, [
      ArtistSortField.name,
      ArtistSortField.added,
      ArtistSortField.albums,
    ]);
  });

  test('sorting albums by added puts the newest album first', () async {
    final lib = await library([
      track('1', 'Old Album', artist: 'Artist')
        ..dateAdded = DateTime.utc(2025, 1, 1),
      track('2', 'New Album', artist: 'Artist')
        ..dateAdded = DateTime.utc(2026, 1, 1),
    ]);
    final albums = AlbumsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    albums.setSortField(AlbumSortField.added);
    expect(albums.isSortDescending, isTrue);
    expect(albums.sortAddedLabel, 'Added ↓');
    expect(titles(albums), ['New Album', 'Old Album']);

    albums.setSortField(AlbumSortField.added);
    expect(albums.isSortDescending, isFalse);
    expect(albums.sortAddedLabel, 'Added ↑');
    expect(titles(albums), ['Old Album', 'New Album']);
  });

  test('sorting artists by albums and added behaves consistently', () async {
    final lib = await library([
      track('1', 'Album 1', artist: 'Few')
        ..dateAdded = DateTime.utc(2026, 5, 1),
      track('2', 'Album 2', artist: 'Many')
        ..dateAdded = DateTime.utc(2025, 1, 1),
      track('3', 'Album 3', artist: 'Many')
        ..dateAdded = DateTime.utc(2025, 2, 1),
    ]);
    final artists = ArtistsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    artists.setSortField(ArtistSortField.albums);
    expect(artists.isSortDescending, isTrue);
    expect(artists.sortAlbumsLabel, 'Albums ↓');
    expect([for (final a in artists.displayedArtists) a.name], ['Many', 'Few']);

    artists.setSortField(ArtistSortField.added);
    expect(artists.isSortDescending, isTrue);
    expect(artists.sortAddedLabel, 'Added ↓');
    expect([for (final a in artists.displayedArtists) a.name], ['Few', 'Many']);
  });
}
