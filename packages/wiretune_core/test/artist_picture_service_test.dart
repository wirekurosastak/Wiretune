// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  late Directory dir;
  late int requests;
  late ArtistPictureService service;

  setUpAll(useTempDataDirectory);
  setUp(() => dir = Directory.systemTemp.createTempSync('wiretune_artist_'));
  tearDown(() {
    service.close();
    dir.deleteSync(recursive: true);
  });

  // A service of its own per test, over a stand-in for Deezer: nothing reaches the real API.
  void useStub(http.Response Function(http.Request request) respond) {
    requests = 0;
    service = ArtistPictureService(
      client: MockClient((request) async {
        requests++;
        return respond(request);
      }),
      cacheFile: p.join(dir.path, 'artist_pictures.json'),
    );
  }

  http.Response json(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});

  test('null, blank and unknown artists have no picture', () async {
    useStub((_) => json('{}'));
    expect(await service.getArtistPictureUrl(null), isNull);
    expect(await service.getArtistPictureUrl('   '), isNull);
    expect(await service.getArtistPictureUrl('Unknown Artist'), isNull);
    expect(requests, 0);
  });

  test('a known artist gets a URL, cached for every spelling', () async {
    useStub((_) => json('{"data":[{"picture_medium":"https://cdn.example/queen.jpg"}]}'));
    expect(await service.getArtistPictureUrl('Queen'), 'https://cdn.example/queen.jpg');
    expect(await service.getArtistPictureUrl('  queen '), 'https://cdn.example/queen.jpg');
    expect(requests, 1);
  });

  test('an unknown artist is remembered, also after a restart, and not asked again', () async {
    useStub((_) => json('{"data":[]}'));
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(requests, 1);

    service.close(); // saves the answers
    useStub((_) => json('{"data":[]}'));
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(requests, 0);
  });

  test('server errors are neither cached nor retried at once', () async {
    useStub((_) => http.Response('', 503));
    expect(await service.getArtistPictureUrl('Queen'), isNull);
    expect(await service.getArtistPictureUrl('Abba'), isNull); // backing off
    expect(requests, 1);

    service.close();
    useStub((_) => json('{"data":[{"picture_medium":"https://cdn.example/queen.jpg"}]}'));
    // An outage was not "this artist has no picture": asked again once the service starts afresh.
    expect(await service.getArtistPictureUrl('Queen'), 'https://cdn.example/queen.jpg');
  });

  test('picture URLs that are not https are refused', () async {
    useStub(
      (_) => json('{"data":[{"picture_medium":"file:///etc/passwd","picture_big":"http://insecure.example/x.jpg"}]}'),
    );
    expect(await service.getArtistPictureUrl('Queen'), isNull);
  });

  test('resolving sets the picture of the artist', () async {
    useStub((_) => json('{"data":[{"picture_medium":"https://cdn.example/a.jpg"}]}'));
    final artist = Artist(name: 'Somebody', picturePath: '/covers/album.jpg');
    final resolved = <Artist>[];
    final unsubscribe = service.pictureResolved.listen(resolved.add);
    addTearDown(unsubscribe);

    service.resolveArtistPictures([artist]);
    for (var i = 0; i < 100 && resolved.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(artist.picturePath, 'https://cdn.example/a.jpg');

    service.resolveArtistPicture(null); // nothing to do, and no error
    service.resolveArtistPictures(const []);
  });

  test('a batch asks once per artist, and an artist that already has a picture is not asked', () async {
    useStub(
      (request) => json('{"data":[{"picture_medium":"https://cdn.example/${request.url.queryParameters['q']}.jpg"}]}'),
    );
    final artists = [
      for (final name in ['A', 'B', 'A']) Artist(name: name),
    ];
    final done = Artist(name: 'C', picturePath: 'https://cdn.example/C.jpg');
    final resolved = <Artist>[];
    final unsubscribe = service.pictureResolved.listen(resolved.add);
    addTearDown(unsubscribe);

    service.resolveArtistPictures([...artists, done]);
    service.resolveArtistPictures([artists.first]); // while the first batch runs: joins it
    for (var i = 0; i < 200 && resolved.length < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      [for (final a in artists) a.picturePath],
      [
        for (final n in ['A', 'B', 'A']) 'https://cdn.example/$n.jpg',
      ],
    );
    expect(requests, 2);
  });
}
