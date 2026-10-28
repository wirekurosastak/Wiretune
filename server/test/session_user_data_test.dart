// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// One player installation: its own database and its own connection to the server.
class Device {
  Device._(this.repo, this.library, this.session);

  final LibraryRepository repo;
  final LibraryService library;
  final ServerSession session;

  static Future<Device> create(ServerFixture server, String name) async {
    final repo = testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, '$name-covers'));
    final session = ServerSession(library, repo);
    library.initialize();
    session.initialize();
    return Device._(repo, library, session);
  }

  Future<void> signIn(ServerFixture server) async {
    await session.connect(server.baseUrl);
    expect(await session.login('owner', adminPassword, true), isNull);
  }
}

/// The player keeps the signed-in account's favourites, play counts and playlists on the server: what it shows is what
/// the server holds, so it follows the account to other devices and survives a sign-out.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  Future<UserDataSnapshot> serverData(Api client) async =>
      UserDataSnapshot.fromJson(json(await client.get('/api/me/data')));

  group('against the real server', () {
    late ServerFixture server;
    late Api admin;
    final devices = <Device>[];

    setUp(() async {
      server = await ServerFixture.start();
      (admin, _) = await setupAdmin(server);
      await server.waitForTracks(admin, 3);
    });
    tearDown(() async {
      for (final d in devices) {
        d.session.dispose();
      }
      devices.clear();
      await server.close();
    });

    Future<Device> device(String name) async {
      final created = await Device.create(server, name);
      devices.add(created);
      return created;
    }

    test('the full client life cycle', () async {
      final d = await device('client');
      final session = d.session;

      // A fresh server needs its administrator... already created by setUp, so this one signs in.
      await session.connect(server.baseUrl);
      expect(session.state, ServerConnectionState.loginRequired);
      expect(await session.login('owner', 'wrong-password', false), Localizer.get('ErrorWrongCredentials'));
      expect(await session.login('OWNER', adminPassword, true), isNull);
      expect(session.state, ServerConnectionState.connected);
      expect(session.usesServer, isTrue);
      expect(d.library.tracks, hasLength(3));
      for (final t in d.library.tracks) {
        expect(t.streamUrl, startsWith('${server.baseUrl}/api/stream/'));
        expect(t.streamUrl, isNot(contains('token')));
      }
      expect(d.repo.getSetting('auth_token'), session.authToken);

      // A favourite survives a refresh from the server.
      final favorite = d.library.tracks.first;
      d.library.toggleFavorite(favorite.id);
      await session.refreshLibrary();
      expect(d.library.isFavorite(favorite.id), isTrue);

      // Signing out forgets the token.
      await session.logout();
      expect(session.state, ServerConnectionState.loginRequired);
      expect(d.repo.getSetting('auth_token'), '');

      // A stale token is dropped on reconnect instead of looping on 401s.
      d.repo.setSetting('auth_token', 'not-a-valid-token');
      final restarted = ServerSession(d.library, d.repo);
      addTearDown(restarted.dispose);
      restarted.initialize();
      await restarted.connect();
      expect(restarted.state, ServerConnectionState.loginRequired);
      expect(d.repo.getSetting('auth_token'), '');
    });

    test('changing the password keeps this device signed in and signs the others out', () async {
      final phone = await device('phone');
      final desktop = await device('desktop');
      await phone.signIn(server);
      await desktop.signIn(server);
      final before = phone.session.authToken;

      await phone.session.changePassword('a-brand-new-password');
      expect(phone.session.authToken, isNot(before));
      expect(phone.repo.getSetting('auth_token'), phone.session.authToken); // "stay signed in" keeps the new one
      await phone.session.refreshLibrary();
      expect(phone.session.state, ServerConnectionState.connected);
      expect(await phone.session.getStreamToken(), isNotNull);

      await desktop.session.refreshLibrary();
      expect(desktop.session.state, ServerConnectionState.loginRequired);
      expect(desktop.repo.getSetting('auth_token'), '');
      // The device that was signed out says why, in the user's language.
      expect(desktop.session.statusMessage, Localizer.get('ErrorPasswordChanged'));
      Localizer.instance.setLanguage('hu');
      expect(desktop.session.statusMessage, Localizer.get('ErrorPasswordChanged'));
      expect(desktop.session.statusMessage, contains('jelszavát'));
      Localizer.instance.setLanguage('en');

      // A password the server refuses changes nothing.
      await expectLater(
        phone.session.changePassword('short'),
        throwsA(isA<ServerRequestException>().having((e) => e.statusCode, 'status', 400)),
      );
      expect(phone.repo.getSetting('auth_token'), phone.session.authToken);
    });

    test('a fresh server asks for setup, and setting it up signs in', () async {
      final fresh = await ServerFixture.start();
      addTearDown(fresh.close);
      final d = await device('fresh');
      await d.session.connect(fresh.baseUrl);
      expect(d.session.state, ServerConnectionState.setupRequired);
      expect(await d.session.setupAdmin('owner', adminPassword, 'wrong'), Localizer.get('ErrorSetupCodeWrong'));
      expect(await d.session.setupAdmin('owner', adminPassword, setupCode), isNull);
      expect(d.session.isLoggedIn, isTrue);
      expect(d.session.currentUser!.isAdmin, isTrue);
    });

    test('data lives on the server and follows the account to another device', () async {
      final phone = await device('phone');
      await phone.signIn(server);
      expect(phone.library.tracks, hasLength(3));
      expect(phone.library.serverConnected, isTrue);

      final track = phone.library.tracks.first;
      phone.library.toggleFavorite(track.id);
      phone.library.recordPlay(track.id);
      final playlist = phone.library.createPlaylist('Road trip');
      phone.library.addTracksToPlaylist(playlist.id, [track.id]);
      await phone.session.flushUserData();

      final data = await serverData(admin);
      expect(data.favorites, [track.id]);
      expect(data.plays.single.playCount, 1);
      expect(data.playlists.single.name, 'Road trip');
      expect(data.playlists.single.trackIds, [track.id]);

      final laptop = await device('laptop');
      await laptop.signIn(server);
      expect(laptop.library.isFavorite(track.id), isTrue);
      expect(laptop.library.playCount(track.id), 1);
      final shared = laptop.library.playlists.single;
      expect(shared.isServer, isTrue);
      expect(shared.name, 'Road trip');
      expect(shared.trackIds, [track.id]);

      laptop.library.renamePlaylist(shared.id, 'Renamed');
      laptop.library.toggleFavorite(track.id);
      await laptop.session.flushUserData();

      await phone.session.refreshLibrary();
      expect(phone.library.playlists.single.name, 'Renamed');
      expect(phone.library.isFavorite(track.id), isFalse);
    });

    test("a change on one device shows on the account's others at once, without signing in again", () async {
      final phone = await device('phone');
      final laptop = await device('laptop');
      await phone.signIn(server);
      await laptop.signIn(server);

      // Each with its remote-control connection, as the player wires it: the server's word refreshes the data.
      final told = {'phone': 0, 'laptop': 0};
      RemoteClient online(Device d, String id) {
        final remote = RemoteClient(d.session)..configure(id: id, name: id, kind: DeviceKind.phone, enabled: true);
        d.session.deviceId = id;
        remote.accountDataChanged.listen((_) {
          told[id] = told[id]! + 1;
          d.session.refreshUserData();
        });
        addTearDown(remote.dispose);
        return remote;
      }

      final phoneRemote = online(phone, 'phone');
      final laptopRemote = online(laptop, 'laptop');
      await until(() => phoneRemote.devices.length == 1 && laptopRemote.devices.length == 1);

      final track = phone.library.tracks.first;
      phone.library.toggleFavorite(track.id);
      await until(() => laptop.library.isFavorite(track.id));
      expect(laptop.library.favorites.single.id, track.id);

      laptop.library.createPlaylist('Shared');
      await until(() => phone.library.playlists.any((pl) => pl.name == 'Shared'));
      expect(phone.library.isFavorite(track.id), isTrue, reason: 'the refresh keeps what the phone holds');
      expect(told, {'phone': 1, 'laptop': 1}, reason: "each is told of the other's change, not of its own");
    });

    test('new music in the folder shows on the players at once; a scan that finds nothing says nothing', () async {
      final phone = await device('phone-new-music');
      await phone.signIn(server);
      var told = 0;
      final remote = RemoteClient(phone.session)
        ..configure(id: 'phone', name: 'phone', kind: DeviceKind.phone, enabled: true);
      addTearDown(remote.dispose);
      remote.libraryChanged.listen((_) {
        told++;
        phone.session.refreshLibrary();
      });
      await until(() => server.server.remote.devicesOf(phone.session.currentUser!.id) == 1);

      // The scan an administrator asks for here is the one the folder watch asks for a few seconds after a copy.
      writeWav(p.join(server.musicFolder, 'Artist C', 'Album 3', '01 Fourth.wav'), 44100);
      await admin.post('/api/library/scan');
      await until(() => phone.library.tracks.length == 4);
      expect(told, 1);
      expect(phone.session.state, ServerConnectionState.connected);

      final scanned = server.server.scanner.lastScanAt;
      await admin.post('/api/library/scan');
      await until(() => server.server.scanner.lastScanAt != scanned);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(told, 1);
    });

    test('hidden content syncs to the server and follows the account to another device', () async {
      final phone = await device('phone-hidden');
      await phone.signIn(server);
      expect(phone.library.tracks, hasLength(3));

      final trackToHide = phone.library.tracks.first;
      phone.library.setHidden(HiddenKind.track, trackToHide.id, true);
      await phone.session.flushUserData();

      final data = await serverData(admin);
      expect(data.hiddenTracks, [trackToHide.id]);
      expect(phone.library.tracks, hasLength(2));
      expect(phone.library.isTrackHidden(trackToHide), isTrue);

      final laptop = await device('laptop-hidden');
      await laptop.signIn(server);
      expect(laptop.library.tracks, hasLength(2));
      expect(laptop.library.hidden(HiddenKind.track), contains(trackToHide.id));

      // Unhide from laptop
      laptop.library.setHidden(HiddenKind.track, trackToHide.id, false);
      await laptop.session.flushUserData();

      await phone.session.refreshLibrary();
      expect(phone.library.tracks, hasLength(3));
      expect(phone.library.isTrackHidden(trackToHide), isFalse);

      // The laptop restarts while the server is away: what the account hid stays hidden there.
      laptop.library.setHidden(HiddenKind.track, trackToHide.id, true);
      await laptop.session.flushUserData();
      laptop.session.dispose();
      devices.remove(laptop);
      final library = LibraryService(laptop.repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, 'c2'));
      final offline = ServerSession(library, laptop.repo);
      addTearDown(offline.dispose);
      library.initialize();
      offline.initialize();
      expect(offline.state, ServerConnectionState.offline);
      expect(library.hidden(HiddenKind.track), contains(trackToHide.id));
      expect(library.tracks, hasLength(2));
    });

    test("signing out removes the account's data from the device, and signing in brings it back", () async {
      final d = await device('device');
      await d.signIn(server);
      final track = d.library.tracks.first;
      d.library.toggleFavorite(track.id);
      d.library.recordPlay(track.id);
      final playlist = d.library.createPlaylist('List');
      d.library.addTracksToPlaylist(playlist.id, [track.id]);
      final hidden = d.library.tracks.last;
      d.library.setHidden(HiddenKind.track, hidden.id, true);
      final account = d.session.currentUser!.id;
      expect(d.repo.getHiddenItems(account)[HiddenKind.track], {hidden.id});

      await d.session.logout();
      expect(d.library.tracks, isEmpty);
      expect(d.library.playlists.any((pl) => pl.isServer), isFalse);
      expect(d.library.serverConnected, isFalse);
      expect(d.repo.getHiddenItems(account)[HiddenKind.track], isEmpty);
      expect(d.repo.getSetting('auth_user_id'), '');

      expect(await d.session.login('owner', adminPassword, true), isNull);
      expect(d.library.isFavorite(track.id), isTrue);
      expect(d.library.playCount(track.id), 1);
      final restored = d.library.playlists.single;
      expect(restored.isServer, isTrue);
      expect(restored.trackIds, [track.id]);
      expect(d.library.hidden(HiddenKind.track), contains(hidden.id));
    });

    test('a change made just before a refresh is not undone by it', () async {
      final d = await device('device');
      await d.signIn(server);
      final track = d.library.tracks.first;

      // No flush in between: the refresh itself has to send the pending change before it downloads.
      d.library.toggleFavorite(track.id);
      await d.session.refreshLibrary();

      expect(d.library.isFavorite(track.id), isTrue);
      expect((await serverData(admin)).favorites, [track.id]);
    });

    test('another account signing in later does not inherit what the device showed for the first', () async {
      final (guest, _) = await registerGuest(server, admin);
      final d = await device('shared');
      await d.signIn(server);
      final track = d.library.tracks.first;
      d.library.toggleFavorite(track.id);
      await d.session.flushUserData();

      // The owner's session ends without a sign-out (an expired token does that): the tracks and stars stay on show.
      expect(await d.session.login('guest', guestPassword, false), isNull);

      expect(d.library.isFavorite(track.id), isFalse);
      expect((await serverData(guest)).favorites, isEmpty);
    });

    test('the stream token is short-lived and media-only, and dropped on sign-out', () async {
      final d = await device('device');
      await d.signIn(server);

      final token = await d.session.getStreamToken();
      expect(token, isNotEmpty);
      expect(token, isNot(d.session.authToken));
      expect(await d.session.getStreamToken(), token); // reused until it is about to expire

      final stream = await server.client().get(
        '/api/stream/${d.library.tracks.first.id}?token=${Uri.encodeComponent(token!)}',
      );
      expect(stream.statusCode, 200);

      await d.session.logout();
      expect(await d.session.getStreamToken(), isNull);
    });

    test('an unreachable address turns the session offline with a message', () async {
      final d = await device('device');
      await d.session.connect('http://127.0.0.1:1');
      expect(d.session.state, ServerConnectionState.offline);
      expect(d.session.statusMessage, contains('127.0.0.1:1'));
      await d.session.connect('not a url at all ::');
      expect(d.session.state, ServerConnectionState.offline);
    });

    test('an address that is not a Wiretune server is recognised', () async {
      final other = await HttpServer.bind('127.0.0.1', 0);
      other.listen((request) {
        request.response
          ..headers.contentType = ContentType.html
          ..write('<html>proxy error</html>')
          ..close();
      });
      addTearDown(() => other.close(force: true));

      final d = await device('device');
      await d.session.connect('http://127.0.0.1:${other.port}');
      expect(d.session.state, ServerConnectionState.offline);
      expect(d.session.statusMessage, contains('is this a Wiretune server?'));
    });
  });
}
