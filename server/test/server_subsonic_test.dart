// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The Subsonic API under /rest, as the apps that speak it call it.
void main() {
  late ServerFixture server;
  late Api admin;
  late String appPassword;
  late List<Map<String, dynamic>> tracks;

  setUp(() async {
    server = await ServerFixture.start();
    (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);
    // The files the fixture makes carry no tags; these do. Alice has one album of two songs, Bob one of one.
    void tagged(String artist, String album, int number, String title, String genre, double seconds) => writeWav(
      p.join(server.musicFolder, artist, album, '0$number $title.wav'),
      44100,
      seconds: seconds,
      artist: artist,
      title: title,
      album: album,
      genre: genre,
      trackNumber: number,
    );
    tagged('Alice', 'First Light', 1, 'Dawn', 'Rock', 2);
    tagged('Alice', 'First Light', 2, 'Noon', 'Rock', 3);
    tagged('Bob', 'Night Songs', 1, 'Dusk', 'Jazz', 4);
    await admin.post('/api/library/scan');
    tracks = await server.waitForTracks(admin, 6);
    appPassword = json(await admin.post('/api/me/app-password'))['password'] as String;
  });
  tearDown(() => server.close());

  /// A call as an app makes it: the app password as a token with a salt, the way current apps sign in.
  Future<http.Response> call(
    String method, {
    Map<String, Object> params = const {},
    String format = 'json',
    String user = 'owner',
    String? password,
  }) {
    const salt = 'c19b2d';
    final query = <String, Object>{
      'u': user,
      't': md5.convert(utf8.encode('${password ?? appPassword}$salt')).toString(),
      's': salt,
      'v': '1.16.1',
      'c': 'test',
      'f': format,
      ...params,
    };
    final encoded = query.entries
        .expand((e) => e.value is List ? (e.value as List).map((v) => MapEntry(e.key, v)) : [MapEntry(e.key, e.value)])
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent('${e.value}')}')
        .join('&');
    return http.get(Uri.parse('${server.baseUrl}/rest/$method.view?$encoded'));
  }

  Future<Map<String, dynamic>> answer(String method, {Map<String, Object> params = const {}}) async {
    final response = await call(method, params: params);
    expect(response.statusCode, 200);
    final body = json(response)['subsonic-response'] as Map<String, dynamic>;
    expect(body['status'], 'ok', reason: '$method: ${body['error']}');
    return body;
  }

  Future<Map<String, dynamic>> failure(String method, {Map<String, Object> params = const {}}) async {
    final body = json(await call(method, params: params))['subsonic-response'] as Map<String, dynamic>;
    expect(body['status'], 'failed');
    return body['error'] as Map<String, dynamic>;
  }

  Future<UserDataSnapshot> data() async => UserDataSnapshot.fromJson(json(await admin.get('/api/me/data')));

  String idOf(String title) => tracks.firstWhere((t) => t['title'] == title)['id'] as String;

  group('signing in', () {
    test('works with the app password as a token, as the password, as hex, and as an API key', () async {
      expect((await answer('ping'))['openSubsonic'], isTrue);

      Future<Map<String, dynamic>> plain(Map<String, String> params) async {
        final response = await http.get(
          Uri.parse('${server.baseUrl}/rest/ping?f=json&${Uri(queryParameters: params).query}'),
        );
        return json(response)['subsonic-response'] as Map<String, dynamic>;
      }

      expect((await plain({'u': 'owner', 'p': appPassword}))['status'], 'ok');
      final hex = utf8.encode(appPassword).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect((await plain({'u': 'OWNER', 'p': 'enc:$hex'}))['status'], 'ok'); // the name ignores case
      expect((await plain({'apiKey': appPassword}))['status'], 'ok');
    });

    test('refuses what is missing, wrong or conflicting, with the codes Subsonic apps know', () async {
      Future<Map<String, dynamic>> error(String query) async {
        final response = await http.get(Uri.parse('${server.baseUrl}/rest/ping?f=json&$query'));
        expect(response.statusCode, 200);
        return (json(response)['subsonic-response'] as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      }

      expect((await error(''))['code'], 10);
      expect((await error('u=owner'))['code'], 10);
      expect((await error('u=owner&p=wrong'))['code'], 40);
      expect((await error('u=nobody&p=$appPassword'))['code'], 40);
      expect((await error('apiKey=wrong'))['code'], 44);
      expect((await error('apiKey=$appPassword&u=owner&p=$appPassword'))['code'], 43);
      // The account's own password opens the Wiretune API and nothing here: an app that keeps it can't change the account.
      expect((await error('u=owner&p=${Uri.encodeQueryComponent(adminPassword)}'))['code'], 40);
    });

    test('ends when the app password is made again, removed, or the password reset', () async {
      expect((await answer('ping'))['status'], 'ok');
      final old = appPassword;
      appPassword = json(await admin.post('/api/me/app-password'))['password'] as String;
      expect(appPassword, isNot(old));
      expect((json(await call('ping', password: old))['subsonic-response'] as Map)['status'], 'failed');
      expect((await answer('ping'))['status'], 'ok');

      expect((await admin.delete('/api/me/app-password')).statusCode, 200);
      expect(json(await admin.get('/api/me/app-password')), {'exists': false});
      expect((json(await call('ping'))['subsonic-response'] as Map)['status'], 'failed');
    });

    test("ends when an administrator resets the account's password, or the account changes it", () async {
      final (guest, user) = await registerGuest(server, admin);
      var secret = json(await guest.post('/api/me/app-password'))['password'] as String;
      Future<String> status() async =>
          (json(await call('ping', user: 'guest', password: secret))['subsonic-response'] as Map)['status'] as String;
      expect(await status(), 'ok');

      expect((await admin.post('/api/users/${user.id}/password', {'newPassword': 'a-new-password-1'})).statusCode, 200);
      expect(await status(), 'failed');

      final (again, _) = await login(server, 'guest', 'a-new-password-1');
      secret = json(await again.post('/api/me/app-password'))['password'] as String;
      expect(await status(), 'ok');
      expect((await again.post('/api/auth/change-password', {'newPassword': 'another-password-2'})).statusCode, 200);
      expect(await status(), 'failed');
    });

    test('is answered in XML unless the app asks for JSON', () async {
      final response = await call('ping', format: 'xml');
      expect(response.headers['content-type'], startsWith('text/xml'));
      expect(response.body, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(response.body, contains('<subsonic-response xmlns="http://subsonic.org/restapi" status="ok"'));
      expect(response.body, endsWith('/>'));

      final failed = await http.get(Uri.parse('${server.baseUrl}/rest/ping'));
      expect(failed.body, contains('status="failed"'));
      expect(failed.body, contains('<error code="10" message="Required parameter is missing: u."/>'));
    });
  });

  group('browsing', () {
    test('lists artists in an index, an artist with its albums, and an album with its songs', () async {
      final artists = (await answer('getArtists'))['artists'] as Map<String, dynamic>;
      expect([for (final group in artists['index'] as List) group['name']], ['A', 'B', 'U']); // Unknown artist: U
      final entries = [for (final group in artists['index'] as List) ...(group['artist'] as List)];
      expect(entries.map((a) => a['name']), ['Alice', 'Bob', 'Unknown artist']);
      final alice = entries.first as Map<String, dynamic>;

      final detail =
          (await answer('getArtist', params: {'id': alice['id'] as String}))['artist'] as Map<String, dynamic>;
      expect(detail['albumCount'], 1);
      final album = (detail['album'] as List).single as Map<String, dynamic>;
      expect(album['name'], 'First Light');
      expect((album['songCount'], album['duration'], album['genre'], album['artistId']), (2, 5, 'Rock', alice['id']));

      final songs = ((await answer('getAlbum', params: {'id': album['id'] as String}))['album'] as Map)['song'] as List;
      expect(songs.map((s) => s['title']), ['Dawn', 'Noon']);
      final dawn = songs.first as Map<String, dynamic>;
      expect(dawn['albumId'], album['id']);
      expect(dawn['artistId'], alice['id']);
      expect(dawn['track'], 1);
      expect(dawn['genre'], 'Rock');
      expect(dawn['suffix'], 'wav');
      expect(dawn['contentType'], isNotEmpty);
      expect(dawn['duration'], 2);
      expect(dawn['path'], 'Alice/First Light/01 Dawn.wav');
      expect(dawn['samplingRate'], 44100);
      expect(dawn['isDir'], isFalse);
      expect(dawn.containsKey('coverArt'), isFalse); // null is left out

      final single = (await answer('getSong', params: {'id': dawn['id'] as String}))['song'] as Map<String, dynamic>;
      expect(single['title'], 'Dawn');
      expect((await failure('getSong', params: {'id': 'nonsense'}))['code'], 70);
      expect((await failure('getAlbum', params: {'id': 'nonsense'}))['code'], 70);

      final directory = (await answer('getMusicDirectory', params: {'id': alice['id'] as String}))['directory'] as Map;
      expect((directory['child'] as List).single['title'], 'First Light');
    });

    test('lists albums by a type, with a size and an offset', () async {
      Future<List<String>> names(Map<String, Object> params) async {
        final list = (await answer('getAlbumList2', params: params))['albumList2'] as Map<String, dynamic>;
        return [for (final a in list['album'] as List) a['name'] as String];
      }

      expect(await names({'type': 'alphabeticalByName'}), ['First Light', 'Night Songs', 'Unknown album']);
      expect(await names({'type': 'alphabeticalByArtist'}), ['First Light', 'Night Songs', 'Unknown album']);
      expect(await names({'type': 'alphabeticalByName', 'size': 1, 'offset': 1}), ['Night Songs']);
      expect(
        await names({'type': 'random', 'size': 5}),
        unorderedEquals(['First Light', 'Night Songs', 'Unknown album']),
      );
      expect(await names({'type': 'random', 'size': 2}), hasLength(2));
      expect(await names({'type': 'newest'}), hasLength(3));
      expect(await names({'type': 'byGenre', 'genre': 'jazz'}), ['Night Songs']);
      expect(await names({'type': 'frequent'}), isEmpty);
      expect(await names({'type': 'starred'}), isEmpty);
      expect(await names({'type': 'highest'}), isEmpty);
      expect((await failure('getAlbumList2', params: {'type': 'bogus'}))['code'], 0);
      expect((await failure('getAlbumList2'))['code'], 10);
    });

    test('searches, and gives everything for an empty query, a page at a time', () async {
      Future<Map<String, dynamic>> search(Map<String, Object> params) async =>
          (await answer('search3', params: params))['searchResult3'] as Map<String, dynamic>;

      expect(
        [
          for (final s in (await search({'query': 'dusk'}))['song'] as List) s['title'],
        ],
        ['Dusk'],
      );
      expect(
        [
          for (final s in (await search({'query': 'bob dusk'}))['song'] as List) s['title'],
        ],
        ['Dusk'],
      );
      expect((await search({'query': 'BOB'}))['artist'], hasLength(1));
      expect((await search({'query': 'night'}))['album'], hasLength(1));
      expect((await search({'query': '"'}))['song'], hasLength(6));
      expect((await search({'query': '', 'songCount': 4}))['song'], hasLength(4));
      expect((await search({'query': '', 'songCount': 4, 'songOffset': 4}))['song'], hasLength(2));
      expect((await search({'query': 'nothing like it'}))['song'], isEmpty);
    });

    test('has the folders, genres, random songs and the user, and an empty answer for what Wiretune lacks', () async {
      expect(((await answer('getMusicFolders'))['musicFolders'] as Map)['musicFolder'], hasLength(1));
      final genres = ((await answer('getGenres'))['genres'] as Map)['genre'] as List;
      expect(genres.map((g) => (g['value'], g['songCount'], g['albumCount'])), [('Jazz', 1, 1), ('Rock', 2, 1)]);
      expect(((await answer('getRandomSongs', params: {'size': 2}))['randomSongs'] as Map)['song'], hasLength(2));
      expect(((await answer('getRandomSongs', params: {'genre': 'Rock'}))['randomSongs'] as Map)['song'], hasLength(2));
      final byGenre =
          ((await answer('getSongsByGenre', params: {'genre': 'Jazz'}))['songsByGenre'] as Map)['song'] as List;
      expect(byGenre.single['title'], 'Dusk');
      final user = (await answer('getUser'))['user'] as Map<String, dynamic>;
      expect((user['username'], user['adminRole']), ('owner', true));
      for (final method in [
        'getNowPlaying',
        'getPodcasts',
        'getInternetRadioStations',
        'getArtistInfo2',
        'getTopSongs',
      ]) {
        expect((await answer(method))['status'], 'ok', reason: method);
      }
      expect((await failure('getVideos'))['code'], 0);
    });
  });

  group('playing', () {
    test('streams the file with ranges, and answers a missing song with a Subsonic error', () async {
      final id = idOf('Dawn');
      final whole = await call('stream', params: {'id': id});
      expect(whole.statusCode, 200);
      expect(whole.headers['content-type'], contains('wav'));
      expect(whole.bodyBytes.length, tracks.firstWhere((t) => t['id'] == id)['fileSizeBytes']);

      final request = http.Request('GET', whole.request!.url)..headers['Range'] = 'bytes=0-99';
      final partial = await http.Response.fromStream(await request.send());
      expect(partial.statusCode, 206);
      expect(partial.bodyBytes, hasLength(100));

      expect((await call('download', params: {'id': id})).bodyBytes, whole.bodyBytes);
      expect((await failure('stream', params: {'id': 'nonsense'}))['code'], 70);
      expect((await failure('stream'))['code'], 10);
    });

    test('has no cover for files that carry none, and 404 for a picture that is not there', () async {
      final album = ((await answer('getAlbumList2', params: {'type': 'newest'}))['albumList2'] as Map)['album'] as List;
      expect((album.first as Map).containsKey('coverArt'), isFalse);
      expect((await call('getCoverArt', params: {'id': album.first['id'] as String})).statusCode, 404);
      expect((await call('getCoverArt', params: {'id': idOf('Dawn')})).statusCode, 404);
      expect((await call('getCoverArt', params: {'id': 'nonsense'})).statusCode, 404);
    });

    test('has no lyrics for a file without them, and says so', () async {
      final lyrics = (await answer('getLyricsBySongId', params: {'id': idOf('Dawn')}))['lyricsList'] as Map;
      expect(lyrics['structuredLyrics'], isEmpty);
    });
  });

  group('the account', () {
    test('stars songs, lists them, unstars them, and refuses what Wiretune has no counterpart for', () async {
      final dawn = idOf('Dawn');
      final noon = idOf('Noon');
      await answer(
        'star',
        params: {
          'id': [dawn, noon],
        },
      );
      expect((await data()).favorites, unorderedEquals([dawn, noon]));

      final starred = ((await answer('getStarred2'))['starred2'] as Map)['song'] as List;
      expect(starred.map((s) => s['id']), unorderedEquals([dawn, noon]));
      expect((starred.first as Map)['starred'], isNotNull);
      expect(
        ((await answer('getAlbumList2', params: {'type': 'starred'}))['albumList2'] as Map)['album'],
        hasLength(1),
      );

      await answer('unstar', params: {'id': dawn});
      expect((await data()).favorites, [noon]);

      final album = ((await answer('getAlbumList2', params: {'type': 'newest'}))['albumList2'] as Map)['album'] as List;
      expect((await failure('star', params: {'id': album.first['id'] as String}))['code'], 0);
      expect((await failure('star', params: {'albumId': album.first['id'] as String}))['code'], 0);
      expect((await failure('star'))['code'], 10);
    });

    test('counts a play when an app says it was played, and not when it says it is playing now', () async {
      final id = idOf('Dusk');
      await answer('scrobble', params: {'id': id, 'submission': 'false'});
      expect((await data()).plays, isEmpty);
      await answer('scrobble', params: {'id': id});
      await answer('scrobble', params: {'id': id, 'submission': 'true'});
      expect((await data()).plays.single.playCount, 2);

      final songs = ((await answer('search3', params: {'query': 'dusk'}))['searchResult3'] as Map)['song'] as List;
      expect((songs.single as Map)['playCount'], 2);
      expect((songs.single as Map)['played'], isNotNull);
      expect(
        ((await answer('getAlbumList2', params: {'type': 'frequent'}))['albumList2'] as Map)['album'],
        hasLength(1),
      );
      expect(((await answer('getAlbumList2', params: {'type': 'recent'}))['albumList2'] as Map)['album'], hasLength(1));
    });

    test('keeps playlists that the Wiretune API shows too', () async {
      final dawn = idOf('Dawn');
      final noon = idOf('Noon');
      final dusk = idOf('Dusk');

      final created =
          (await answer(
                'createPlaylist',
                params: {
                  'name': 'Drive',
                  'songId': [dawn, noon],
                },
              ))['playlist']
              as Map;
      final id = created['id'] as String;
      expect((created['name'], created['songCount'], (created['entry'] as List).length), ('Drive', 2, 2));
      expect((await data()).playlists.single.trackIds, [dawn, noon]);

      await answer(
        'updatePlaylist',
        params: {
          'playlistId': id,
          'name': 'Drive home',
          'comment': 'for the car',
          'songIdToAdd': [dusk],
          'songIndexToRemove': 0,
        },
      );
      final playlist = (await data()).playlists.single;
      expect((playlist.name, playlist.description), ('Drive home', 'for the car'));
      expect(playlist.trackIds, [noon, dusk]);

      final listed = ((await answer('getPlaylists'))['playlists'] as Map)['playlist'] as List;
      expect(listed.single['name'], 'Drive home');
      expect(listed.single['songCount'], 2);
      final fetched = (await answer('getPlaylist', params: {'id': id}))['playlist'] as Map;
      expect((fetched['entry'] as List).map((s) => s['title']), ['Noon', 'Dusk']);

      // A playlist made in the Wiretune API shows to the app, and createPlaylist with an ID replaces its songs.
      await admin.put('/api/me/playlists/pl-2', {
        'name': 'From the player',
        'description': null,
        'trackIds': [dusk],
      });
      expect(((await answer('getPlaylists'))['playlists'] as Map)['playlist'] as List, hasLength(2));
      await answer(
        'createPlaylist',
        params: {
          'playlistId': 'pl-2',
          'songId': [dawn],
        },
      );
      expect((await data()).playlists.firstWhere((p) => p.id == 'pl-2').trackIds, [dawn]);

      await answer('deletePlaylist', params: {'id': id});
      expect((await data()).playlists.map((p) => p.id), ['pl-2']);
      expect((await failure('getPlaylist', params: {'id': id}))['code'], 70);
      expect((await failure('createPlaylist'))['code'], 10);
    });

    test("never shows another account's playlists", () async {
      final (guest, _) = await registerGuest(server, admin);
      await guest.put('/api/me/playlists/pl-g', {'name': 'Private', 'description': null, 'trackIds': <String>[]});
      expect(((await answer('getPlaylists'))['playlists'] as Map)['playlist'], isEmpty);
      expect((await failure('getPlaylist', params: {'id': 'pl-g'}))['code'], 70);
    });
  });
}
