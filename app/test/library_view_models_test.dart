// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/library_view_models.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The album list's quality sort, and the genre filter of the album and artist lists.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  Track track(String id, String album, {String artist = 'Artist', String? genre, AudioFormat? format}) =>
      TestSupport.makeTrack(id, 'Track $id', artist: artist, album: album)
        ..genre = genre
        ..format = format ?? const AudioFormat(codec: 'FLAC', sampleRate: 44100, bitsPerSample: 16, isLossless: true);

  const hiRes = AudioFormat(codec: 'FLAC', sampleRate: 96000, bitsPerSample: 24, isLossless: true);
  const hiResLow = AudioFormat(codec: 'FLAC', sampleRate: 48000, bitsPerSample: 24, isLossless: true);
  const mp3 = AudioFormat(codec: 'MP3', sampleRate: 44100, bitrateKbps: 320, isLossless: false);

  Future<LibraryService> library(
    List<Track> tracks, {
    Map<String, DateTime?> favorites = const {},
    Map<String, PlayStats> plays = const {},
  }) async {
    final library = createLibrary(tracks, favorites, plays);
    library.initialize();
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
    expect(albums.sortLabel(AlbumSortField.quality), 'Quality ↓');

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
    expect(albums.sortLabel(AlbumSortField.artist), 'Artist ↑');

    albums.setSortField(AlbumSortField.artist);
    expect(albums.isSortDescending, isTrue);
    expect(titles(albums), ['Abbey Road', 'Nevermind', 'Album A', 'Album Z']);
    expect(albums.sortLabel(AlbumSortField.artist), 'Artist ↓');
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
          ..addedAt = DateTime.utc(2026, 1, 3),
        track('2', 'A Album', artist: 'Abba', format: hiRes)
          ..title = 'Gamma'
          ..addedAt = DateTime.utc(2026, 1, 1),
        track('3', 'C Album', artist: 'Moby', format: mp3)
          ..title = 'Alpha'
          ..addedAt = DateTime.utc(2026, 1, 2),
      ]);
      final tracks = TrackListViewModel.allTracks(lib, PlayerViewModel(TestSupport.createEngine(), lib));
      List<String> titles() => [for (final t in tracks.tracks) t.title];

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

  test('the tracks sort by bitrate, the highest first, a file of unknown bitrate last either way', () async {
    AudioFormat kbps(int bitrate) => AudioFormat(codec: 'FLAC', isLossless: true, bitrateKbps: bitrate);
    final lib = await library([
      track('1', 'Album', format: kbps(900))..title = 'CD',
      track('2', 'Album', format: kbps(0))..title = 'Unknown',
      track('3', 'Album', format: kbps(3100))..title = 'Hi-res',
      track('4', 'Album', format: kbps(320))..title = 'MP3',
    ]);
    final tracks = TrackListViewModel.allTracks(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    List<String> titles() => [for (final t in tracks.tracks) t.title];

    tracks.setSortField(TrackSortField.bitrate);
    expect(tracks.sortLabel(TrackSortField.bitrate), 'Bitrate ↓');
    expect(titles(), ['Hi-res', 'CD', 'MP3', 'Unknown']);
    tracks.setSortField(TrackSortField.bitrate);
    expect(titles(), ['MP3', 'CD', 'Hi-res', 'Unknown']);
  });

  test('the favourites can sort by date added with newest first', () async {
    final lib = await library(
      [
        track('1', 'Album')..title = 'C',
        track('2', 'Album')..title = 'B',
        track('3', 'Album')..title = 'A',
        track('4', 'Album'),
      ],
      favorites: {'1': DateTime.utc(2026, 1, 1), '2': DateTime.utc(2026, 3, 1), '3': null},
    );
    final favorites = TrackListViewModel.favorites(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    expect([for (final t in favorites.tracks) t.id], ['2', '1', '3']); // Date added newest first default
    expect(favorites.sortLabel(TrackSortField.added), 'Added ↓');
    favorites.setSortField(TrackSortField.title);
    expect([for (final t in favorites.tracks) t.id], ['3', '2', '1']);

    lib.toggleFavorite('4'); // marked just now: the newest
    favorites.setSortField(TrackSortField.added);
    expect(favorites.tracks.first.id, '4');
  });

  test('every list offers ABC first, then its own fields, then the shared year, date added and quality', () {
    expect(TrackSortField.values, [
      TrackSortField.title,
      TrackSortField.artist,
      TrackSortField.album,
      TrackSortField.length,
      TrackSortField.released,
      TrackSortField.added,
      TrackSortField.quality,
      TrackSortField.bitrate, // a track's, beside its quality
    ]);
    expect(AlbumSortField.values, [
      AlbumSortField.title,
      AlbumSortField.artist,
      AlbumSortField.released,
      AlbumSortField.added,
      AlbumSortField.quality,
    ]);
    expect(ArtistSortField.values, [ArtistSortField.name, ArtistSortField.albums, ArtistSortField.added]);
  });

  test('a track without a year or a date goes last in either direction, and length starts with the shortest', () async {
    final lib = await library([
      track('1', 'Album')
        ..title = 'Dated'
        ..releaseYear = 2001
        ..duration = const Duration(minutes: 5),
      track('2', 'Album')
        ..title = 'Undated'
        ..duration = const Duration(minutes: 2),
      track('3', 'Album')
        ..title = 'Recent'
        ..releaseYear = 2020
        ..duration = const Duration(minutes: 3),
    ]);
    final tracks = TrackListViewModel.allTracks(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    List<String> titles() => [for (final t in tracks.tracks) t.title];

    tracks.setSortField(TrackSortField.released);
    expect(titles(), ['Recent', 'Dated', 'Undated']);
    tracks.setSortField(TrackSortField.released);
    expect(titles(), ['Dated', 'Recent', 'Undated']);
    tracks.setSortField(TrackSortField.length);
    expect(tracks.sortLabel(TrackSortField.length), 'Length ↑');
    expect(titles(), ['Undated', 'Recent', 'Dated']);
  });

  test('sorting albums by added puts the newest album first', () async {
    final lib = await library([
      track('1', 'Old Album', artist: 'Artist')..addedAt = DateTime.utc(2025, 1, 1),
      track('2', 'New Album', artist: 'Artist')..addedAt = DateTime.utc(2026, 1, 1),
    ]);
    final albums = AlbumsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    albums.setSortField(AlbumSortField.added);
    expect(albums.isSortDescending, isTrue);
    expect(albums.sortLabel(AlbumSortField.added), 'Added ↓');
    expect(titles(albums), ['New Album', 'Old Album']);

    albums.setSortField(AlbumSortField.added);
    expect(albums.isSortDescending, isFalse);
    expect(albums.sortLabel(AlbumSortField.added), 'Added ↑');
    expect(titles(albums), ['Old Album', 'New Album']);
  });

  test('sorting artists by albums and added behaves consistently', () async {
    final lib = await library([
      track('1', 'Album 1', artist: 'Few')..addedAt = DateTime.utc(2026, 5, 1),
      track('2', 'Album 2', artist: 'Many')..addedAt = DateTime.utc(2025, 1, 1),
      track('3', 'Album 3', artist: 'Many')..addedAt = DateTime.utc(2025, 2, 1),
    ]);
    final artists = ArtistsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));

    artists.setSortField(ArtistSortField.albums);
    expect(artists.isSortDescending, isTrue);
    expect(artists.sortLabel(ArtistSortField.albums), 'Albums ↓');
    expect([for (final a in artists.displayedArtists) a.name], ['Many', 'Few']);

    artists.setSortField(ArtistSortField.added);
    expect(artists.isSortDescending, isTrue);
    expect(artists.sortLabel(ArtistSortField.added), 'Added ↓');
    expect([for (final a in artists.displayedArtists) a.name], ['Few', 'Many']);
  });

  test("a playlist's tracks start in the order they were added, and play in the order shown", () async {
    final lib = await library([
      track('1', 'Album')..title = 'Beta',
      track('2', 'Album')..title = 'Alpha',
      track('3', 'Album')..title = 'Gamma',
    ]);
    final engine = TestSupport.createEngine();
    final player = PlayerViewModel(engine, lib);
    final playlists = PlaylistsViewModel(lib, player);
    final mix = lib.createPlaylist('Mix');
    for (final id in ['3', '1', '2']) {
      lib.addTracksToPlaylist(mix.id, [id]);
    }
    playlists.openPlaylist(lib.getPlaylist(mix.id));
    List<String> titles() => [for (final t in playlists.selectedPlaylistTracks) t.title];

    expect(titles(), ['Gamma', 'Beta', 'Alpha']);
    expect(playlists.sortLabel(TrackSortField.added), 'Added ↑');
    expect([for (final t in playlists.selectedPlaylistTracks) playlists.positionOf(t)], [1, 2, 3]);
    playlists.setSortField(TrackSortField.added); // the newest added first
    expect(titles(), ['Alpha', 'Beta', 'Gamma']);
    playlists.setSortField(TrackSortField.title);
    expect(titles(), ['Alpha', 'Beta', 'Gamma']);
    playlists.setSortField(TrackSortField.title);
    expect(titles(), ['Gamma', 'Beta', 'Alpha']);

    playlists.playPlaylist();
    expect([for (final t in player.queueTracks) t.title], ['Gamma', 'Beta', 'Alpha']);
    playlists.dispose();
  });

  test('the playlists page starts with the newest playlist and sorts by name, tracks or added', () async {
    final lib = await library([track('1', 'Album'), track('2', 'Album')]);
    final playlists = PlaylistsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    for (final (name, tracks) in [('Zed', 2), ('Alpha', 0), ('Mid', 1)]) {
      final created = lib.createPlaylist(name);
      lib.addTracksToPlaylist(created.id, ['1', '2'].take(tracks));
      await Future<void>.delayed(const Duration(milliseconds: 2)); // a creation time of its own
    }
    List<String> names() => [for (final p in playlists.playlists) p.name];

    expect(names(), ['Mid', 'Alpha', 'Zed']);
    expect(playlists.listSortLabel(PlaylistSortField.added), 'Added ↓');
    playlists.setListSortField(PlaylistSortField.name);
    expect(names(), ['Alpha', 'Mid', 'Zed']);
    playlists.setListSortField(PlaylistSortField.tracks); // the most first
    expect(names(), ['Zed', 'Mid', 'Alpha']);
    expect(PlaylistSortField.values, [PlaylistSortField.name, PlaylistSortField.tracks, PlaylistSortField.added]);
    playlists.dispose();
  });

  test('the most and the recently played tracks are read-only playlists above the own ones', () async {
    final now = DateTime.utc(2026, 10, 12);
    PlayStats played(int count, int hoursAgo) => (count: count, lastPlayedAt: now.subtract(Duration(hours: hoursAgo)));
    final lib = await library(
      [
        for (final id in ['a', 'b', 'c']) TestSupport.makeTrack(id, 'Song $id'),
        TestSupport.makeTrack('d', 'Never played'),
      ],
      plays: {'a': played(3, 5), 'b': played(9, 30), 'c': played(3, 1)},
    );
    final playlists = PlaylistsViewModel(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    List<String?> titles(Playlist playlist) => [for (final t in playlists.tracksOf(playlist)) t.title];

    expect([for (final pl in playlists.automaticPlaylists) pl.name], ['Most played', 'Recently played']);
    final [most, recent] = playlists.automaticPlaylists;
    expect(titles(most), ['Song b', 'Song c', 'Song a'], reason: 'equal counts: the more recent first');
    expect(titles(recent), ['Song c', 'Song a', 'Song b']);
    expect(playlists.playlists, isEmpty, reason: 'not among the own playlists (the dialogs, the car)');
    expect(playlists.hasPlaylists, isTrue);

    playlists.openPlaylist(most);
    expect(playlists.canReorder, isFalse);
    playlists.startRename();
    expect(playlists.isEditingName, isFalse);
  });

  test('the favourites follow a track toggled anywhere, and tell their listeners', () async {
    final t1 = track('1', 'Album');
    final lib = await library([t1]);
    final favorites = TrackListViewModel.favorites(lib, PlayerViewModel(TestSupport.createEngine(), lib));
    addTearDown(favorites.dispose);

    expect(favorites.tracks, isEmpty);

    var notified = 0;
    favorites.addListener(() => notified++);

    lib.toggleFavorite(t1.id);
    expect([for (final t in favorites.tracks) t.id], [t1.id]);
    expect(notified, greaterThan(0));

    final countAfterAdd = notified;
    lib.toggleFavorite(t1.id);
    expect(favorites.tracks, isEmpty);
    expect(notified, greaterThan(countAfterAdd));
  });
}
