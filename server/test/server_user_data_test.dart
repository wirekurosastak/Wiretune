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
    await guest.put('/api/me/playlists/pl-1', {'name': 'Mine', 'description': null, 'trackIds': <String>[]});
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

    test('import is a union that never lowers what the server holds', () async {
      final (admin, _) = await setupAdmin(server);
      await admin.put('/api/me/favorites/a');
      await admin.post('/api/me/plays/a');
      await admin.post('/api/me/plays/a');
      await admin.put('/api/me/playlists/pl', {
        'name': 'Server copy',
        'trackIds': ['a'],
      });

      final played = DateTime.utc(2026);
      final import = UserDataSnapshot(
        ['a', 'b'],
        [const TrackPlayStats('a', 1, null), TrackPlayStats('c', 5, played)],
        [
          PlaylistData('pl', 'Device copy', null, const ['x'], played, played),
          PlaylistData('pl-2', 'Only on the device', null, const ['b'], played, played),
        ],
      ).toJson();

      for (var round = 0; round < 2; round++) {
        final response = await admin.post('/api/me/data/import', import);
        expect(response.statusCode, 200);
        expect(json(response), {'favorites': 2, 'plays': 2, 'playlists': 2});

        final stored = await data(admin);
        expect(stored.favorites.toList()..sort(), ['a', 'b']);
        expect(stored.plays.singleWhere((p) => p.trackId == 'a').playCount, 2); // the higher count wins
        final c = stored.plays.singleWhere((p) => p.trackId == 'c');
        expect((c.playCount, c.lastPlayed), (5, played));
        expect(stored.playlists.singleWhere((p) => p.id == 'pl').name, 'Server copy');
        expect(stored.playlists.singleWhere((p) => p.id == 'pl-2').name, 'Only on the device');
      }
    });

    test('an import with one invalid entry stores nothing', () async {
      final (admin, _) = await setupAdmin(server);
      final import = UserDataSnapshot(['fine', 'x' * (UserDataRules.maxIdLength + 1)], const [], const []).toJson();
      expect((await admin.post('/api/me/data/import', import)).statusCode, 400);
      expect((await data(admin)).favorites, isEmpty);
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

      expect((await admin.delete('/api/users/${guestInfo.id}')).statusCode, 200);

      final stored = server.server.userData.get(guestInfo.id);
      expect(stored.favorites, isEmpty);
      expect(stored.plays, isEmpty);
      expect(stored.playlists, isEmpty);
      expect((await guest.get('/api/me/data')).statusCode, 401);
    });
  });
}
