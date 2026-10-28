// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The session against a stand-in server: it comes back by itself, and a refresh downloads only what changed.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late LibraryService library;

  setUp(() {
    library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();
  });

  test('a server that went away is asked again by itself, quietly, and the session connects when it answers', () async {
    final saved = ServerSession.firstRetry;
    ServerSession.firstRetry = const Duration(milliseconds: 20);
    addTearDown(() => ServerSession.firstRetry = saved);
    var down = false;
    var asked = 0;
    final session = await signedInSession(
      library,
      respond: (request) {
        if (!down) return null;
        asked++;
        throw const SocketException('Connection refused');
      },
    );
    addTearDown(session.dispose);

    down = true;
    await session.refreshLibrary();
    expect(session.state, ServerConnectionState.offline);
    final states = <ServerConnectionState>[];
    session.stateChanged.listen((_) => states.add(session.state));

    await until(() => asked >= 3);
    expect(states, isEmpty, reason: 'asking does not say "connecting" each time');

    down = false;
    await until(() => session.state == ServerConnectionState.connected);
  });

  test('offline mode leaves the server alone, and says nothing of it, until it is turned off', () async {
    final saved = ServerSession.firstRetry;
    ServerSession.firstRetry = const Duration(milliseconds: 20);
    addTearDown(() => ServerSession.firstRetry = saved);
    var asked = 0;
    final session = await signedInSession(
      library,
      respond: (_) {
        asked++;
        return null;
      },
    );
    addTearDown(session.dispose);

    await session.setOfflineMode(true);
    expect((session.state, session.statusMessage), (ServerConnectionState.offline, null));
    expect(library.serverConnected, isFalse, reason: "the account's data isn't changed meanwhile");
    asked = 0;
    await session.connect();
    await session.resume();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(asked, 0, reason: 'neither connecting nor asking now and then whether the server is back');

    await session.setOfflineMode(false);
    expect(session.state, ServerConnectionState.connected);
  });

  test('offline mode lasts across a restart, and connecting to a server ends it', () async {
    (await signedInSession(library, tracks: [TestSupport.makeTrack('t1', 'One')])).dispose();
    final settings = testRepository();
    var asked = 0;
    ServerSession start() {
      final client = MockClient((request) async {
        asked++;
        return http.Response(jsonEncode({'setupRequired': false}), 200, headers: {'content-type': 'application/json'});
      });
      final session = ServerSession(library, settings, ServerClient(client))..initialize();
      addTearDown(session.dispose);
      return session;
    }

    await start().setOfflineMode(true);
    final restarted = start();
    expect(restarted.isOfflineMode, isTrue);
    await restarted.connect();
    expect(asked, 0);

    await restarted.connect('http://server:5200');
    expect(restarted.isOfflineMode, isFalse);
    expect(restarted.state, ServerConnectionState.loginRequired);
    expect(start().isOfflineMode, isFalse);
  });

  test("the server's artists' own pictures take the place of their album covers, also after a restart", () async {
    final id = stableId('miles davis');
    var pictures = {id: 'v1'};
    final session = await signedInSession(
      library,
      tracks: [TestSupport.makeTrack('t1', 'So What', artist: 'Miles Davis')],
      respond: (request) => request.url.path != '/api/artists/pictures'
          ? null
          : http.Response(jsonEncode(pictures), 200, headers: {'content-type': 'application/json'}),
    );
    addTearDown(session.dispose);
    Artist miles(LibraryService library) => library.artists.single;
    expect(miles(library).picturePath, 'http://server:5200/api/cover/artist/$id?v=v1');
    expect(miles(library).hasOwnPicture, isTrue);

    final restarted = LibraryService(library.repository, MetadataScanner(), coverCacheDirectory: '/nonexistent')
      ..initialize();
    expect(miles(restarted).picturePath, 'http://server:5200/api/cover/artist/$id?v=v1');

    pictures = {};
    await session.refreshLibrary();
    expect(miles(library).hasOwnPicture, isFalse);
  });

  test('a refresh downloads the track list and the account data only when they changed', () async {
    var tracks = [TestSupport.makeTrack('t1', 'One')];
    var tracksVersion = 1;
    final downloaded = <String>[];
    final session = await signedInSession(
      library,
      respond: (request) {
        final (etag, body) = switch (request.url.path) {
          '/api/tracks' => ('"tracks-$tracksVersion"', [for (final t in tracks) t.toJson()]),
          '/api/me/data' => ('"data"', const UserDataSnapshot([], [], []).toJson()),
          _ => (null, null),
        };
        if (etag == null) return null;
        if (request.headers['If-None-Match'] == etag) return http.Response('', 304, headers: {'etag': etag});
        downloaded.add(request.url.path);
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json', 'etag': etag});
      },
    );
    addTearDown(session.dispose);
    expect(downloaded, ['/api/tracks', '/api/me/data']);
    var rebuilt = 0;
    library.libraryChanged.listen((_) => rebuilt++);

    await session.refreshLibrary();
    expect(downloaded, hasLength(2));
    expect(rebuilt, 0, reason: 'nothing changed, so nothing is merged again');

    tracks = [...tracks, TestSupport.makeTrack('t2', 'Two')];
    tracksVersion++;
    await session.refreshLibrary();
    expect(downloaded.last, '/api/tracks');
    expect(library.tracks.map((t) => t.id), unorderedEquals(['t1', 't2']));
    expect(rebuilt, greaterThan(0));
    expect(session.state, ServerConnectionState.connected);

    // A change made here means the data shown is no longer the data downloaded: it is downloaded again.
    library.toggleFavorite('t1');
    await session.flushUserData();
    await session.refreshLibrary();
    expect(downloaded.last, '/api/me/data');
  });

  http.Response refusal(int status, String error) =>
      http.Response(jsonEncode({'error': error}), status, headers: {'content-type': 'application/json'});

  test('a server that refuses a change can be reached, so the session stays connected', () async {
    final requests = <String>[];
    final session = await signedInSession(
      library,
      respond: (request) {
        requests.add('${request.method} ${request.url.path}');
        return request.url.path.startsWith('/api/me/playlists/')
            ? refusal(409, 'An account can have at most 500 playlists.')
            : null;
      },
    );
    addTearDown(session.dispose);

    library.createPlaylist('One too many');
    await session.flushUserData();
    expect(requests.where((r) => r.startsWith('PUT /api/me/playlists/')), hasLength(1)); // sent, and refused
    expect(session.state, ServerConnectionState.connected);
    expect(library.serverConnected, isTrue);
  });

  test('a favourite the server refuses is shown as what it really is', () async {
    final requests = <String>[];
    final session = await signedInSession(
      library,
      tracks: [TestSupport.makeTrack('s1', 'Server song')],
      respond: (request) {
        requests.add('${request.method} ${request.url.path}');
        return request.url.path == '/api/me/favorites/s1' ? refusal(500, 'Database is locked.') : null;
      },
    );
    addTearDown(session.dispose);
    expect(library.serverConnected, isTrue);

    library.toggleFavorite('s1');
    await session.flushUserData();
    expect(requests, contains('PUT /api/me/favorites/s1'));
    expect(library.isFavorite('s1'), isFalse);
  });

  test('a connection cut in the middle of the library download is reported', () async {
    final user = UserInfo('u1', 'owner', true, DateTime.now().toUtc(), null);
    final client = MockClient.streaming((request, _) async {
      if (request.url.path == '/api/auth/setup-required') {
        return http.StreamedResponse(Stream.value(utf8.encode('{"setupRequired":false}')), 200);
      }
      if (request.url.path == '/api/auth/me') {
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(user.toJson()))), 200);
      }
      return http.StreamedResponse(Stream<List<int>>.error(const SocketException('Connection reset by peer')), 200);
    });
    final repo = testRepository()
      ..setSetting('server_url', 'http://wiretune.test')
      ..setSetting('auth_token', 'stored');
    final cut = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent')..initialize();
    final session = ServerSession(cut, repo, ServerClient(client));
    addTearDown(session.dispose);
    session.initialize();
    expect(session.state, ServerConnectionState.offline); // a stored server source starts offline
    await session.connect();
    expect(session.state, ServerConnectionState.offline);
    expect(session.statusMessage, contains('connection was lost'));
  });

  test('while the server cannot be reached its tracks cannot be changed, but local ones can', () async {
    final repo = testRepository()
      ..replaceAllTracks([TestSupport.makeServerTrack('s1', 'Server song'), TestSupport.makeTrack('l1', 'Local song')]);
    final offline = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent')..initialize();
    final session = ServerSession(
      offline,
      repo,
      ServerClient(MockClient((_) => throw StateError('no request expected'))),
    );
    addTearDown(session.dispose);
    session.initialize();
    expect(offline.serverConnected, isFalse);

    offline.toggleFavorite('s1');
    offline.recordPlay('s1');
    expect(offline.isFavorite('s1'), isFalse);
    expect(offline.playCount('s1'), 0);

    offline.toggleFavorite('l1');
    expect(offline.isFavorite('l1'), isTrue);
  });
}
