// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// A Wiretune server as far as a signed-in player sees it: the track list, the account's data, the audio (with ranges)
/// and the album covers. Counts what it was asked for.
class FakeServer {
  static const String url = 'http://server:5200';

  final Map<String, (Track, List<int>)> tracks = {};
  final List<String> favorites = [];
  final List<PlaylistData> playlists = [];
  final List<http.BaseRequest> streamRequests = [];

  /// The next stream breaks off after this many bytes.
  int? cutAfter;

  /// The cover route answers with an error.
  bool coversFail = false;

  void add(Track track, List<int> bytes) {
    track
      ..fileSizeBytes = bytes.length
      ..fileModifiedAt ??= DateTime.utc(2026, 1, 1);
    tracks[track.id] = (track, bytes);
  }

  late final MockClient client = MockClient.streaming((request, body) async {
    final path = request.url.path;
    http.StreamedResponse json(Object? value) =>
        http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(value))), 200);
    if (path == '/api/auth/setup-required') return json({'setupRequired': false});
    if (path == '/api/auth/login') {
      final user = UserInfo('u1', 'owner', true, DateTime.utc(2026), null);
      return json(AuthResponse('sign-in-token', user, DateTime.utc(2027)).toJson());
    }
    if (path == '/api/auth/me') return json(UserInfo('u1', 'owner', true, DateTime.utc(2026), null).toJson());
    if (path == '/api/tracks') return json([for (final (t, _) in tracks.values) t.toJson()]);
    if (path == '/api/me/data') {
      return json(UserDataSnapshot(List.of(favorites), const [], List.of(playlists)).toJson());
    }
    if (path.startsWith('/api/me/')) return json({});
    if (path.startsWith('/api/cover/album/')) {
      if (coversFail) return http.StreamedResponse(Stream.empty(), 500);
      return http.StreamedResponse(Stream.value(pngBytes), 200, headers: {'content-type': 'image/png'});
    }
    if (path.startsWith('/api/stream/')) {
      streamRequests.add(request);
      if (request.headers['Authorization'] != 'Bearer sign-in-token') return http.StreamedResponse(Stream.empty(), 401);
      final entry = tracks[Uri.decodeComponent(path.substring('/api/stream/'.length))];
      if (entry == null) return http.StreamedResponse(Stream.empty(), 404);
      final bytes = entry.$2;
      final range = RegExp(r'^bytes=(\d+)-$').firstMatch(request.headers['Range'] ?? '');
      final start = range == null ? 0 : int.parse(range.group(1)!);
      final rest = bytes.sublist(start);
      final cut = cutAfter;
      cutAfter = null;
      final stream = cut == null
          ? Stream.value(rest)
          : Stream<List<int>>.fromIterable([rest.sublist(0, cut)]).followedBy(http.ClientException('Connection reset'));
      return http.StreamedResponse(
        stream,
        range == null ? 200 : 206,
        contentLength: rest.length,
        headers: {if (range != null) 'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}'},
      );
    }
    return http.StreamedResponse(Stream.empty(), 404);
  });
}

extension<T> on Stream<T> {
  /// This stream, then [error].
  Stream<T> followedBy(Object error) async* {
    yield* this;
    throw error;
  }
}

final List<int> pngBytes = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAJ0lEQVR4nGN44JDg0PDA4UDDgw0GDHDWA4cEBjjLoeEBA5zlcKABAJiSGYEhhgnzAAAAAElFTkSuQmCC',
);

List<int> audio(int seed, [int length = 50000]) => List<int>.generate(length, (i) => (i * 31 + seed) & 0xff);

/// One player: its library, server session and downloads, over a database of its own (or [start]'s `repo`).
class Player {
  Player._(this.library, this.session, this.downloads);

  final LibraryService library;
  final ServerSession session;
  final DownloadService downloads;

