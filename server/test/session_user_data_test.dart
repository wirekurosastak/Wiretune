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

/// Waits (up to three seconds) until [condition] holds.
Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
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
      expect(await session.login('owner', 'wrong-password', false), Localizer.get('SessionBadCredentials'));
      expect(await session.login('OWNER', adminPassword, true), isNull);
      expect(session.state, ServerConnectionState.connected);
      expect(session.source, LibrarySource.server);
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
      expect(d.library.getTrack(favorite.id)!.isFavorite, isTrue);

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

      await phone.session.changePassword(adminPassword, 'a-brand-new-password');
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

      // A wrong current password changes nothing.
      await expectLater(
        phone.session.changePassword('not-it', 'another-new-password'),
        throwsA(isA<ServerRequestException>().having((e) => e.statusCode, 'status', 403)),
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
      final same = laptop.library.getTrack(track.id)!;
      expect(same.isFavorite, isTrue);
      expect(same.playCount, 1);
      final shared = laptop.library.playlists.single;
      expect(shared.isServer, isTrue);
      expect(shared.name, 'Road trip');
      expect(shared.trackIds, [track.id]);

      laptop.library.renamePlaylist(shared.id, 'Renamed');
      laptop.library.toggleFavorite(track.id);
      await laptop.session.flushUserData();

      await phone.session.refreshLibrary();
      expect(phone.library.playlists.single.name, 'Renamed');
      expect(phone.library.getTrack(track.id)!.isFavorite, isFalse);
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
      await waitFor(() => phoneRemote.devices.length == 1 && laptopRemote.devices.length == 1);

      final track = phone.library.tracks.first;
      phone.library.toggleFavorite(track.id);
      await waitFor(() => laptop.library.getTrack(track.id)!.isFavorite);
      expect(laptop.library.favorites.single.id, track.id);

      laptop.library.createPlaylist('Shared');
      await waitFor(() => phone.library.playlists.any((pl) => pl.name == 'Shared'));
      expect(phone.library.getTrack(track.id)!.isFavorite, isTrue, reason: 'the refresh keeps what the phone holds');
      expect(told, {'phone': 1, 'laptop': 1}, reason: "each is told of the other's change, not of its own");
    });

    test('hidden content syncs to the server and follows the account to another device', () async {
      final phone = await device('phone-hidden');
      await phone.signIn(server);
      expect(phone.library.tracks, hasLength(3));

      final trackToHide = phone.library.tracks.first;
      phone.library.hideTrack(trackToHide.id);
      await phone.session.flushUserData();

      final data = await serverData(admin);
      expect(data.hiddenTracks, [trackToHide.id]);
      expect(phone.library.tracks, hasLength(2));
      expect(phone.library.isTrackHidden(trackToHide), isTrue);

      final laptop = await device('laptop-hidden');
      await laptop.signIn(server);
      expect(laptop.library.tracks, hasLength(2));
      expect(laptop.library.hiddenTracks, contains(trackToHide.id));

      // Unhide from laptop
      laptop.library.unhideTrack(trackToHide.id);
      await laptop.session.flushUserData();

      await phone.session.refreshLibrary();
      expect(phone.library.tracks, hasLength(3));
      expect(phone.library.isTrackHidden(trackToHide), isFalse);

      // The laptop restarts while the server is away: what the account hid stays hidden there.
      laptop.library.hideTrack(trackToHide.id);
      await laptop.session.flushUserData();
      laptop.session.dispose();
      devices.remove(laptop);
      final library = LibraryService(laptop.repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, 'c2'));
      final offline = ServerSession(library, laptop.repo);
      addTearDown(offline.dispose);
      library.initialize();
      offline.initialize();
      expect(offline.state, ServerConnectionState.offline);
      expect(library.hiddenTracks, contains(trackToHide.id));
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
      d.library.hideTrack(hidden.id);
      final account = d.session.currentUser!.id;
      expect(d.repo.getHiddenItems(account)['track'], {hidden.id});

      await d.session.logout();
      expect(d.library.tracks, isEmpty);
      expect(d.library.playlists.any((pl) => pl.isServer), isFalse);
      expect(d.library.serverConnected, isFalse);
      expect(d.repo.getHiddenItems(account)['track'], isEmpty);
      expect(d.repo.getSetting('auth_user_id'), '');

      expect(await d.session.login('owner', adminPassword, true), isNull);
      final again = d.library.getTrack(track.id)!;
      expect(again.isFavorite, isTrue);
      expect(again.playCount, 1);
      final restored = d.library.playlists.single;
      expect(restored.isServer, isTrue);
      expect(restored.trackIds, [track.id]);
      expect(d.library.hiddenTracks, contains(hidden.id));
    });

    test('a change made just before a refresh is not undone by it', () async {
      final d = await device('device');
      await d.signIn(server);
      final track = d.library.tracks.first;

      // No flush in between: the refresh itself has to send the pending change before it downloads.
      d.library.toggleFavorite(track.id);
      await d.session.refreshLibrary();

      expect(d.library.getTrack(track.id)!.isFavorite, isTrue);
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

      expect(d.library.getTrack(track.id)!.isFavorite, isFalse);
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

  group('against a scripted server', () {
    final auth = AuthResponse(
      't0ken',
      UserInfo('u1', 'owner', true, DateTime.now().toUtc(), null),
      DateTime.now().toUtc().add(const Duration(days: 1)),
    );

    http.Response respond(Object value, [int status = 200]) =>
        http.Response(jsonEncode(value), status, headers: {'content-type': 'application/json'});
    final empty = const UserDataSnapshot([], [], []).toJson();

    Future<(ServerSession, LibraryService, List<String>)> scripted(
      http.Response? Function(http.Request request) more,
    ) async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        return switch (request.url.path) {
          '/api/auth/setup-required' => respond({'setupRequired': false}),
          '/api/auth/login' => respond(auth.toJson()),
          '/api/auth/me' => respond(auth.user.toJson()),
          '/api/tracks' => respond([TestSupport.makeTrack('s1', 'Server song').toJson()]),
          '/api/me/data' => respond(empty),
          _ => more(request) ?? http.Response('', 404),
        };
      });
      final repo = testRepository();
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
      library.initialize();
      final session = ServerSession(library, repo, ServerStreamingClient(client));
      session.initialize();
      await session.connect('http://wiretune.test');
      expect(await session.login('owner', 'correct horse', true), isNull);
      return (session, library, requests);
    }

    test('a server that refuses a change can be reached, so the session stays connected', () async {
      final (session, library, requests) = await scripted(
        (request) => switch (request.url.path) {
          final path when path.startsWith('/api/me/playlists/') => respond({
            'error': 'An account can have at most 500 playlists.',
          }, 409),
          _ => null,
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
      final (session, library, requests) = await scripted(
        (request) => switch (request.url.path) {
          '/api/me/favorites/s1' => respond({'error': 'Database is locked.'}, 500),
          _ => null,
        },
      );
      addTearDown(session.dispose);
      expect(library.serverConnected, isTrue);

      library.toggleFavorite('s1');
      await session.flushUserData();
      expect(requests, contains('PUT /api/me/favorites/s1'));
      expect(library.getTrack('s1')!.isFavorite, isFalse);
    });

    test('a connection cut in the middle of the library download is reported', () async {
      final client = MockClient.streaming((request, _) async {
        if (request.url.path == '/api/auth/setup-required') {
          return http.StreamedResponse(Stream.value(utf8.encode('{"setupRequired":false}')), 200);
        }
        if (request.url.path == '/api/auth/me') {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(auth.user.toJson()))), 200);
        }
        return http.StreamedResponse(Stream<List<int>>.error(const SocketException('Connection reset by peer')), 200);
      });
      final repo = testRepository()
        ..setSetting('server_url', 'http://wiretune.test')
        ..setSetting('library_source', 'server')
        ..setSetting('auth_token', 'stored');
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
      library.initialize();
      final session = ServerSession(library, repo, ServerStreamingClient(client));
      addTearDown(session.dispose);
      session.initialize();
      expect(session.state, ServerConnectionState.offline); // a stored server source starts offline
      await session.connect();
      expect(session.state, ServerConnectionState.offline);
      expect(session.statusMessage, contains('connection was lost'));
    });
  });

  test("while the server cannot be reached its tracks cannot be changed, but local ones can", () async {
    final repo = testRepository()
      ..replaceAllTracks([TestSupport.makeServerTrack('s1', 'Server song'), TestSupport.makeTrack('l1', 'Local song')]);
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();

    final session = ServerSession(
      library,
      repo,
      ServerStreamingClient(MockClient((_) => throw StateError('no request expected'))),
    );
    addTearDown(session.dispose);
    session.initialize();
    expect(library.serverConnected, isFalse);

    library.toggleFavorite('s1');
    library.recordPlay('s1');
    expect(library.getTrack('s1')!.isFavorite, isFalse);
    expect(library.getTrack('s1')!.playCount, 0);

    library.toggleFavorite('l1');
    expect(library.getTrack('l1')!.isFavorite, isTrue);
  });
}
