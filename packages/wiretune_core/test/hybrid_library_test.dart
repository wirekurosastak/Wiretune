// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

Track _t(
  String id,
  String title,
  String artist, {
  String album = 'Unknown Album',
  double seconds = 0,
  String path = '',
  String? stream,
}) => Track(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: Duration(milliseconds: (seconds * 1000).round()),
  filePath: path,
  streamUrl: stream,
);

/// What the server holds for the signed-in account; it comes with every merge of the server's tracks.
UserDataSnapshot _account({List<String> favorites = const []}) => UserDataSnapshot(favorites, const [], const []);

void main() {
  setUpAll(useTempDataDirectory);

  test('an exact match is a duplicate', () {
    final local = _t(
      'loc-1',
      'Hotel California',
      'Eagles',
      album: 'Hotel California',
      seconds: 390,
      path: '/music/hotel.flac',
    );
    final server = _t(
      'srv-1',
      'Hotel California',
      'Eagles',
      album: 'Hotel California',
      seconds: 390,
      path: '/server/hotel.flac',
      stream: 'http://localhost:5200/api/stream/srv-1',
    );
    expect(TrackDeduplication.isDuplicate(local, server), isTrue);
  });

  test('a remastered title on another album is a duplicate within the length tolerance', () {
    final local = _t(
      'loc-1',
      'Hotel California',
      'Eagles',
      album: 'Their Greatest Hits',
      seconds: 390.5,
      path: '/music/hotel.mp3',
    );
    final server = _t(
      'srv-1',
      'Hotel California (2013 Remaster)',
      'Eagles',
      album: 'Hotel California (Deluxe Edition)',
      seconds: 391.2,
      stream: 'http://localhost:5200/api/stream/srv-1',
    );
    expect(TrackDeduplication.isDuplicate(local, server), isTrue);
  });

  test('different songs or artists, and live versions, are not duplicates', () {
    final local = _t('a', 'Take It Easy', 'Eagles', seconds: 210);
    expect(TrackDeduplication.isDuplicate(local, _t('b', 'Take It Easy', 'Jackson Browne', seconds: 210)), isFalse);
    expect(TrackDeduplication.isDuplicate(local, _t('c', 'Desperado', 'Eagles', seconds: 210)), isFalse);
    expect(
      TrackDeduplication.isDuplicate(
        _t('d', 'Hotel California', 'Eagles', seconds: 390),
        _t('e', 'Hotel California (Live)', 'Eagles', seconds: 430),
      ),
      isFalse,
    );
  });

  test('merging prefers the local track and takes over the server copy\'s data', () {
    final local = _t(
      'loc-1',
      'Comfortably Numb',
      'Pink Floyd',
      album: 'The Wall',
      seconds: 382,
      path: '/local/numb.mp3',
    )..playCount = 2;
    final server =
        _t(
            'srv-1',
            'Comfortably Numb',
            'Pink Floyd',
            album: 'The Wall',
            seconds: 382,
            path: '/server/numb.flac',
            stream: 'http://localhost:5200/api/stream/srv-1',
          )
          ..isFavorite = true
          ..playCount = 10
          ..hasCoverArt = true
          ..coverArtPath = 'http://localhost:5200/api/covers/srv-1';
    final aliases = <String, String>{};

    final merged = TrackDeduplication.mergeTracks([local], [server], aliases);

    final track = merged.single;
    expect(track.id, 'loc-1');
    expect(track.filePath, '/local/numb.mp3');
    expect(track.streamUrl, isNull);
    expect(track.isLocal, isTrue);
    expect(track.isFavorite, isTrue);
    expect(track.playCount, 10);
    expect(track.hasCoverArt, isTrue);
    expect(track.coverArtPath, 'http://localhost:5200/api/covers/srv-1');
    expect(aliases['srv-1'], 'loc-1');
  });

  test('merging without duplicates keeps every track', () {
    final aliases = <String, String>{};
    final merged = TrackDeduplication.mergeTracks(
      [_t('loc-1', 'Song A', 'Artist 1', seconds: 180, path: '/local/a.mp3')],
      [_t('srv-1', 'Song B', 'Artist 2', seconds: 200, stream: 'http://localhost:5200/api/stream/srv-1')],
      aliases,
    );
    expect(merged, hasLength(2));
    expect(merged.any((t) => t.id == 'loc-1' && t.isLocal), isTrue);
    expect(merged.any((t) => t.id == 'srv-1' && !t.isLocal), isTrue);
    expect(aliases, isEmpty);
  });

  test('merging server tracks keeps the local ones and prefers local duplicates', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    repo.saveTracks([_t('loc-1', 'Hey Jude', 'The Beatles', album: '1', seconds: 431, path: '/music/hey_jude.flac')]);
    await library.initialize();

    await library.mergeServerTracks([
      _t(
        'srv-jude',
        'Hey Jude (Remastered 2015)',
        'The Beatles',
        album: '1 (Remastered)',
        seconds: 431,
        stream: 'http://localhost:5200/api/stream/srv-jude',
      ),
      _t(
        'srv-letitbe',
        'Let It Be',
        'The Beatles',
        album: 'Let It Be',
        seconds: 243,
        stream: 'http://localhost:5200/api/stream/srv-letitbe',
      ),
    ], _account(favorites: ['srv-jude']));

    expect(library.tracks, hasLength(2));
    final heyJude = library.tracks.firstWhere((t) => t.title.startsWith('Hey Jude'));
    expect(heyJude.id, 'loc-1');
    expect(heyJude.isLocal, isTrue);
    expect(heyJude.isFavorite, isTrue); // merged from the server
    expect(library.tracks.firstWhere((t) => t.title == 'Let It Be').isLocal, isFalse);
  });

  test('deduplication points local playlists at the local track', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    await repo.savePlaylist(Playlist(id: 'pl-1', name: 'Favorites', trackIds: ['srv-jude']));
    repo.saveTracks([_t('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431, path: '/music/hey_jude.flac')]);
    await library.initialize();

    await library.mergeServerTracks([
      _t('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431, stream: 'http://localhost:5200/api/stream/srv-jude'),
    ], _account());

    final playlist = library.getPlaylist('pl-1')!;
    expect(playlist.trackIds.first, 'loc-jude');
    expect(library.getPlaylistTracks(playlist).single.id, 'loc-jude');
  });

  test('another device names a matched track by its server ID, and this one finds its local file by it', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    repo.saveTracks([
      _t('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431, path: '/music/hey_jude.flac'),
      _t('loc-only', 'Demo', 'Me', seconds: 100, path: '/music/demo.flac'),
    ]);
    await library.initialize();
    await library.mergeServerTracks([
      _t('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431, stream: 'http://localhost:5200/api/stream/srv-jude'),
      _t('srv-help', 'Help!', 'The Beatles', seconds: 140, stream: 'http://localhost:5200/api/stream/srv-help'),
    ], _account());

    final jude = library.getTrack('loc-jude')!;
    expect(library.sharedId(jude), 'srv-jude');
    expect(library.sharedId(library.getTrack('srv-help')!), 'srv-help');
    expect(library.sharedId(library.getTrack('loc-only')!), 'loc-only');
    expect(library.resolveTracks(['srv-help', 'srv-jude', 'unknown', 'loc-only']).map((t) => t.id), [
      'srv-help',
      'loc-jude',
      'loc-only',
    ]);
  });

  test('server playlists keep the server IDs and still resolve to the local copy', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    repo.saveTracks([_t('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431, path: '/music/hey_jude.flac')]);
    await library.initialize();

    final now = DateTime.now().toUtc();
    await library.mergeServerTracks(
      [_t('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431, stream: 'http://localhost:5200/api/stream/srv-jude')],
      UserDataSnapshot(const [], const [], [
        PlaylistData('srv-pl', 'Mine', null, const ['srv-jude'], now, now),
      ]),
    );

    final playlist = library.getPlaylist('srv-pl')!;
    expect(playlist.isServer, isTrue);
    expect(playlist.trackIds, ['srv-jude']);
    expect(library.getPlaylistTracks(playlist).single.id, 'loc-jude');
  });

  test('another device names a matched track by its server ID, and this one finds its local file by it', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    repo.saveTracks([
      _t('loc-jude', 'Hey Jude', 'The Beatles', seconds: 431, path: '/music/hey_jude.flac'),
      _t('loc-only', 'Demo', 'Me', seconds: 100, path: '/music/demo.flac'),
    ]);
    await library.initialize();
    await library.mergeServerTracks([
      _t('srv-jude', 'Hey Jude', 'The Beatles', seconds: 431, stream: 'http://localhost:5200/api/stream/srv-jude'),
      _t('srv-help', 'Help!', 'The Beatles', seconds: 140, stream: 'http://localhost:5200/api/stream/srv-help'),
    ], _account());

    final jude = library.getTrack('loc-jude')!;
    expect(library.sharedId(jude), 'srv-jude');
    expect(library.sharedId(library.getTrack('srv-help')!), 'srv-help');
    expect(library.sharedId(library.getTrack('loc-only')!), 'loc-only');
    expect(library.resolveTracks(['srv-help', 'srv-jude', 'unknown', 'loc-only']).map((t) => t.id), [
      'srv-help',
      'loc-jude',
      'loc-only',
    ]);
  });

  test('the session moves between local, hybrid and back on sign-out', () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    await library.initialize();
    final session = ServerSession(library, repo);
    addTearDown(session.dispose);
    await session.initialize();
    expect(session.source, LibrarySource.none);

    await library.replaceTracks([_t('loc-1', 'Local Song', 'Local Artist', path: '/local/path.flac')]);
    await session.useLocalLibrary();
    expect(session.source, LibrarySource.local);

    await library.mergeServerTracks([
      _t('srv-1', 'Server Song', 'Server Artist', stream: 'http://server/api/stream/srv-1'),
    ], _account());
    await session.useLocalLibrary();
    expect(session.source, LibrarySource.hybrid);
    expect(library.tracks, hasLength(2));

    await session.logout();
    expect(session.source, LibrarySource.local);
    expect(library.tracks.single.id, 'loc-1');
    expect(repo.settings['library_source'], 'local');
  });
}