  static Future<Player> start(FakeServer server, String directory, {LibraryRepository? repo}) async {
    repo ??= testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(directory, 'covers-cache'));
    final session = ServerSession(library, repo, ServerClient(server.client));
    final downloads = DownloadService(
      library,
      session,
      directory: p.join(directory, 'Downloads'),
      workDirectory: p.join(directory, 'DownloadCache'),
      client: server.client,
    );
    library.initialize();
    session.initialize();
    await downloads.initialize();
    return Player._(library, session, downloads);
  }

  Future<void> signIn() async {
    await session.connect(FakeServer.url);
    expect(await session.login('owner', 'password', true), isNull);
  }

  void close() {
    downloads.dispose();
    session.dispose();
  }
}

Future<void> until(bool Function() condition, [String? reason]) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason ?? 'timed out');
}

/// Lets every pending event and file operation run.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late FakeServer server;
  late String directory;
  final players = <Player>[];

  setUp(() {
    server = FakeServer();
    directory = Directory.systemTemp.createTempSync('wiretune_downloads_').path;
  });
  tearDown(() {
    for (final player in players) {
      player.close();
    }
    players.clear();
    Directory(directory).deleteSync(recursive: true);
  });

  Future<Player> signedIn({LibraryRepository? repo}) async {
    final player = await Player.start(server, directory, repo: repo);
    players.add(player);
    await player.signIn();
    return player;
  }

  Track serverTrack(String id, String title, String album, {int number = 1, int? disc}) =>
      TestSupport.makeServerTrack(id, title, album: album, trackNumber: number, discNumber: disc)..hasCoverArt = true;

  String work(String name) => p.join(directory, 'DownloadCache', name);

  List<String> filesIn(String folder) => Directory(folder).existsSync()
      ? [
          for (final f in Directory(folder).listSync(recursive: true).whereType<File>())
            p.relative(f.path, from: folder),
        ]
      : [];

  test('an album is downloaded with its cover, and then plays from the copies without the server', () async {
    server
      ..add(serverTrack('a1', 'One', 'Album A'), audio(1))
      ..add(serverTrack('a2', 'Two', 'Album A', number: 2), audio(2))
      ..add(serverTrack('b1', 'Other', 'Album B'), audio(3));
    final player = await signedIn();
    final downloads = player.downloads;
    final album = player.library.albums.firstWhere((a) => a.title == 'Album A');

    downloads.setAlbumDownloaded(album.id, true);
    await until(() => downloads.doneCount == 2);
    expect(downloads.wantedCount, 2);
    for (final track in album.tracks) {
      expect(downloads.stateOf(track), DownloadState.done);
      expect(File(downloads.localCopy(track)!).readAsBytesSync(), server.tracks[track.id]!.$2);
    }
    final other = player.library.getTrack('b1')!;
    expect(downloads.stateOf(other), DownloadState.none);
    expect(downloads.localCopy(other), isNull);
    expect(server.streamRequests.map((r) => r.url.pathSegments.last), unorderedEquals(['a1', 'a2']));
    // One cover for the album, under its URL.
    expect(File(downloads.localCover(album.tracks.first.coverArtPath!)!).readAsBytesSync(), pngBytes);
    expect(downloads.bytesOnDisk, 2 * 50000 + pngBytes.length);

    // The engine plays the copy, and doesn't ask the (perhaps unreachable) server for a stream token.
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    var tokenRequests = 0;
    engine
      ..setStreamTokenProvider(() async {
        tokenRequests++;
        return 'stream-token';
      })
      ..setOfflineCopyProvider(downloads.localCopy);
    await engine.playTrack(album.tracks.first);
    expect(driver.lastSource, downloads.localCopy(album.tracks.first));
    expect(engine.signalPathDescription, contains('Downloaded copy'));
    await engine.playTrack(other);
    expect(driver.lastSource, '${FakeServer.url}/api/stream/b1?token=stream-token');
    expect(tokenRequests, 1);
  });

  test("an artist's albums are downloaded, also one that arrives later; unmarking deletes them", () async {
    server
      ..add(serverTrack('a1', 'One', 'Album A'), audio(1))
      ..add(serverTrack('b1', 'Two', 'Album B'), audio(2))
      ..add(TestSupport.makeServerTrack('x1', 'Else', artist: 'Someone Else', album: 'Album X'), audio(3));
    final player = await signedIn();
    final downloads = player.downloads;
    final artist = player.library.getArtistByName('Artist')!;

    downloads.setArtistDownloaded(artist.id, true);
    await until(() => downloads.doneCount == 2);
    expect(downloads.isArtistDownloaded(artist.id), isTrue);
    expect(downloads.stateOf(player.library.getTrack('x1')!), DownloadState.none);

    // A new album of the artist follows once the library knows it.
    server.add(serverTrack('c1', 'Three', 'Album C'), audio(4));
    await player.session.refreshLibrary();
    await until(() => downloads.doneCount == 3);

    downloads.setArtistDownloaded(artist.id, false);
    await until(() => filesIn(downloads.directory).isEmpty);
  });

  test('a playlist and the favourites keep their copies in step; unmarking deletes them', () async {
    for (final (id, number) in [('t1', 1), ('t2', 2), ('t3', 3)]) {
      server.add(serverTrack(id, 'Song $id', 'Album', number: number), audio(number));
    }
    final now = DateTime.utc(2026);
    server.playlists.add(PlaylistData('p1', 'Road', null, ['t1'], now, now));
    final player = await signedIn();
    final downloads = player.downloads;
    final library = player.library;
    Track track(String id) => library.getTrack(id)!;

    downloads.setPlaylistDownloaded('p1', true);
    await until(() => downloads.stateOf(track('t1')) == DownloadState.done);

    // The playlist grows: the new track follows; it shrinks: the copy goes.
    library.addTracksToPlaylist('p1', ['t2']);
    await until(() => downloads.stateOf(track('t2')) == DownloadState.done);
    final t1Copy = downloads.localCopy(track('t1'))!;
    library.removeTrackFromPlaylist('p1', 't1');
    await until(() => !File(t1Copy).existsSync());
    expect(downloads.localCopy(track('t1')), isNull);

    // The favourites, likewise.
    downloads.setFavoritesDownloaded(true);
    library.toggleFavorite('t3');
    await until(() => downloads.stateOf(track('t3')) == DownloadState.done);
    final t3Copy = downloads.localCopy(track('t3'))!;
    library.toggleFavorite('t3');
    await until(() => !File(t3Copy).existsSync());

    // A single track that is also in the playlist keeps its copy when the playlist is unmarked.
    downloads.setTrackDownloaded('t2', true);
    downloads.setPlaylistDownloaded('p1', false);
    await settle();
    expect(downloads.stateOf(track('t2')), DownloadState.done);

    downloads.removeAll();
    await until(() => filesIn(downloads.directory).isEmpty);
    expect(filesIn(work('covers')), isEmpty);
    expect(downloads.bytesOnDisk, 0);
    expect((downloads.isTrackDownloaded('t2'), downloads.areFavoritesDownloaded), (false, false));
  });

  test('files Wiretune did not download are never taken for copies, overwritten or deleted', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..add(serverTrack('t2', 'Other', 'Album', number: 2), audio(2));
    final player = await signedIn();
    final downloads = player.downloads;
    final folder = p.join(downloads.directory, 'Artist', 'Album');
    Directory(folder).createSync(recursive: true);
    final notes = File(p.join(downloads.directory, 'user_notes.txt'))..writeAsStringSync('keep me');
    // Where the copy of t1 would go, a file of the user's own (another size than the server's).
    final mine = File(p.join(folder, '01 - Song.flac'))..writeAsStringSync('my own recording');

    downloads.setAlbumDownloaded(player.library.albums.single.id, true);
    await until(() => downloads.doneCount == 2);
    final copy = downloads.localCopy(player.library.getTrack('t1')!)!;
    expect(p.basename(copy), '01 - Song (2).flac');
    expect(File(copy).readAsBytesSync(), audio(1));
    expect(mine.readAsStringSync(), 'my own recording');

    downloads.removeAll();
    await until(() => !File(copy).existsSync());
    expect(mine.readAsStringSync(), 'my own recording');
    expect(notes.readAsStringSync(), 'keep me');
    expect(downloads.bytesOnDisk, 0);
  });

  test('a copy follows the server file: a changed file is fetched again and then replaces the old copy', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final player = await signedIn();
    final downloads = player.downloads;
    downloads.setTrackDownloaded('t1', true);
    await until(() => downloads.doneCount == 1);
    final first = downloads.localCopy(player.library.getTrack('t1')!)!;

    // Retagged on the server: same track, other bytes and modification time.
    server.tracks.clear();
    server.add(serverTrack('t1', 'Song', 'Album')..fileModifiedAt = DateTime.utc(2026, 2, 1), audio(9, 50100));
    final requestsBefore = server.streamRequests.length;
    await player.session.refreshLibrary();
    final track = player.library.getTrack('t1')!;
    await until(() => downloads.stateOf(track) == DownloadState.done);

    final second = downloads.localCopy(track)!;
    expect(second, first);
    expect(File(second).readAsBytesSync(), audio(9, 50100));
    expect(server.streamRequests.length, requestsBefore + 1);
    expect(filesIn(downloads.directory).where((n) => !n.startsWith('covers')), hasLength(1));
  });

  test('an interrupted download continues where it stopped', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..cutAfter = 20000;
    final player = await signedIn();
    final downloads = player.downloads;
    downloads.setTrackDownloaded('t1', true);
    await until(() => downloads.errorMessage != null);
    expect(downloads.errorMessage, contains('Connection reset'));
    expect(downloads.doneCount, 0);

    // The session reconnecting (or the retry timer) starts it again, with a range request for the rest.
    await player.session.refreshLibrary();
    await until(() => downloads.doneCount == 1);
    expect(server.streamRequests.last.headers['Range'], 'bytes=20000-');
    expect(File(downloads.localCopy(player.library.getTrack('t1')!)!).readAsBytesSync(), audio(1));
    expect(downloads.errorMessage, isNull);
    expect(filesIn(downloads.directory).where((n) => n.endsWith('.part')), isEmpty);
    expect(filesIn(work('partial')), isEmpty);
  });

  test('a track the server lost is not asked for again until the library is refreshed', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..add(serverTrack('t2', 'Gone', 'Album', number: 2), audio(2));
    final player = await signedIn();
    final downloads = player.downloads;
    final library = player.library;

    // The server forgets t2 between the listing and the download.
    final lost = server.tracks.remove('t2')!;
    downloads.setAlbumDownloaded(library.albums.single.id, true);
    await until(() => downloads.doneCount == 1);
    downloads.setTrackDownloaded('t1', true); // another change: another pass over the wanted tracks
    await settle();
    Iterable<http.BaseRequest> asksForT2() => server.streamRequests.where((r) => r.url.path.endsWith('/t2'));
    expect(asksForT2(), hasLength(1));
    expect(downloads.stateOf(library.getTrack('t2')!), DownloadState.queued);

    // It is back, and the library is refreshed: asked for once more, and fetched.
    server.tracks['t2'] = lost;
    await player.session.refreshLibrary();
    await until(() => downloads.doneCount == 2);
    expect(asksForT2(), hasLength(2));
  });

  test('marks made while the server is out of reach wait for it', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final repo = testRepository();
    (await signedIn(repo: repo)).close();
    players.clear();

    // A restart without the server: the cached library still lists the track.
    final player = await Player.start(server, directory, repo: repo);
    players.add(player);
    expect(player.session.isLoggedIn, isFalse);
    player.downloads.setTrackDownloaded('t1', true);
    await settle();
    expect(server.streamRequests, isEmpty);
    expect(player.downloads.isWaitingForServer, isTrue);
    expect(player.downloads.stateOf(player.library.getTrack('t1')!), DownloadState.queued);

    await player.signIn();
    await until(() => player.downloads.doneCount == 1);
    expect(player.downloads.isWaitingForServer, isFalse);
  });

  test('the marks and the copies survive a restart, with nothing downloaded twice', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final repo = testRepository();
    final first = await signedIn(repo: repo);
    first.downloads.setTrackDownloaded('t1', true);
    await until(() => first.downloads.doneCount == 1);
    first.close();
    players.remove(first);

    final again = await Player.start(server, directory, repo: repo);
    players.add(again);
    expect(again.downloads.isTrackDownloaded('t1'), isTrue);
    final track = again.library.getTrack('t1')!;
    expect(again.downloads.stateOf(track), DownloadState.done, reason: 'the cached library still lists the track');
    await again.signIn();
    await settle();
    expect(server.streamRequests, hasLength(1));
  });

  test('a server ID never becomes a path: copies are named safely inside the downloads folder', () async {
    server.add(serverTrack('../../outside', 'Sneaky', 'Album'), audio(1));
    final player = await signedIn();
    final downloads = player.downloads;
    downloads.setTrackDownloaded('../../outside', true);
    await until(() => downloads.doneCount == 1);

    final copy = downloads.localCopy(player.library.getTrack('../../outside')!)!;
    expect(p.isWithin(downloads.directory, copy), isTrue);
    expect(p.basename(copy), '01 - Sneaky.flac');
    expect(p.relative(copy, from: downloads.directory), p.join('Artist', 'Album', '01 - Sneaky.flac'));
    expect(filesIn(downloads.directory).where((n) => !n.startsWith('covers')), [
      p.join('Artist', 'Album', '01 - Sneaky.flac'),
    ]);
    expect(File(p.join(p.dirname(directory), 'outside')).existsSync(), isFalse);
    expect(File(p.join(directory, 'outside')).existsSync(), isFalse);
  });

  test('downloads are stored in nested Artist/Album/Track folders', () async {
    server
      ..add(serverTrack('t1', 'Track 1', 'Album A', number: 1), audio(1))
      ..add(serverTrack('t2', 'Track 2', 'Album A', number: 2), audio(2));
    final player = await signedIn();
    final downloads = player.downloads;
    final album = player.library.albums.firstWhere((a) => a.title == 'Album A');

    downloads.setAlbumDownloaded(album.id, true);
    await until(() => downloads.doneCount == 2);

    final t1Copy = downloads.localCopy(album.tracks.first)!;
    final t2Copy = downloads.localCopy(album.tracks.last)!;

    expect(p.relative(t1Copy, from: downloads.directory), p.join('Artist', 'Album A', '01 - Track 1.flac'));
    expect(p.relative(t2Copy, from: downloads.directory), p.join('Artist', 'Album A', '02 - Track 2.flac'));
    expect(File(t1Copy).existsSync(), isTrue);
    expect(File(t2Copy).existsSync(), isTrue);
  });

  test('a name from the tags is one safe part of a path on every system', () {
    String safe(String name) => DownloadService.safeFileName(name, fallback: 'Track');
    expect(safe('AC/DC: Live?'), 'AC_DC_ Live_');
    expect(safe(r'..\..\etc'), r'_.._etc');
    expect(safe('...And Justice for All'), 'And Justice for All'); // not a hidden file
    expect(safe('Trailing. . '), 'Trailing');
    expect(safe('CON'), 'CON_');
    expect(safe('lpt1.flac'), 'lpt1.flac_');
    expect(safe('Console'), 'Console');
    expect(safe('  ..  '), 'Track');
    expect(safe('tab\there'), 'tab_here');
    final long = safe('x' * 300);
    expect(long.length, 80);
    final wide = DownloadService.safeFileName('🎵' * 100, fallback: 'Track', maxLength: 100);
    expect(utf8.encode(wide).length, lessThanOrEqualTo(200));
    expect(wide.runes.every((r) => r == '🎵'.runes.single), isTrue); // never half a character
  });

  test('a cover the server cannot give does not hold up the audio', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..coversFail = true;
    final player = await signedIn();
    player.downloads.setTrackDownloaded('t1', true);
    await until(() => player.downloads.doneCount == 1);
    expect(player.downloads.localCover(player.library.getTrack('t1')!.coverArtPath!), isNull);
    expect(player.downloads.errorMessage, isNull);
  });

  test('two tracks that would get one name get two files, each with its own audio', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..add(serverTrack('t2', 'Song', 'Album'), audio(2, 50001)); // the same album twice on the server, say
    final player = await signedIn();
    final downloads = player.downloads;
    downloads.setAlbumDownloaded(player.library.albums.single.id, true);
    await until(() => downloads.doneCount == 2);

    final first = downloads.localCopy(player.library.getTrack('t1')!)!;
    final second = downloads.localCopy(player.library.getTrack('t2')!)!;
    expect({p.basename(first), p.basename(second)}, {'01 - Song.flac', '01 - Song (2).flac'});
    expect(File(first).readAsBytesSync(), audio(1));
    expect(File(second).readAsBytesSync(), audio(2, 50001));

    // A restart finds each copy again, with nothing downloaded twice.
    final requests = server.streamRequests.length;
    final again = DownloadService(
      player.library,
      player.session,
      directory: downloads.directory,
      workDirectory: work(''),
      client: server.client,
    );
    addTearDown(again.dispose);
    await again.initialize();
    await settle();
    expect(again.localCopy(player.library.getTrack('t2')!), second);
    expect(server.streamRequests.length, requests);
  });

  test('copies are filed by album artist, and by disc on an album of several discs', () async {
    server
      ..add(serverTrack('d1', 'Intro', 'Live', disc: 1), audio(1))
      ..add(serverTrack('d2', 'Intro', 'Live', disc: 2), audio(2))
      ..add(
        TestSupport.makeServerTrack(
          'c1',
          'Duet',
          artist: 'Guest',
          album: 'Hits',
          albumArtist: 'Various Artists',
          trackNumber: 7,
        ),
        audio(3),
      );
    final player = await signedIn();
    final downloads = player.downloads;
    for (final album in player.library.albums) {
      downloads.setAlbumDownloaded(album.id, true);
    }
    await until(() => downloads.doneCount == 3);
    String place(String id) =>
        p.relative(downloads.localCopy(player.library.getTrack(id)!)!, from: downloads.directory);
    expect(place('d1'), p.join('Artist', 'Live', '1-01 - Intro.flac'));
    expect(place('d2'), p.join('Artist', 'Live', '2-01 - Intro.flac'));
    expect(place('c1'), p.join('Various Artists', 'Hits', '07 - Duet.flac'));
  });

  test('a copy whose record was lost is found at its place instead of downloaded again', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final repo = testRepository();
    final first = await signedIn(repo: repo);
    first.downloads.setTrackDownloaded('t1', true);
    await until(() => first.downloads.doneCount == 1);
    final copy = first.downloads.localCopy(first.library.getTrack('t1')!)!;
    first.close();
    players.remove(first);

    repo.deleteDownload('t1'); // the app's data was lost, the music folder was not
    final again = await signedIn(repo: repo);
    await until(() => again.downloads.doneCount == 1);
    expect(again.downloads.localCopy(again.library.getTrack('t1')!), copy);
    expect(server.streamRequests, hasLength(1));
  });

  test('a copy that was still being moved into place when the app stopped is fetched again', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final repo = testRepository();
    final first = await signedIn(repo: repo);
    first.downloads.setTrackDownloaded('t1', true);
    await until(() => first.downloads.doneCount == 1);
    final copy = first.downloads.localCopy(first.library.getTrack('t1')!)!;
    first.close();
    players.remove(first);

    // As the app leaves it when it ends in the middle of the move: half a file, recorded as moving.
    File(copy).writeAsBytesSync(audio(1).sublist(0, 1000));
    repo.saveDownload('t1', '', p.relative(copy, from: first.downloads.directory));
    final again = await signedIn(repo: repo);
    await until(() => again.downloads.doneCount == 1);
    expect(File(again.downloads.localCopy(again.library.getTrack('t1')!)!).readAsBytesSync(), audio(1));
    expect(server.streamRequests, hasLength(2));
    expect(again.downloads.bytesOnDisk, 50000 + pngBytes.length);
  });

  test('copies of an earlier version, named by hashes, move into place instead of being downloaded again', () async {
    final track = serverTrack('t1', 'Song', 'Album');
    server.add(track, audio(1));
    final repo = testRepository();
    final player = await signedIn(repo: repo);
    final version = stableId('${track.fileSizeBytes}\u001f${track.fileModifiedAt!.millisecondsSinceEpoch ~/ 1000}');
    final legacy = File(
      p.join(player.downloads.directory, '${stableId('track\u001ft1')}-${version.substring(0, 8)}-Song.flac'),
    )..createSync(recursive: true);
    legacy.writeAsBytesSync(audio(1));
    final stale = File(p.join(player.downloads.directory, '${'0' * 16}-${'1' * 8}.flac'))..writeAsBytesSync([1, 2]);
    player.close();
    players.remove(player);

    final again = await Player.start(server, directory, repo: repo);
    players.add(again);
    again.downloads.setTrackDownloaded('t1', true);
    await again.signIn();
    await until(() => again.downloads.doneCount == 1);
    expect(
      p.relative(again.downloads.localCopy(again.library.getTrack('t1')!)!, from: again.downloads.directory),
      p.join('Artist', 'Album', '01 - Song.flac'),
    );
    expect(server.streamRequests, isEmpty);
    expect((legacy.existsSync(), stale.existsSync()), (false, false));
    await until(() => again.downloads.localCover(again.library.getTrack('t1')!.coverArtPath!) != null);
    expect(again.downloads.bytesOnDisk, 50000 + pngBytes.length); // what was deleted on the way was never counted
  });

  test('with sync off, a mark downloads what it covers then, and nothing more comes on its own', () async {
    for (final (id, number) in [('t1', 1), ('t2', 2)]) {
      server.add(serverTrack(id, 'Song $id', 'Album', number: number), audio(number));
    }
    final now = DateTime.utc(2026);
    server.playlists.add(PlaylistData('p1', 'Road', null, ['t1'], now, now));
    final repo = testRepository();
    final player = await signedIn(repo: repo);
    final downloads = player.downloads;
    final library = player.library;
    downloads.setSyncModeEnabled(false);

    downloads.setPlaylistDownloaded('p1', true);
    await until(() => downloads.doneCount == 1);
    library.addTracksToPlaylist('p1', ['t2']);
    await settle();
    expect(downloads.stateOf(library.getTrack('t2')!), DownloadState.none);
    expect(server.streamRequests, hasLength(1));

    // Marking the track itself is asking for it.
    downloads.setTrackDownloaded('t2', true);
    await until(() => downloads.doneCount == 2);

    // A mark made without the server waits for it, across a restart.
    server.add(serverTrack('t3', 'Song t3', 'Album', number: 3), audio(3));
    await player.session.refreshLibrary();
    player.close();
    players.remove(player);
    final offline = await Player.start(server, directory, repo: repo);
    players.add(offline);
    offline.downloads.setTrackDownloaded('t3', true);
    offline.close();
    players.remove(offline);
    final later = await signedIn(repo: repo);
    expect(later.downloads.isTrackDownloaded('t3'), isTrue);
    await until(() => later.downloads.doneCount == 3);
  });

  test('when sync mode is disabled, manual deletions stay gone and are not auto-redownloaded', () async {
    server
      ..add(serverTrack('t1', 'Track 1', 'Album A', number: 1), audio(1))
      ..add(serverTrack('t2', 'Track 2', 'Album A', number: 2), audio(2));

    final repo = testRepository();
    final first = await signedIn(repo: repo);
    final albumId = first.library.albums.single.id;

    first.downloads.setSyncModeEnabled(false);
    first.downloads.setAlbumDownloaded(albumId, true);
    await until(() => first.downloads.doneCount == 2);
    expect(server.streamRequests, hasLength(2));

    first.close();
    players.remove(first);

    // Delete downloads folder manually
    final downloadsDir = Directory(p.join(directory, 'Downloads'));
    if (downloadsDir.existsSync()) downloadsDir.deleteSync(recursive: true);

    // Restart app
    final again = await Player.start(server, directory, repo: repo);
    players.add(again);
    await again.signIn();
    await settle();

    // In non-sync mode, nothing is redownloaded
    expect(server.streamRequests, hasLength(2));
    expect(again.downloads.doneCount, 0);
    expect(again.downloads.wantedCount, 0);
    expect(again.downloads.isAlbumDownloaded(albumId), isFalse);
  });
}
