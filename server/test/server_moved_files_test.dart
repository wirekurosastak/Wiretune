// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// A track is known by its file path, so a file that is moved or renamed would be a new track: its favourites, plays,
/// playlists and hidden items would stay with the old one. The scan pairs them instead.
void main() {
  late ServerFixture server;
  setUp(() async => server = await ServerFixture.start());
  tearDown(() => server.close());

  Future<UserDataSnapshot> data(Api client) async => UserDataSnapshot.fromJson(json(await client.get('/api/me/data')));

  Future<void> scan(Api client) async {
    final before = server.server.scanner.lastScanAt;
    await client.post('/api/library/scan');
    await until(() => server.server.scanner.lastScanAt != before);
  }

  Future<Map<String, String>> idsByTitle(Api client) async => {
    for (final track in (json(await client.get('/api/tracks')) as List).cast<Map<String, dynamic>>())
      track['title'] as String: track['id'] as String,
  };

  test('what every account has on a file goes with it when it is moved or renamed', () async {
    final (admin, _) = await setupAdmin(server);
    final (guest, _) = await registerGuest(server, admin);
    await server.waitForTracks(admin, 3);
    final before = await idsByTitle(admin);
    final third = before['01 Third']!;
    final first = before['01 First']!;

    for (final client in [admin, guest]) {
      await client.put('/api/me/favorites/$third');
      await client.post('/api/me/plays/$third');
      await client.put('/api/me/hidden/track/$third');
    }
    await admin.post('/api/me/plays/$third');
    await admin.put('/api/me/playlists/pl-1', {
      'name': 'Road trip',
      'description': null,
      'trackIds': [first, third],
    });
    await guest.put('/api/me/favorites/$first');

    final moved = p.join(server.musicFolder, 'Artist B', 'Album 2 (reorganised)', 'Third, renamed.wav');
    Directory(p.dirname(moved)).createSync(recursive: true);
    File(p.join(server.musicFolder, 'Artist B', 'Album 2', '01 Third.wav')).renameSync(moved);
    await scan(admin);
    await server.waitForTracks(admin, 3);

    final after = await idsByTitle(admin);
    final renamed = after['Third, renamed']!;
    expect(renamed, isNot(third));

    final mine = await data(admin);
    expect(mine.favorites, [renamed]);
    expect(mine.plays.single.trackId, renamed);
    expect(mine.plays.single.playCount, 2);
    expect(mine.hiddenTracks, [renamed]);
    expect(mine.playlists.single.trackIds, [first, renamed]);

    final theirs = await data(guest);
    expect(theirs.favorites, unorderedEquals([first, renamed]));
    expect(theirs.plays.single.trackId, renamed);
    expect(theirs.hiddenTracks, [renamed]);
  });

  test('a whole folder moved to another place keeps the data of every track in it', () async {
    final (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);
    // The two files of the folder are alike (same size and length) until one is changed.
    writeWav(p.join(server.musicFolder, 'Artist A', 'Album 1', '02 Second.wav'), 44100, seconds: 1.5);
    await scan(admin);
    final before = await idsByTitle(admin);
    await admin.put('/api/me/favorites/${before['01 First']}');
    await admin.put('/api/me/favorites/${before['02 Second']}');

    Directory(p.join(server.musicFolder, 'Artist A')).renameSync(p.join(server.musicFolder, 'Artist A, sorted'));
    await scan(admin);
    await server.waitForTracks(admin, 3);

    final after = await idsByTitle(admin);
    expect((await data(admin)).favorites, unorderedEquals([after['01 First'], after['02 Second']]));
    expect(after['01 First'], isNot(before['01 First']));
  });

  test('two files that are alike and both moved are not guessed: nothing goes to the wrong one', () async {
    final (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);
    final before = await idsByTitle(admin);
    await admin.put('/api/me/favorites/${before['01 First']}');

    Directory(p.join(server.musicFolder, 'Artist A')).renameSync(p.join(server.musicFolder, 'Artist A, sorted'));
    await scan(admin);
    await server.waitForTracks(admin, 3);

    final after = await idsByTitle(admin);
    final favorites = (await data(admin)).favorites;
    expect(favorites, isNot(contains(after['01 First'])));
    expect(favorites, isNot(contains(after['02 Second'])));
  });

  test('a file that is only copied does not take the data of the original', () async {
    final (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);
    final third = (await idsByTitle(admin))['01 Third']!;
    await admin.put('/api/me/favorites/$third');

    File(
      p.join(server.musicFolder, 'Artist B', 'Album 2', '01 Third.wav'),
    ).copySync(p.join(server.musicFolder, 'Artist B', 'Album 2', '02 Third copy.wav'));
    await scan(admin);
    await server.waitForTracks(admin, 4);

    expect((await data(admin)).favorites, [third]);
  });
}
