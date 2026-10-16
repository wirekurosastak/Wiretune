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

  test('a playlist takes many tracks in one change, and its shown entries move around the ones it lacks', () async {
    final repo = MockRepository();
    final service = _service(repo);
    repo.saveTracks([
      for (final id in ['a', 'b', 'c']) TestSupport.makeTrack(id, 'Song $id'),
    ]);
    await service.initialize();
    final playlist = await service.createPlaylist('Mix');
    var edits = 0;
    service.playlistsChanged.listen((_) => edits++);

    await service.addTracksToPlaylist(playlist.id, ['a', 'gone', 'b', 'a', 'c']);
    expect(playlist.trackIds, ['a', 'gone', 'b', 'c']);
    expect(edits, 1);

    // Shown: a, b, c. Moving c to the top keeps the missing entry among the others.
    await service.movePlaylistTrack(playlist.id, 2, 0);
    expect([for (final t in service.getPlaylistTracks(playlist)) t.id], ['c', 'a', 'b']);
    await service.movePlaylistTrack(playlist.id, 0, 2);
    expect([for (final t in service.getPlaylistTracks(playlist)) t.id], ['a', 'b', 'c']);
    await service.movePlaylistTrack(playlist.id, 0, 9); // out of range: nothing happens
    expect(playlist.trackIds, hasLength(4));
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

  group("a folder of one artist's songs from several albums", () {
    Track song(String id, String folder, String album, {String artist = 'AC/DC', int? number, int? year}) => Track(
      id: id,
      title: 'Song $id',
      artist: artist,
      album: album,
      albumArtist: artist,
      trackNumber: number,
      discNumber: 1,
      year: year,
      filePath: '/Music/$folder/$id.flac',
    );

    Future<LibraryService> library(List<Track> tracks) async {
      final repo = MockRepository()..settings['library_path'] = '/Music';
      final service = _service(repo);
      repo.saveTracks(tracks);
      await service.initialize();
      return service;
    }

    test('is one album named after the folder, numbered by title and as new as its newest song', () async {
      final service = await library([
        song('c', 'ACDC Essentials', 'Back In Black', number: 6, year: 1980),
        song('a', 'ACDC Essentials', 'Highway to Hell', number: 1, year: 1979),
        song('b', 'ACDC Essentials', 'POWER UP', number: 1, year: 2020),
      ]);

      final album = service.albums.single;
      expect((album.title, album.artist, album.year), ('ACDC Essentials', 'AC/DC', 2020));
      expect(
        [for (final t in album.tracks) (t.title, t.trackNumber, t.discNumber)],
        [('Song a', 1, null), ('Song b', 2, null), ('Song c', 3, null)],
      );
      // What the tags say is kept (and stored) as it is.
      final tagged = service.getTrack('c')!.taggedAlbum!;
      expect(
        (tagged.album, tagged.albumArtist, tagged.trackNumber, tagged.discNumber),
        ('Back In Black', 'AC/DC', 6, 1),
      );
    });

    test("is the artist's Essentials in the artist's own folder", () async {
      final service = await library([
        song('1', 'Eminem', 'The Eminem Show', artist: 'Eminem'),
        song('2', 'Eminem', 'Encore', artist: 'Eminem'),
      ]);
      expect(service.albums.single.title, 'Eminem Essentials');
    });

    test('lets strays join the album the folder is named after, keeping the numbers', () async {
      final service = await library([
        song(
          '1',
          'Hooverphonic/The Best of Hooverphonic',
          'The Best of Hooverphonic',
          artist: 'Hooverphonic',
          number: 1,
        ),
        song(
          '2',
          'Hooverphonic/The Best of Hooverphonic',
          'The Best of Hooverphonic',
          artist: 'Hooverphonic',
          number: 2,
        ),
        song(
          '3',
          'Hooverphonic/The Best of Hooverphonic',
          'In Wonderland',
          artist: 'Hooverphonic',
          number: 7,
          year: 2011,
        ),
      ]);
      final album = service.albums.single;
      expect((album.title, album.year), ('The Best of Hooverphonic', null)); // not the stray's year
      expect([for (final t in album.tracks) t.trackNumber], [1, 2, 7]);
    });

    test('counts featured artists and the album artist as the shared one', () async {
      final service = await library([
        Track(id: '1', title: 'A', artist: 'Ufo361', album: 'Private', filePath: '/Music/Ufo361/1.flac'),
        Track(
          id: '2',
          title: 'B',
          artist: '10am, Ufo361',
          artists: ['10am', 'Ufo361'],
          album: 'pj nach zürich',
          filePath: '/Music/Ufo361/2.flac',
        ),
        Track(
          id: '3',
          title: 'C',
          artist: 'Ludovico Einaudi',
          album: 'Nomadland',
          albumArtist: 'Various Artists',
          filePath: '/Music/Ufo361/3.flac',
        ),
      ]);
      expect(service.albums, hasLength(3)); // Einaudi is no Ufo361 song: nothing is shared
      final shared = await library([
        Track(id: '1', title: 'A', artist: 'Ufo361', album: 'Private', filePath: '/Music/Ufo361/1.flac'),
        Track(
          id: '2',
          title: 'B',
          artist: '10am, Ufo361',
          artists: ['10am', 'Ufo361'],
          album: 'pj nach zürich',
          filePath: '/Music/Ufo361/2.flac',
        ),
      ]);
      expect((shared.albums.single.title, shared.albums.single.artist), ('Ufo361 Essentials', 'Ufo361'));
    });

    test('leaves loose files in the music folder, and folders of several artists, alone', () async {
      final loose = await library([song('1', '', 'Back In Black'), song('2', '', 'Highway to Hell')]);
      expect(loose.albums, hasLength(2));
      final mixed = await library([
        song('1', 'Mix', 'Back In Black'),
        song('2', 'Mix', 'Discovery', artist: 'Daft Punk'),
      ]);
      expect(mixed.albums, hasLength(2));
    });

    test(
      "leaves an artist's whole albums side by side in one folder apart, and works only inside the music folder",
      () async {
        Track full(String id, String album, int number) =>
            song(id, 'Daft Punk', album, artist: 'Daft Punk', number: number)..trackCount = 3;
        final flat = await library([
          for (var i = 1; i <= 3; i++) full('d$i', 'Discovery', i),
          for (var i = 1; i <= 3; i++) full('h$i', 'Homework', i),
        ]);
        expect(flat.albums.map((a) => a.title), unorderedEquals(['Discovery', 'Homework']));

        final repo = MockRepository(); // no music folder known
        final service = _service(repo);
        repo.saveTracks([song('1', 'ACDC Essentials', 'Back In Black'), song('2', 'ACDC Essentials', 'POWER UP')]);
        await service.initialize();
        expect(service.albums, hasLength(2));
      },
    );

    test('follows the tags again when the folder no longer qualifies, and stores only the tags', () async {
      final repo = MockRepository()..settings['library_path'] = '/Music';
      final service = _service(repo);
      repo.saveTracks([song('1', 'GOLD', 'Gold: Greatest Hits', number: 3), song('2', 'GOLD', 'The Singles')]);
      await service.initialize();
      expect(service.albums.single.title, 'GOLD');

      await service.replaceTracks([service.getTrack('1')!, service.getTrack('2')!]);
      expect(service.albums.single.title, 'GOLD');
      expect({for (final t in await repo.getAllTracks()) t.album}, {'Gold: Greatest Hits', 'The Singles'});

      await service.replaceTracks([service.getTrack('1')!]);
      final alone = service.albums.single;
      expect((alone.title, alone.tracks.single.trackNumber), ('Gold: Greatest Hits', 3));
    });
  });

  test(
    "featured artists are credited: their songs are on their pages, while the artist list keeps album artists",
    () async {
      final repo = MockRepository();
      final service = _service(repo);
      repo.saveTracks([
        Track(
          id: '1',
          title: 'AFFILIATED (feat. Lil Durk)',
          artist: 'Future, Lil Durk',
          artists: ['Future', 'Lil Durk'],
          album: 'I NEVER LIKED YOU',
          albumArtist: 'Future',
        ),
        Track(id: '2', title: 'WAIT FOR U', artist: 'Future', album: 'I NEVER LIKED YOU', albumArtist: 'Future'),
        Track(
          id: '3',
          title: 'Life Is Good',
          artist: 'Drake, Future',
          artists: ['Drake', 'Future'],
          album: 'Dark Lane Demo Tapes',
        ),
      ]);
      await service.initialize();

      expect(service.artists.map((a) => a.name), ['Drake', 'Future']);
      expect(service.albums.firstWhere((a) => a.title == 'Dark Lane Demo Tapes').artist, 'Drake');
      final future = service.artists.firstWhere((a) => a.name == 'Future');
      expect(future.tracks.map((t) => t.id), unorderedEquals(['1', '2', '3']));
      expect(service.getArtistByName('lil durk')!.tracks.map((t) => t.id), ['1']);
      expect(service.search('Lil Durk').map((t) => t.id), ['1']);
    },
  );

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

    service.serverConnected = true; // an account's hidden items change only while signed in to its server
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

  test(
    "the account's hidden items stay on the device for offline use, and cannot change while it is offline",
    () async {
      final repo = MockRepository();
      final service = _service(repo);
      final track = Track(
        id: 's1',
        title: 'Song 1',
        artist: 'Artist A',
        album: 'Album 1',
        streamUrl: 'http://server/api/stream/s1',
        duration: const Duration(seconds: 180),
        format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
      );
      await service.initialize();
      await service.setCurrentUser('account');
      service.serverConnected = true;
      await service.mergeServerTracks([track], const UserDataSnapshot([], [], [], {}, [], [], ['s1']));
      expect(service.tracks, isEmpty);

      // The next start, before the server answers (or when it cannot be reached): still hidden.
      final restarted = _service(repo);
      await restarted.initialize();
      await restarted.setCurrentUser('account');
      expect(restarted.isTrackIdHidden('s1'), isTrue);
      expect(restarted.tracks, isEmpty);

      // Offline, a change would be lost at the next refresh, so it is not made, nor sent; the user is told why.
      final sent = <HiddenChangeEvent>[];
      final notices = <ChangeNotice>[];
      restarted.hiddenToggled.listen(sent.add);
      restarted.changeNotice.listen(notices.add);
      expect(restarted.canChangeHidden, isFalse);
      await restarted.unhideTrack('s1');
      await restarted.hideArtist('artist-b');
      expect(restarted.isTrackIdHidden('s1'), isTrue);
      expect(restarted.hiddenArtists, isEmpty);
      expect(sent, isEmpty);
      expect(notices, [ChangeNotice.readOnlyOffline, ChangeNotice.readOnlyOffline]);

      // So is a favourite of a server track; and a playlist made meanwhile stays on this device.
      await restarted.toggleFavorite('s1');
      expect(restarted.getTrack('s1')!.isFavorite, isFalse);
      expect((await restarted.createPlaylist('On the road')).isServer, isFalse);
      expect(notices.skip(2), [ChangeNotice.readOnlyOffline, ChangeNotice.playlistKeptOnDevice]);
      notices.clear();

      // Signed in again, a change is made and sent on.
      restarted.serverConnected = true;
      await restarted.unhideTrack('s1');
      expect(restarted.tracks, hasLength(1));
      expect(sent.map((e) => (e.itemType, e.itemId, e.hidden)), [('track', 's1', false)]);

      // Without an account, hiding is the device's own business.
      await restarted.removeServerTracks();
      restarted.serverConnected = false;
      expect(restarted.canChangeHidden, isTrue);
      await restarted.hideArtist('artist-b');
      expect(restarted.isArtistHidden('artist-b'), isTrue);
      expect(sent, hasLength(1));
      await restarted.createPlaylist('Local');
      expect(notices, isEmpty);
      expect((await repo.getHiddenItems('account'))['track'], isEmpty); // the account's copy left with its tracks
    },
  );
}
