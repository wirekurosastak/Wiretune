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

  void add(Track track, List<int> bytes) {
    track
      ..fileSizeBytes = bytes.length
      ..fileModifiedUtc ??= DateTime.utc(2026, 1, 1);
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

  static Future<Player> start(FakeServer server, String directory, {MockRepository? repo}) async {
    repo ??= MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(directory, 'covers-cache'));
    final session = ServerSession(library, repo, ServerStreamingClient(server.client));
    final downloads = DownloadService(
      library,
      session,
      directory: p.join(directory, 'Downloads'),
      client: server.client,
    );
    await library.initialize();
    await session.initialize();
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

  Future<Player> signedIn({MockRepository? repo}) async {
    final player = await Player.start(server, directory, repo: repo);
    players.add(player);
    await player.signIn();
    return player;
  }

  Track serverTrack(String id, String title, String album, {int number = 1}) =>
      TestSupport.makeServerTrack(id, title, album: album)
        ..trackNumber = number
        ..hasCoverArt = true;

  List<String> filesIn(String folder) => Directory(folder).existsSync()
      ? [for (final f in Directory(folder).listSync().whereType<File>()) p.basename(f.path)]
      : [];

  test('an album is downloaded with its cover, and then plays from the copies without the server', () async {
    server
      ..add(serverTrack('a1', 'One', 'Album A'), audio(1))
      ..add(serverTrack('a2', 'Two', 'Album A', number: 2), audio(2))
      ..add(serverTrack('b1', 'Other', 'Album B'), audio(3));
    final player = await signedIn();
    final downloads = player.downloads;
    final album = player.library.albums.firstWhere((a) => a.title == 'Album A');

    await downloads.pinAlbum(album.id, true);
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

    await downloads.pinPlaylist('p1', true);
    await until(() => downloads.stateOf(track('t1')) == DownloadState.done);

    // The playlist grows: the new track follows; it shrinks: the copy goes.
    await library.addTrackToPlaylist('p1', 't2');
    await until(() => downloads.stateOf(track('t2')) == DownloadState.done);
    final t1Copy = downloads.localCopy(track('t1'))!;
    await library.removeTrackFromPlaylist('p1', 't1');
    await until(() => !File(t1Copy).existsSync());
    expect(downloads.localCopy(track('t1')), isNull);

    // The favourites, likewise.
    await downloads.pinFavorites(true);
    await library.toggleFavorite('t3');
    await until(() => downloads.stateOf(track('t3')) == DownloadState.done);
    final t3Copy = downloads.localCopy(track('t3'))!;
    await library.toggleFavorite('t3');
    await until(() => !File(t3Copy).existsSync());

    // A single track that is also in the playlist keeps its copy when the playlist is unmarked.
    await downloads.pinTrack('t2', true);
    await downloads.pinPlaylist('p1', false);
    await settle();
    expect(downloads.stateOf(track('t2')), DownloadState.done);

    await downloads.removeAll();
    await until(() => filesIn(downloads.directory).isEmpty);
    expect(filesIn(p.join(downloads.directory, 'covers')), isEmpty);
    expect(downloads.bytesOnDisk, 0);
    expect((downloads.isTrackPinned('t2'), downloads.areFavoritesPinned), (false, false));
  });

  test('a copy follows the server file: a changed file is fetched again and then replaces the old copy', () async {
    server.add(serverTrack('t1', 'Song', 'Album'), audio(1));
    final player = await signedIn();
    final downloads = player.downloads;
    await downloads.pinTrack('t1', true);
    await until(() => downloads.doneCount == 1);
    final first = downloads.localCopy(player.library.getTrack('t1')!)!;

    // Retagged on the server: same track, other bytes and modification time.
    server.tracks.clear();
    server.add(serverTrack('t1', 'Song', 'Album')..fileModifiedUtc = DateTime.utc(2026, 2, 1), audio(9, 50100));
    final requestsBefore = server.streamRequests.length;
    await player.session.refreshLibrary();
    final track = player.library.getTrack('t1')!;
    await until(() => downloads.stateOf(track) == DownloadState.done);

    final second = downloads.localCopy(track)!;
    expect(second, isNot(first));
    expect(File(second).readAsBytesSync(), audio(9, 50100));
    expect(File(first).existsSync(), isFalse);
    expect(server.streamRequests.length, requestsBefore + 1);
    expect(filesIn(downloads.directory).where((n) => !n.startsWith('covers')), hasLength(1));
  });

  test('an interrupted download continues where it stopped', () async {
    server
      ..add(serverTrack('t1', 'Song', 'Album'), audio(1))
      ..cutAfter = 20000;
    final player = await signedIn();
    final downloads = player.downloads;
    await downloads.pinTrack('t1', true);
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
    await downloads.pinAlbum(library.albums.single.id, true);
    await until(() => downloads.doneCount == 1);
    await downloads.pinTrack('t1', true); // another change: another pass over the wanted tracks
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
    final repo = MockRepository();
    (await signedIn(repo: repo)).close();
    players.clear();

    // A restart without the server: the cached library still lists the track.
    final player = await Player.start(server, directory, repo: repo);
    players.add(player);
    expect(player.session.isLoggedIn, isFalse);
    await player.downloads.pinTrack('t1', true);
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
    final repo = MockRepository();
    final first = await signedIn(repo: repo);
    await first.downloads.pinTrack('t1', true);
    await until(() => first.downloads.doneCount == 1);
    first.close();
    players.remove(first);

    final again = await Player.start(server, directory, repo: repo);
    players.add(again);
    expect(again.downloads.isTrackPinned('t1'), isTrue);
    final track = again.library.getTrack('t1')!;
    expect(again.downloads.stateOf(track), DownloadState.done, reason: 'the cached library still lists the track');
    await again.signIn();
    await settle();
    expect(server.streamRequests, hasLength(1));
  });

  test('a server ID never becomes a path: copies are named by hashes, inside the downloads folder', () async {
    server.add(serverTrack('../../outside', 'Sneaky', 'Album'), audio(1));
    final player = await signedIn();
    final downloads = player.downloads;
    await downloads.pinTrack('../../outside', true);
    await until(() => downloads.doneCount == 1);

    final copy = downloads.localCopy(player.library.getTrack('../../outside')!)!;
    expect(p.isWithin(downloads.directory, copy), isTrue);
    expect(p.basename(copy), matches(RegExp(r'^[0-9a-f]{16}-[0-9a-f]{8}\.flac$')));
    expect(filesIn(downloads.directory), [p.basename(copy)]);
    expect(filesIn(directory), isEmpty);
    expect(filesIn(p.dirname(directory)).where((name) => name.contains('outside')), isEmpty);
  });
}
