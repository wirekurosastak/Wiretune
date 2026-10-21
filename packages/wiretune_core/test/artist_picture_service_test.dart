// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
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
      spacing: Duration.zero,
    );
  }

  http.Response json(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});

  // Deezer's artist search answering with [artists] (name, fans, picture); its album search with [albums] (the
  // artist's name and picture of each).
  void useDeezer({List<(String, int, String)> artists = const [], List<(String, String)> albums = const []}) =>
      useStub((request) {
        final kind = request.url.pathSegments.last;
        return json(
          jsonEncode({
            'data': kind == 'album'
                ? [
                    for (final (name, picture) in albums)
                      {
                        'title': 'An album',
                        'artist': {'name': name, 'picture_medium': picture},
                      },
                  ]
                : [
                    for (final (name, fans, picture) in artists)
                      {'name': name, 'nb_fan': fans, 'picture_medium': picture},
                  ],
          }),
        );
      });

  test('null, blank and unknown artists have no picture', () async {
    useStub((_) => json('{}'));
    expect(await service.getArtistPictureUrl(null), isNull);
    expect(await service.getArtistPictureUrl('   '), isNull);
    expect(await service.getArtistPictureUrl('Unknown Artist'), isNull);
    expect(requests, 0);
  });

  test('a known artist gets a URL, cached for every spelling', () async {
    useDeezer(artists: [('Queen', 100, 'https://cdn.example/queen.jpg')]);
    expect(await service.getArtistPictureUrl('Queen'), 'https://cdn.example/queen.jpg');
    expect(await service.getArtistPictureUrl('  queen '), 'https://cdn.example/queen.jpg');
    expect(requests, 1);
  });

  test('by name alone, only that exact name counts, and the best known of those who have it', () async {
    useDeezer(
      artists: [
        ('SZA', 1339100, 'https://cdn.example/sza.jpg'),
        ('Aza', 5, 'https://cdn.example/aza-5.jpg'),
        ('AZA', 25, 'https://cdn.example/aza-25.jpg'),
      ],
    );
    expect(await service.getArtistPictureUrl('aza'), 'https://cdn.example/aza-25.jpg');
    useDeezer(artists: [('Coldplay', 18427271, 'https://cdn.example/coldplay.jpg')]);
    expect(await service.getArtistPictureUrl('Co Lee'), isNull, reason: 'not another name');
  });

  test('an album of theirs tells which of the artists with the name they are', () async {
    useDeezer(
      artists: [('AZA', 25, 'https://cdn.example/aza-25.jpg')],
      albums: [('Someone Else', 'https://cdn.example/other.jpg'), ('Aza', 'https://cdn.example/aza-2.jpg')],
    );
    expect(
      await service.getArtistPictureUrl('aza', albums: ['#SzuperCsillagParaszt']),
      'https://cdn.example/aza-2.jpg',
    );
    expect(requests, 1);

    // No album of theirs found: their name, then.
    useDeezer(artists: [('AZA', 25, 'https://cdn.example/aza-25.jpg')]);
    expect(await service.getArtistPictureUrl('aza', albums: ['One', 'Two', 'Three']), 'https://cdn.example/aza-25.jpg');
    expect(requests, 3, reason: 'two albums, then the name');
  });

  test("an album's second act is found among its contributors, not by their name", () async {
    useStub((request) {
      if (request.url.path == '/album/637590871') {
        return json(
          jsonEncode({
            'contributors': [
              {'name': 'Co Lee', 'picture_medium': 'https://cdn.example/co-lee.jpg'},
              {'name': 'Blaize', 'picture_medium': 'https://cdn.example/blaize-65.jpg'},
            ],
          }),
        );
      }
      return json(
        jsonEncode({
          'data': request.url.path == '/search/album'
              ? [
                  {
                    'id': 637590871,
                    'title': 'LA PROMENADE',
                    'artist': {'name': 'Co Lee', 'picture_medium': 'https://cdn.example/co-lee.jpg'},
                  },
                ]
              : [
                  {'name': 'Blaize', 'nb_fan': 216, 'picture_medium': 'https://cdn.example/blaize-216.jpg'},
                ],
        }),
      );
    });
    expect(await service.getArtistPictureUrl('Blaize', albums: ['LA PROMENADE']), 'https://cdn.example/blaize-65.jpg');
    expect(requests, 2);
  });

  test("Deezer's grey stand-in is no picture, and neither is an address that is not https", () async {
    useDeezer(artists: [('Ketioz', 9, 'https://cdn-images.dzcdn.net/images/artist//250x250-000000-80-0-0.jpg')]);
    expect(await service.getArtistPictureUrl('Ketioz'), isNull);
    useStub(
      (_) => json(
        '{"data":[{"name":"Queen","picture_medium":"file:///etc/passwd","picture_big":"http://insecure.example/x.jpg"}]}',
      ),
    );
    expect(await service.getArtistPictureUrl('Queen'), isNull);
  });

  test('an unknown artist is remembered, also after a restart, and not asked again', () async {
    useDeezer();
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(requests, 1);

    service.close(); // saves the answers
    useDeezer();
    expect(await service.getArtistPictureUrl('Nobody'), isNull);
    expect(requests, 0);
  });

  test("an earlier lookup's answers are asked again: it took the wrong one of the artists with a name", () async {
    File(
      p.join(dir.path, 'artist_pictures.json'),
    ).writeAsStringSync('{"version": 2, "artists": {"aza": "https://cdn.example/wrong.jpg"}}');
    useDeezer(artists: [('Aza', 5, 'https://cdn.example/aza.jpg')]);
    expect(await service.getArtistPictureUrl('aza'), 'https://cdn.example/aza.jpg');
  });

  for (final (what, answer) in [
    ('server errors', http.Response('', 503)),
    ('too many requests (an error sent with 200 OK)', http.Response('{"error":{"code":4,"message":"Quota"}}', 200)),
  ]) {
    test('$what are neither cached nor retried at once', () async {
      useStub((_) => answer);
      expect(await service.getArtistPictureUrl('Queen'), isNull);
      expect(await service.getArtistPictureUrl('Abba'), isNull); // backing off
      expect(requests, 1);

      service.close();
      useDeezer(artists: [('Queen', 100, 'https://cdn.example/queen.jpg')]);
      // An outage was not "this artist has no picture": asked again once the service starts afresh.
      expect(await service.getArtistPictureUrl('Queen'), 'https://cdn.example/queen.jpg');
    });
  }

  Future<void> resolving(List<Artist> resolved, int count) async {
    for (var i = 0; i < 200 && resolved.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test("resolving sets the artist's picture, also over a server's album cover", () async {
    useDeezer(artists: [('Somebody', 1, 'https://cdn.example/a.jpg'), ('Co Lee', 1, 'https://cdn.example/b.jpg')]);
    final local = Artist(name: 'Somebody', picturePath: '/covers/album.jpg');
    final served = Artist(name: 'Co Lee', picturePath: 'https://music.example/api/cover/album/5f35fa6701f60a0e?v=8');
    final resolved = <Artist>[];
    final unsubscribe = service.pictureResolved.listen(resolved.add);
    addTearDown(unsubscribe);

    service.resolveArtistPictures([local, served]);
    await resolving(resolved, 2);
    expect([local.picturePath, served.picturePath], ['https://cdn.example/a.jpg', 'https://cdn.example/b.jpg']);

    service.resolveArtistPicture(null); // nothing to do, and no error
    service.resolveArtistPictures(const []);
  });

  test('an artist with a picture of their own is never looked up', () async {
    useDeezer(artists: [('Valter', 1, 'https://cdn.example/someone-else.jpg')]);
    final artist = Artist(name: 'Valter', picturePath: '/music/Valter/artist.jpg', hasOwnPicture: true);
    service.resolveArtistPictures([artist]);
    service.resolveArtistPicture(artist);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((artist.picturePath, requests), ('/music/Valter/artist.jpg', 0));
  });

  test('a batch asks once per artist, and an artist that already shows its picture is not asked', () async {
    useStub(
      (request) => json(
        jsonEncode({
          'data': [
            {
              'name': request.url.queryParameters['q'],
              'picture_medium': 'https://cdn.example/${request.url.queryParameters['q']}.jpg',
            },
          ],
        }),
      ),
    );
    final artists = [
      for (final name in ['A', 'B', 'A']) Artist(name: name),
    ];
    final resolved = <Artist>[];
    final unsubscribe = service.pictureResolved.listen(resolved.add);
    addTearDown(unsubscribe);

    service.resolveArtistPictures(artists);
    service.resolveArtistPictures([artists.first]); // while the first batch runs: joins it
    await resolving(resolved, 3);
    expect(
      [for (final a in artists) a.picturePath],
      [
        for (final n in ['A', 'B', 'A']) 'https://cdn.example/$n.jpg',
      ],
    );
    expect(requests, 2);

    // The library built again: the same artist shows an album cover until its known picture is set, without a request.
    final again = Artist(name: 'B', picturePath: '/covers/b.jpg');
    service.resolveArtistPictures([again, artists[1]]);
    await resolving(resolved, 4);
    expect((again.picturePath, requests, resolved.length), ('https://cdn.example/B.jpg', 2, 4));
  });
}
