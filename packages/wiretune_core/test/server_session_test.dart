// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

Future<bool> until(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

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

    expect(await until(() => asked >= 3), isTrue);
    expect(states, isEmpty, reason: 'asking does not say "connecting" each time');

    down = false;
    expect(await until(() => session.state == ServerConnectionState.connected), isTrue);
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
}
