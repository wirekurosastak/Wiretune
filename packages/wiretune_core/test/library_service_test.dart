// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

LibraryService _service(MockRepository repo) =>
    LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');

void main() {
  setUpAll(useTempDataDirectory);

  test('indexes albums and artists', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      Track(
        id: '1',
        title: 'Starboy',
        artist: 'The Weeknd',
        album: 'Starboy',
        duration: const Duration(seconds: 228),
        format: const AudioFormat(sampleRate: 96000, bitsPerSample: 24),
      ),
      Track(
        id: '2',
        title: 'Party Monster',
        artist: 'The Weeknd',
        album: 'Starboy',
        duration: const Duration(seconds: 246),
        format: const AudioFormat(sampleRate: 96000, bitsPerSample: 24),
      ),
      Track(
        id: '3',
        title: 'Get Lucky',
        artist: 'Daft Punk',
        album: 'Random Access Memories',
        duration: const Duration(seconds: 366),
        format: const AudioFormat(sampleRate: 88200, bitsPerSample: 24),
      ),
    ]);
    await service.initialize();

    expect(service.tracks, hasLength(3));
    expect(service.albums, hasLength(2));
    expect(service.artists, hasLength(2));
    final starboy = service.albums.firstWhere((a) => a.title == 'Starboy');
    expect(starboy.trackCount, 2);
    expect(starboy.tier, QualityTier.gold); // both of its tracks are hi-res
    expect(service.search('Lucky').map((t) => t.title), ['Get Lucky']);
    expect(service.search('daft').map((t) => t.title), ['Get Lucky']); // ignoring case
  });

  test('playlists can be created and modified', () async {
    final repo = MockRepository();
    final service = _service(repo);
    await service.initialize();

    final playlist = await service.createPlaylist('Favorites Hi-Res', 'Best 24-bit FLAC tracks');
    expect(playlist.name, 'Favorites Hi-Res');

    await service.addTrackToPlaylist(playlist.id, 'track_123');
    expect(playlist.trackCount, 1);
    await service.addTrackToPlaylist(playlist.id, 'track_123'); // no duplicates
    expect(playlist.trackCount, 1);

    await service.renamePlaylist(playlist.id, '  Renamed ');
    expect(service.getPlaylist(playlist.id)!.name, 'Renamed');

    await service.removeTrackFromPlaylist(playlist.id, 'track_123');
    expect(playlist.trackCount, 0);

    await service.deletePlaylist(playlist.id);
    expect(service.playlists, isEmpty);
    expect(repo.playlists, isEmpty);
  });

  test('a compilation in one folder becomes Various Artists, and guests stay out of the artist list', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      Track(
        id: '1',
        title: 'Song 1',
        artist: 'Guest Alpha',
        album: 'Top Hits',
        trackNumber: 1,
        filePath: '/Music/Compilations/TopHits/01.flac',
      ),
      Track(
        id: '2',
        title: 'Song 2',
        artist: 'Guest Beta',
        album: 'Top Hits',
        trackNumber: 2,
        filePath: '/Music/Compilations/TopHits/02.flac',
      ),
      Track(
        id: '3',
        title: 'Song 3',
        artist: 'Guest Gamma',
        album: 'Top Hits',
        trackNumber: 3,
        filePath: '/Music/Compilations/TopHits/03.flac',
      ),
    ]);
    await service.initialize();

    expect(service.albums.single.artist, 'Various Artists');
    expect(service.artists.single.name, 'Various Artists');
    final resolved = service.getArtistByName('Guest Alpha')!;
    expect(resolved.name, 'Guest Alpha');
    expect(resolved.tracks, hasLength(1));
  });

  test('the dominant artist of a folder becomes its album artist', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      Track(
        id: '1',
        title: 'One More Time',
        artist: 'Daft Punk',
        album: 'Discovery',
        trackNumber: 1,
        filePath: '/Music/DaftPunk/Discovery/01.flac',
      ),
      Track(
        id: '2',
        title: 'Aerodynamic',
        artist: 'Daft Punk',
        album: 'Discovery',
        trackNumber: 2,
        filePath: '/Music/DaftPunk/Discovery/02.flac',
      ),
      Track(
        id: '3',
        title: 'Too Long',
        artist: 'Daft Punk feat. Romanthony',
        album: 'Discovery',
        trackNumber: 3,
        filePath: '/Music/DaftPunk/Discovery/03.flac',
      ),
    ]);
    await service.initialize();

    expect(service.albums.single.artist, 'Daft Punk');
    expect(service.artists.single.name, 'Daft Punk');
    // The inferred album artist is shown, never stored.
    expect(service.tracks.every((t) => t.albumArtistInferred), isTrue);
  });

  test('colliding track numbers keep the folder apart', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      Track(id: '1', title: 'A', artist: 'X', album: 'Same', trackNumber: 1, filePath: '/m/f/1.flac'),
      Track(id: '2', title: 'B', artist: 'Y', album: 'Same', trackNumber: 1, filePath: '/m/f/2.flac'),
    ]);
    await service.initialize();
    expect(service.albums, hasLength(2));
  });

  test('an album of hi-res and CD tracks is tagged MIXED, at the tier of its weakest track', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      Track(
        id: 't1',
        title: 'Hi-Res',
        artist: 'Artist X',
        album: 'Mixed Album',
        trackNumber: 1,
        filePath: '/Music/X/Mixed/01.flac',
        format: const AudioFormat(sampleRate: 96000, bitsPerSample: 24),
      ),
      Track(
        id: 't2',
        title: 'CD',
        artist: 'Artist X',
        album: 'Mixed Album',
        trackNumber: 2,
        filePath: '/Music/X/Mixed/02.flac',
        format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
      ),
    ]);
    await service.initialize();
    final album = service.albums.single;
    expect((album.tier, album.tagSpec), (QualityTier.silver, QualitySummary.mixedSpec));
  });

  test('sorting ignores accents and case', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      TestSupport.makeTrack('1', 'x', artist: 'zebra', album: 'Zulu'),
      TestSupport.makeTrack('2', 'y', artist: 'Ábel', album: 'Ébredés'),
      TestSupport.makeTrack('3', 'z', artist: 'bach', album: 'b'),
    ]);
    await service.initialize();
    expect(service.artists.map((a) => a.name), ['Ábel', 'bach', 'zebra']);
    expect(service.albums.map((a) => a.title), ['b', 'Ébredés', 'Zulu']);
  });

  test('server tracks change only while signed in to the server, local ones always', () async {
    final repo = MockRepository();
    final service = _service(repo);
    final local = TestSupport.makeTrack('local', 'Local');
    final server = TestSupport.makeServerTrack('server', 'Server');
    repo.saveTracks([local, server]);
    await service.initialize();

    final toggled = <String>[];
    service.favoriteToggled.listen((t) => toggled.add(t.id));

    service.serverConnected = true;
    await service.toggleFavorite('server');
    expect(service.getTrack('server')!.isFavorite, isTrue);
    expect(toggled, ['server']); // a change the server has to hear about

    await service.toggleFavorite('local');
    expect(toggled, ['server']); // local tracks stay on the device

    service.serverConnected = false;
    await service.toggleFavorite('server');
    expect(service.getTrack('server')!.isFavorite, isTrue); // cannot be changed while the server is away
    await service.recordPlay('server');
    expect(service.getTrack('server')!.playCount, 0);
    await service.recordPlay('local');
    expect(service.getTrack('local')!.playCount, 1);
  });

  test('a favourite remembers when it was marked: here, or on the server', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([TestSupport.makeTrack('local', 'Local')]);
    await service.initialize();

    final before = DateTime.now().toUtc();
    await service.toggleFavorite('local');
    final marked = service.getTrack('local')!.favoritedAt;
    expect(marked != null && !marked.isBefore(before), isTrue);
    expect(repo.tracks.single.favoritedAt, marked); // and stored
    await service.toggleFavorite('local');
    expect(service.getTrack('local')!.favoritedAt, isNull);

    // A server's favourites come with the time the account marked them.
    final when = DateTime.utc(2026, 2, 3);
    await service.mergeServerTracks([
      TestSupport.makeServerTrack('s1', 'Server'),
    ], UserDataSnapshot(['s1'], const [], const [], {'s1': when}));
    expect(service.getTrack('s1')!.favoritedAt, when);
  });

  test('a rescan keeps favourites, play counts and the date added', () async {
    final repo = MockRepository();
    final service = _service(repo);
    final original = TestSupport.makeTrack('1', 'Song')..dateAdded = DateTime.utc(2020);
    repo.saveTracks([original]);
    await service.initialize();
    await service.toggleFavorite('1');
    await service.recordPlay('1');

    await service.replaceTracks([TestSupport.makeTrack('1', 'Song (retagged)')]);

    final track = service.getTrack('1')!;
    expect(track.title, 'Song (retagged)');
    expect(track.isFavorite, isTrue);
    expect(track.playCount, 1);
    expect(track.dateAdded, DateTime.utc(2020));
  });

  test('content hiding: tracks, albums, artists, precedence, non-destructive hierarchy, and playback', () async {
    final repo = MockRepository();
    final service = _service(repo);
    final t1 = Track(
      id: 't1',
      title: 'Song 1',
      artist: 'Artist A',
      album: 'Album 1',
      duration: const Duration(seconds: 180),
      format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
    )..isFavorite = true;
    final t2 = Track(
      id: 't2',
      title: 'Song 2',
      artist: 'Artist A',
      album: 'Album 1',
      duration: const Duration(seconds: 200),
      format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
    );
    final t3 = Track(
      id: 't3',
      title: 'Song 3',
      artist: 'Artist B',
      album: 'Album 2',
      duration: const Duration(seconds: 210),
      format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
    );
    repo.saveTracks([t1, t2, t3]);
    await service.initialize();

    expect(service.tracks, hasLength(3));
    expect(service.albums, hasLength(2));
    expect(service.artists, hasLength(2));
    expect(service.favorites, hasLength(1));

    // 1. Hide track 1
    await service.hideTrack('t1');
    expect(service.isTrackHidden(t1), isTrue);
    expect(service.isTrackExplicitlyHidden('t1'), isTrue);
    expect(service.tracks.map((t) => t.id), ['t2', 't3']);
    expect(service.favorites, isEmpty);
    expect(service.search('Song 1'), isEmpty);
    expect(service.search('Song 2'), hasLength(1));

    // Direct playback & playlist resolution still works for hidden track
    expect(service.getTrack('t1'), isNotNull);
    expect(service.resolveTracks(['t1', 't2']).map((t) => t.id), ['t1', 't2']);

    // 2. Hide Album 1 (precedence & hierarchy)
    final album1Id = t1.albumId;
    await service.hideAlbum(album1Id);
    expect(service.isAlbumHidden(album1Id), isTrue);
    expect(service.isTrackHidden(t2), isTrue); // t2 is hidden via album
    expect(service.albums.map((a) => a.id), [t3.albumId]);
    expect(service.tracks.map((t) => t.id), ['t3']);

    // 3. Unhide Album 1: Non-destructive hierarchy test!
    // t1 was explicitly hidden, so when Album 1 is unhidden, t1 MUST STILL be hidden, while t2 reappears.
    await service.unhideAlbum(album1Id);
    expect(service.isAlbumHidden(album1Id), isFalse);
    expect(service.isTrackHidden(t1), isTrue); // still explicitly hidden
    expect(service.isTrackHidden(t2), isFalse); // visible again
    expect(service.tracks.map((t) => t.id), ['t2', 't3']);

    // 4. Hide Artist A: hides Album 1 and all its tracks
    final artistAId = service.artists.firstWhere((a) => a.name == 'Artist A').id;
    await service.hideArtist(artistAId);
    expect(service.isArtistHidden(artistAId), isTrue);
    expect(service.isTrackHidden(t2), isTrue);
    expect(service.artists.map((a) => a.name), ['Artist B']);
    expect(service.tracks.map((t) => t.id), ['t3']);

    // 5. Unhide Artist A: non-destructive hierarchy
    await service.unhideArtist(artistAId);
    expect(service.isArtistHidden(artistAId), isFalse);
    expect(service.isTrackHidden(t1), isTrue); // still explicitly hidden
    expect(service.isTrackHidden(t2), isFalse); // visible again

    // 6. Unhide All
    await service.unhideAll();
    expect(service.isTrackHidden(t1), isFalse);
    expect(service.tracks, hasLength(3));
    expect(service.favorites, hasLength(1));
  });

  test('content hiding: user switching isolates hidden items', () async {
    final repo = MockRepository();
    final service = _service(repo);
    final t1 = Track(
      id: 't1',
      title: 'Song 1',
      artist: 'Artist A',
      album: 'Album 1',
      duration: const Duration(seconds: 180),
      format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
    );
    repo.saveTracks([t1]);
    await service.initialize();

    await service.setCurrentUser('user_alpha');
    await service.hideTrack('t1');
    expect(service.isTrackHidden(t1), isTrue);
    expect(service.tracks, isEmpty);

    // Switch to user_beta
    await service.setCurrentUser('user_beta');
    expect(service.isTrackHidden(t1), isFalse);
    expect(service.tracks, hasLength(1));

    // Switch back to user_alpha
    await service.setCurrentUser('user_alpha');
    expect(service.isTrackHidden(t1), isTrue);
    expect(service.tracks, isEmpty);
  });
}
