// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

LibraryService _service(LibraryRepository repo) =>
    LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');

void main() {
  setUpAll(useTempDataDirectory);

  test('indexes albums and artists', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
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
    service.initialize();

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
    final repo = testRepository();
    final service = _service(repo);
    service.initialize();

    final playlist = service.createPlaylist('Favorites Hi-Res', 'Best 24-bit FLAC tracks');
    expect(playlist.name, 'Favorites Hi-Res');

    service.addTracksToPlaylist(playlist.id, ['track_123']);
    expect(playlist.trackCount, 1);
    service.addTracksToPlaylist(playlist.id, ['track_123']); // no duplicates
    expect(playlist.trackCount, 1);

    service.renamePlaylist(playlist.id, '  Renamed ');
    expect(service.getPlaylist(playlist.id)!.name, 'Renamed');

    service.removeTrackFromPlaylist(playlist.id, 'track_123');
    expect(playlist.trackCount, 0);

    service.deletePlaylist(playlist.id);
    expect(service.playlists, isEmpty);
    expect(repo.getAllPlaylists(), isEmpty);
  });

  test('a playlist takes many tracks in one change, and its shown entries move around the ones it lacks', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
      for (final id in ['a', 'b', 'c']) TestSupport.makeTrack(id, 'Song $id'),
    ]);
    service.initialize();
    final playlist = service.createPlaylist('Mix');
    var edits = 0;
    service.playlistsChanged.listen((_) => edits++);

    service.addTracksToPlaylist(playlist.id, ['a', 'gone', 'b', 'a', 'c']);
    expect(playlist.trackIds, ['a', 'gone', 'b', 'c']);
    expect(edits, 1);

    // Shown: a, b, c. Moving c to the top keeps the missing entry among the others.
    service.movePlaylistTrack(playlist.id, 2, 0);
    expect([for (final t in service.getPlaylistTracks(playlist)) t.id], ['c', 'a', 'b']);
    service.movePlaylistTrack(playlist.id, 0, 2);
    expect([for (final t in service.getPlaylistTracks(playlist)) t.id], ['a', 'b', 'c']);
    service.movePlaylistTrack(playlist.id, 0, 9); // out of range: nothing happens
    expect(playlist.trackIds, hasLength(4));
  });

  test('a compilation in one folder becomes Various Artists, and guests stay out of the artist list', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
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
    service.initialize();

    expect(service.albums.single.artist, 'Various Artists');
    expect(service.artists.single.name, 'Various Artists');
    final resolved = service.getArtistByName('Guest Alpha')!;
    expect(resolved.name, 'Guest Alpha');
    expect(resolved.tracks, hasLength(1));
  });

  test('the dominant artist of a folder becomes its album artist', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
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
    service.initialize();

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
      final repo = testRepository()..setSetting('library_path', '/Music');
      final service = _service(repo);
      repo.replaceAllTracks(tracks);
      service.initialize();
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

        final repo = testRepository(); // no music folder known
        final service = _service(repo);
        repo.replaceAllTracks([
          song('1', 'ACDC Essentials', 'Back In Black'),
          song('2', 'ACDC Essentials', 'POWER UP'),
        ]);
        service.initialize();
        expect(service.albums, hasLength(2));
      },
    );

    test('follows the tags again when the folder no longer qualifies, and stores only the tags', () async {
      final repo = testRepository()..setSetting('library_path', '/Music');
      final service = _service(repo);
      repo.replaceAllTracks([song('1', 'GOLD', 'Gold: Greatest Hits', number: 3), song('2', 'GOLD', 'The Singles')]);
      service.initialize();
      expect(service.albums.single.title, 'GOLD');
      service.recordPlay('1'); // a write of the library: what it stores is what the tags say
      expect({for (final t in repo.getAllTracks()) t.album}, {'Gold: Greatest Hits', 'The Singles'});

      // With the other song hidden, the folder holds one album's song: it goes back to its tags.
      service.hideTrack('2');
      final alone = service.albums.single;
      expect((alone.title, alone.tracks.single.trackNumber), ('Gold: Greatest Hits', 3));
    });
  });

  test(
    "featured artists are credited: their songs are on their pages, while the artist list keeps album artists",
    () async {
      final repo = testRepository();
      final service = _service(repo);
      repo.replaceAllTracks([
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
      service.initialize();

      expect(service.artists.map((a) => a.name), ['Drake', 'Future']);
      expect(service.albums.firstWhere((a) => a.title == 'Dark Lane Demo Tapes').artist, 'Drake');
      final future = service.artists.firstWhere((a) => a.name == 'Future');
      expect(future.tracks.map((t) => t.id), unorderedEquals(['1', '2', '3']));
      expect(service.getArtistByName('lil durk')!.tracks.map((t) => t.id), ['1']);
      expect(service.search('Lil Durk').map((t) => t.id), ['1']);
    },
  );

  test('colliding track numbers keep the folder apart', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
      Track(id: '1', title: 'A', artist: 'X', album: 'Same', trackNumber: 1, filePath: '/m/f/1.flac'),
      Track(id: '2', title: 'B', artist: 'Y', album: 'Same', trackNumber: 1, filePath: '/m/f/2.flac'),
    ]);
    service.initialize();
    expect(service.albums, hasLength(2));
  });

  test('an album of hi-res and CD tracks is tagged MIXED, at the tier of its weakest track', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
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
    service.initialize();
    final album = service.albums.single;
    expect((album.tier, album.tagSpec), (QualityTier.silver, QualitySummary.mixedSpec));
  });

  test('sorting ignores accents and case', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([
      TestSupport.makeTrack('1', 'x', artist: 'zebra', album: 'Zulu'),
      TestSupport.makeTrack('2', 'y', artist: 'Ábel', album: 'Ébredés'),
      TestSupport.makeTrack('3', 'z', artist: 'bach', album: 'b'),
    ]);
    service.initialize();
    expect(service.artists.map((a) => a.name), ['Ábel', 'bach', 'zebra']);
    expect(service.albums.map((a) => a.title), ['b', 'Ébredés', 'Zulu']);
  });

  test('server tracks change only while signed in to the server, local ones always', () async {
    final repo = testRepository();
    final service = _service(repo);
    final local = TestSupport.makeTrack('local', 'Local');
    final server = TestSupport.makeServerTrack('server', 'Server');
    repo.replaceAllTracks([local, server]);
    service.initialize();

    final toggled = <String>[];
    service.favoriteToggled.listen((t) => toggled.add(t.id));

    service.serverConnected = true;
    service.toggleFavorite('server');
    expect(service.getTrack('server')!.isFavorite, isTrue);
    expect(toggled, ['server']); // a change the server has to hear about

    service.toggleFavorite('local');
    expect(toggled, ['server']); // local tracks stay on the device

    service.serverConnected = false;
    service.toggleFavorite('server');
    expect(service.getTrack('server')!.isFavorite, isTrue); // cannot be changed while the server is away
    service.recordPlay('server');
    expect(service.getTrack('server')!.playCount, 0);
    service.recordPlay('local');
    expect(service.getTrack('local')!.playCount, 1);
  });

  test('a favourite remembers when it was marked: here, or on the server', () async {
    final repo = testRepository();
    final service = _service(repo);
    repo.replaceAllTracks([TestSupport.makeTrack('local', 'Local')]);
    service.initialize();

    final before = DateTime.now().toUtc();
    service.toggleFavorite('local');
    final marked = service.getTrack('local')!.favoritedAt;
    expect(marked != null && !marked.isBefore(before), isTrue);
    expect(repo.getAllTracks().single.favoritedAt, marked); // and stored
    service.toggleFavorite('local');
    expect(service.getTrack('local')!.favoritedAt, isNull);

    // A server's favourites come with the time the account marked them.
    final when = DateTime.utc(2026, 2, 3);
    service.mergeServerTracks([
      TestSupport.makeServerTrack('s1', 'Server'),
    ], UserDataSnapshot(['s1'], const [], const [], {'s1': when}));
    expect(service.getTrack('s1')!.favoritedAt, when);
  });

  test('a rescan that reads a changed file again keeps its favourite, play count and date added', () async {
    final folder = Directory.systemTemp.createTempSync('wiretune_rescan_');
    final file = '${folder.path}/Song.wav';
    writeWav(file, 44100);
    final service = _service(testRepository());
    service.initialize();
    expect(await service.scanFolder(folder.path), isTrue);
    final id = service.tracks.single.id;
    final added = service.tracks.single.dateAdded;
    service.toggleFavorite(id);
    service.recordPlay(id);

    writeWav(file, 44100, seconds: 2); // the file changed: the next scan reads it again
    expect(await service.scanFolder(folder.path), isTrue);

    final track = service.getTrack(id)!;
    expect(track.duration, const Duration(seconds: 2));
    expect((track.isFavorite, track.playCount, track.dateAdded), (true, 1, added));
  });

  test('content hiding: tracks, albums, artists, precedence, non-destructive hierarchy, and playback', () async {
    final repo = testRepository();
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
    repo.replaceAllTracks([t1, t2, t3]);
    service.initialize();

    expect(service.tracks, hasLength(3));
    expect(service.albums, hasLength(2));
    expect(service.artists, hasLength(2));
    expect(service.favorites, hasLength(1));

    // 1. Hide track 1
    service.hideTrack('t1');
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
    service.hideAlbum(album1Id);
    expect(service.hiddenAlbums, contains(album1Id));
    expect(service.isTrackHidden(t2), isTrue); // t2 is hidden via album
    expect(service.albums.map((a) => a.id), [t3.albumId]);
    expect(service.tracks.map((t) => t.id), ['t3']);

    // 3. Unhide Album 1: Non-destructive hierarchy test!
    // t1 was explicitly hidden, so when Album 1 is unhidden, t1 MUST STILL be hidden, while t2 reappears.
    service.unhideAlbum(album1Id);
    expect(service.hiddenAlbums, isNot(contains(album1Id)));
    expect(service.isTrackHidden(t1), isTrue); // still explicitly hidden
    expect(service.isTrackHidden(t2), isFalse); // visible again
    expect(service.tracks.map((t) => t.id), ['t2', 't3']);

    // 4. Hide Artist A: hides Album 1 and all its tracks
    final artistAId = service.artists.firstWhere((a) => a.name == 'Artist A').id;
    service.hideArtist(artistAId);
    expect(service.hiddenArtists, contains(artistAId));
    expect(service.isTrackHidden(t2), isTrue);
    expect(service.artists.map((a) => a.name), ['Artist B']);
    expect(service.tracks.map((t) => t.id), ['t3']);

    // 5. Unhide Artist A: non-destructive hierarchy
    service.unhideArtist(artistAId);
    expect(service.hiddenArtists, isNot(contains(artistAId)));
    expect(service.isTrackHidden(t1), isTrue); // still explicitly hidden
    expect(service.isTrackHidden(t2), isFalse); // visible again

    // 6. Unhide All
    service.unhideAll();
    expect(service.isTrackHidden(t1), isFalse);
    expect(service.tracks, hasLength(3));
    expect(service.favorites, hasLength(1));
  });

  test('content hiding: user switching isolates hidden items', () async {
    final repo = testRepository();
    final service = _service(repo);
    final t1 = Track(
      id: 't1',
      title: 'Song 1',
      artist: 'Artist A',
      album: 'Album 1',
      duration: const Duration(seconds: 180),
      format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
    );
    repo.replaceAllTracks([t1]);
    service.initialize();

    service.serverConnected = true; // an account's hidden items change only while signed in to its server
    service.setCurrentUser('user_alpha');
    service.hideTrack('t1');
    expect(service.isTrackHidden(t1), isTrue);
    expect(service.tracks, isEmpty);

    // Switch to user_beta
    service.setCurrentUser('user_beta');
    expect(service.isTrackHidden(t1), isFalse);
    expect(service.tracks, hasLength(1));

    // Switch back to user_alpha
    service.setCurrentUser('user_alpha');
    expect(service.isTrackHidden(t1), isTrue);
    expect(service.tracks, isEmpty);
  });

  test(
    "the account's hidden items stay on the device for offline use, and cannot change while it is offline",
    () async {
      final repo = testRepository();
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
      service.initialize();
      service.setCurrentUser('account');
      service.serverConnected = true;
      service.mergeServerTracks([track], const UserDataSnapshot([], [], [], {}, [], [], ['s1']));
      expect(service.tracks, isEmpty);

      // The next start, before the server answers (or when it cannot be reached): still hidden.
      final restarted = _service(repo);
      restarted.initialize();
      restarted.setCurrentUser('account');
      expect(restarted.hiddenTracks, contains('s1'));
      expect(restarted.tracks, isEmpty);

      // Offline, a change would be lost at the next refresh, so it is not made, nor sent; the user is told why.
      final sent = <HiddenChangeEvent>[];
      final notices = <ChangeNotice>[];
      restarted.hiddenToggled.listen(sent.add);
      restarted.changeNotice.listen(notices.add);
      expect(restarted.canChangeHidden, isFalse);
      restarted.unhideTrack('s1');
      restarted.hideArtist('artist-b');
      expect(restarted.hiddenTracks, contains('s1'));
      expect(restarted.hiddenArtists, isEmpty);
      expect(sent, isEmpty);
      expect(notices, [ChangeNotice.readOnlyOffline, ChangeNotice.readOnlyOffline]);

      // So is a favourite of a server track; and a playlist made meanwhile stays on this device.
      restarted.toggleFavorite('s1');
      expect(restarted.getTrack('s1')!.isFavorite, isFalse);
      expect((restarted.createPlaylist('On the road')).isServer, isFalse);
      expect(notices.skip(2), [ChangeNotice.readOnlyOffline, ChangeNotice.playlistKeptOnDevice]);
      notices.clear();

      // Signed in again, a change is made and sent on.
      restarted.serverConnected = true;
      restarted.unhideTrack('s1');
      expect(restarted.tracks, hasLength(1));
      expect(sent.map((e) => (e.itemType, e.itemId, e.hidden)), [('track', 's1', false)]);

      // Without an account, hiding is the device's own business.
      restarted.removeServerTracks();
      restarted.serverConnected = false;
      expect(restarted.canChangeHidden, isTrue);
      restarted.hideArtist('artist-b');
      expect(restarted.hiddenArtists, contains('artist-b'));
      expect(sent, hasLength(1));
      restarted.createPlaylist('Local');
      expect(notices, isEmpty);
      expect(repo.getHiddenItems('account')['track'], isEmpty); // the account's copy left with its tracks
    },
  );

  group('server and local music together', () {
    Track local(String id, String title, String artist, {String album = 'Unknown Album', double seconds = 0}) => Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      filePath: '/music/$id.flac',
    );
    Track server(String id, String title, String artist, {String album = 'Unknown Album', double seconds = 0}) => Track(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      streamUrl: 'http://localhost:5200/api/stream/$id',
    );
    UserDataSnapshot account({List<String> favorites = const [], List<PlaylistData> playlists = const []}) =>
        UserDataSnapshot(favorites, const [], playlists);

    test('a server refresh keeps the local tracks, and a song in both places is the local file', () async {
      final repo = testRepository()
        ..replaceAllTracks([local('loc-1', 'Hey Jude', 'The Beatles', album: '1', seconds: 431)]);
      final library = _service(repo)..initialize();

      library.mergeServerTracks([
        server('srv-jude', 'Hey Jude (Remastered 2015)', 'The Beatles', album: '1 (Remastered)', seconds: 431),
        server('srv-letitbe', 'Let It Be', 'The Beatles', album: 'Let It Be', seconds: 243),
      ], account(favorites: ['srv-jude']));

      expect(library.tracks, hasLength(2));
      final heyJude = library.tracks.firstWhere((t) => t.title.startsWith('Hey Jude'));
      expect((heyJude.id, heyJude.isLocal, heyJude.isFavorite), ('loc-1', true, true)); // the favourite came along
      expect(library.tracks.firstWhere((t) => t.title == 'Let It Be').isLocal, isFalse);
    });

    test("this device's playlists point at the local file, the account's keep the server's IDs", () async {
      final repo = testRepository()
        ..savePlaylist(Playlist(id: 'pl-1', name: 'Mine', trackIds: ['srv-jude']))
        ..replaceAllTracks([local('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431)]);
      final library = _service(repo)..initialize();
      final now = DateTime.now().toUtc();

      library.mergeServerTracks(
        [server('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431)],
        account(
          playlists: [
            PlaylistData('srv-pl', 'Account', null, const ['srv-jude'], now, now),
          ],
        ),
      );

      final own = library.getPlaylist('pl-1')!;
      expect(own.trackIds, ['loc-jude']);
      final accounts = library.getPlaylist('srv-pl')!;
      expect(accounts.isServer, isTrue);
      expect(accounts.trackIds, ['srv-jude']);
      for (final playlist in [own, accounts]) {
        expect(library.getPlaylistTracks(playlist).single.id, 'loc-jude');
      }
    });

    test('another device names a matched track by its server ID, and this one finds its local file by it', () async {
      final repo = testRepository()
        ..replaceAllTracks([
          local('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431),
          local('loc-only', 'Demo', 'Me', seconds: 100),
        ]);
      final library = _service(repo)..initialize();
      library.mergeServerTracks([
        server('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431),
        server('srv-help', 'Help!', 'The Beatles', seconds: 140),
      ], account());

      expect(library.sharedId(library.getTrack('loc-jude')!), 'srv-jude');
      expect(library.sharedId(library.getTrack('srv-help')!), 'srv-help');
      expect(library.sharedId(library.getTrack('loc-only')!), 'loc-only');
      expect(library.resolveTracks(['srv-help', 'srv-jude', 'unknown', 'loc-only']).map((t) => t.id), [
        'srv-help',
        'loc-jude',
        'loc-only',
      ]);
    });

    test('the session moves between local, hybrid and back on sign-out', () async {
      final repo = testRepository()..replaceAllTracks([local('loc-1', 'Local Song', 'Local Artist')]);
      final library = _service(repo)..initialize();
      final session = ServerSession(library, repo);
      addTearDown(session.dispose);
      session.initialize();
      expect(session.source, LibrarySource.none);

      session.useLocalLibrary();
      expect(session.source, LibrarySource.local);

      library.mergeServerTracks([server('srv-1', 'Server Song', 'Server Artist')], account());
      session.useLocalLibrary();
      expect(session.source, LibrarySource.hybrid);
      expect(library.tracks, hasLength(2));

      await session.logout();
      expect(session.source, LibrarySource.local);
      expect(library.tracks.single.id, 'loc-1');
      expect(repo.getSetting('library_source'), 'local');
    });
  });
}
