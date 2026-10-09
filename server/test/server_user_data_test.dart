// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Favourites, play counts and playlists live on the server, per account.
void main() {
  Future<UserDataSnapshot> data(Api client) async => UserDataSnapshot.fromJson(json(await client.get('/api/me/data')));

  test('they belong to the account and survive a restart', () async {
    final first = await ServerFixture.start();
    first.keepFiles = true;
    final (admin, _) = await setupAdmin(first);
    final (guest, _) = await registerGuest(first, admin);

    expect((await admin.put('/api/me/favorites/track-a')).statusCode, 200);
    expect((await admin.post('/api/me/plays/track-a')).statusCode, 200);
    final second = await admin.post('/api/me/plays/track-a');
    expect(TrackPlayStats.fromJson(json(second)).playCount, 2);

    final save = await admin.put('/api/me/playlists/pl-1', {
      'name': 'Road trip',
      'description': 'for the car',
      'trackIds': ['track-a', 'track-b'],
    });
    expect(save.statusCode, 200);

    final mine = await data(admin);
    expect(mine.favorites, ['track-a']);
    expect(mine.plays.single.playCount, 2);
    expect(mine.playlists.single.name, 'Road trip');
    expect(mine.playlists.single.description, 'for the car');
    expect(mine.playlists.single.trackIds, ['track-a', 'track-b']);

    // Another account on the same server sees none of it.
    final theirs = await data(guest);
    expect(theirs.favorites, isEmpty);
    expect(theirs.plays, isEmpty);
    expect(theirs.playlists, isEmpty);

    // The same playlist ID in another account is a different playlist.
    final theirsSaved = await guest.put('/api/me/playlists/pl-1', {
      'name': 'Mine',
      'description': null,
      'trackIds': <String>[],
    });
    expect(theirsSaved.statusCode, 200);
    expect((await data(guest)).playlists.single.name, 'Mine');
    expect((await data(admin)).playlists.single.name, 'Road trip');

    await first.close();
    final restarted = await ServerFixture.start(existingRoot: first.root);
    addTearDown(() async {
      await restarted.close();
      first.keepFiles = false;
      await first.close().catchError((_) {});
    });
    final (admin2, _) = await login(restarted, 'owner', adminPassword);
    final after = await data(admin2);
    expect(after.favorites, ['track-a']);
    expect(after.plays.single.playCount, 2);
    expect(after.playlists.single.name, 'Road trip');
  });

  group('with a server', () {
    late ServerFixture server;
    setUp(() async => server = await ServerFixture.start());
    tearDown(() async => server.close());

    test('a favourite says when it was marked, and marking it again keeps that time', () async {
      final (admin, _) = await setupAdmin(server);
      final before = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
      await admin.put('/api/me/favorites/t1');
      final marked = (await data(admin)).favoritedAt['t1'];
      expect(marked != null && marked.isAfter(before), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await admin.put('/api/me/favorites/t1');
      expect((await data(admin)).favoritedAt['t1'], marked);
    });

    test('favourites can be added and removed repeatedly', () async {
      final (admin, _) = await setupAdmin(server);
      expect((await admin.put('/api/me/favorites/t1')).statusCode, 200);
      final again = await admin.put('/api/me/favorites/t1');
      expect(again.statusCode, 200);
      expect(json(again), {'trackId': 't1', 'isFavorite': true});
      expect((await data(admin)).favorites, hasLength(1));

      expect((await admin.delete('/api/me/favorites/t1')).statusCode, 200);
      expect((await admin.delete('/api/me/favorites/t1')).statusCode, 200);
      expect((await data(admin)).favorites, isEmpty);
    });

    test('the routes need a sign-in and reject invalid input', () async {
      final (admin, _) = await setupAdmin(server);
      final anonymous = server.client();
      expect((await anonymous.get('/api/me/data')).statusCode, 401);
      expect((await anonymous.put('/api/me/favorites/t1')).statusCode, 401);

      final tooLong = 'x' * (UserDataRules.maxIdLength + 1);
      expect((await admin.put('/api/me/favorites/$tooLong')).statusCode, 400);
      expect((await admin.post('/api/me/plays/$tooLong')).statusCode, 400);
      expect((await admin.put('/api/me/playlists/p1', {'name': '   ', 'trackIds': <String>[]})).statusCode, 400);
      expect(
        (await admin.put('/api/me/playlists/p1', {
          'name': 'Ok',
          'trackIds': [tooLong],
        })).statusCode,
        400,
      );
      expect(
        (await admin.put('/api/me/playlists/p1', {
          'name': 'n' * (UserDataRules.maxPlaylistNameLength + 1),
          'trackIds': <String>[],
        })).statusCode,
        400,
      );
      expect((await admin.put('/api/me/playlists/p1')).statusCode, 400);

      expect((await admin.delete('/api/me/playlists/unknown')).statusCode, 404);
      expect((await data(admin)).playlists, isEmpty);
    });

    test('PUT replaces the whole playlist and DELETE removes it', () async {
      final (admin, _) = await setupAdmin(server);
      await admin.put('/api/me/playlists/p1', {
        'name': 'First',
        'description': 'one',
        'trackIds': ['a', 'b'],
      });
      final created = (await data(admin)).playlists.single;

      await admin.put('/api/me/playlists/p1', {
        'name': 'Renamed',
        'description': null,
        'trackIds': ['c'],
      });
      final replaced = (await data(admin)).playlists.single;
      expect(replaced.name, 'Renamed');
      expect(replaced.description, isNull);
      expect(replaced.trackIds, ['c']);
      expect(replaced.createdAt, created.createdAt);

      final deleted = await admin.delete('/api/me/playlists/p1');
      expect(deleted.statusCode, 200);
      expect(json(deleted), {'deleted': true});
      expect((await data(admin)).playlists, isEmpty);
    });

    test('deleting an account removes its data and ends its access', () async {
      final (admin, _) = await setupAdmin(server);
      final (guest, guestInfo) = await registerGuest(server, admin);
      await guest.put('/api/me/favorites/t1');
      await guest.post('/api/me/plays/t1');
      await guest.put('/api/me/playlists/p1', {
        'name': 'Mine',
        'trackIds': ['t1'],
      });
      // The data is there before the deletion, so that its absence afterwards is the deletion's doing.
      final before = server.server.userData.get(guestInfo.id);
      expect(before.favorites, ['t1']);
      expect(before.plays.single.playCount, 1);
      expect(before.playlists.single.trackIds, ['t1']);

      expect((await admin.delete('/api/users/${guestInfo.id}')).statusCode, 200);

      final stored = server.server.userData.get(guestInfo.id);
      expect(stored.favorites, isEmpty);
      expect(stored.plays, isEmpty);
      expect(stored.playlists, isEmpty);
      expect((await guest.get('/api/me/data')).statusCode, 401);
    });

    test('hidden content belongs to the account, isolates users, and is removed on account deletion', () async {
      final (admin, _) = await setupAdmin(server);
      final (guest, guestInfo) = await registerGuest(server, admin);

      // Admin hides track, album, artist
      expect((await admin.put('/api/me/hidden/track/t1')).statusCode, 200);
      expect((await admin.put('/api/me/hidden/album/al1')).statusCode, 200);
      expect((await admin.put('/api/me/hidden/artist/ar1')).statusCode, 200);

      // Guest hides different items
      expect((await guest.put('/api/me/hidden/track/t2')).statusCode, 200);

      final adminData = await data(admin);
      expect(adminData.hiddenTracks, ['t1']);
      expect(adminData.hiddenAlbums, ['al1']);
      expect(adminData.hiddenArtists, ['ar1']);

      final guestData = await data(guest);
      expect(guestData.hiddenTracks, ['t2']);
      expect(guestData.hiddenAlbums, isEmpty);
      expect(guestData.hiddenArtists, isEmpty);

      // Invalid item type
      expect((await admin.put('/api/me/hidden/genre/g1')).statusCode, 400);

      // Too long item id
      final tooLong = 'x' * (UserDataRules.maxIdLength + 1);
      expect((await admin.put('/api/me/hidden/track/$tooLong')).statusCode, 400);

      // Unhide
      expect((await admin.delete('/api/me/hidden/track/t1')).statusCode, 200);
      expect((await data(admin)).hiddenTracks, isEmpty);

      // Guest account deletion clears guest hidden items
      expect((await admin.delete('/api/users/${guestInfo.id}')).statusCode, 200);
      final storedGuest = server.server.userData.get(guestInfo.id);
      expect(storedGuest.hiddenTracks, isEmpty);
    });
  });
}
