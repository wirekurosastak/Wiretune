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

  final MockRepository repo;
  final LibraryService library;
  final ServerSession session;

  static Future<Device> create(ServerFixture server, String name) async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, '$name-covers'));
    final session = ServerSession(library, repo);
    await library.initialize();
    await session.initialize();
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
      expect(await session.login('owner', 'wrong-password', false), Localizer.get('SessionBadCredentials'));
      expect(await session.login('OWNER', adminPassword, true), isNull);
      expect(session.state, ServerConnectionState.connected);
      expect(session.source, LibrarySource.server);
      expect(d.library.tracks, hasLength(3));
      for (final t in d.library.tracks) {
        expect(t.streamUrl, startsWith('${server.baseUrl}/api/stream/'));
        expect(t.streamUrl, isNot(contains('token')));
      }
      expect(d.repo.settings['auth_token'], session.authToken);

      // A favourite survives a refresh from the server.
      final favorite = d.library.tracks.first;
      await d.library.toggleFavorite(favorite.id);
      await session.refreshLibrary();
      expect(d.library.getTrack(favorite.id)!.isFavorite, isTrue);

      // Signing out forgets the token.
      await session.logout();
      expect(session.state, ServerConnectionState.loginRequired);
      expect(d.repo.settings['auth_token'], '');

      // A stale token is dropped on reconnect instead of looping on 401s.
      d.repo.settings['auth_token'] = 'not-a-valid-token';
      final restarted = ServerSession(d.library, d.repo);
      addTearDown(restarted.dispose);
      await restarted.initialize();
      await restarted.connect();
      expect(restarted.state, ServerConnectionState.loginRequired);
      expect(d.repo.settings['auth_token'], '');
    });

    test('a fresh server asks for setup, and setting it up signs in', () async {
      final fresh = await ServerFixture.start();
      addTearDown(fresh.close);
      final d = await device('fresh');
      await d.session.connect(fresh.baseUrl);
      expect(d.session.state, ServerConnectionState.setupRequired);
      expect(await d.session.setupAdmin('owner', adminPassword, 'wrong'), contains('setup code'));
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
      await phone.library.toggleFavorite(track.id);
      await phone.library.recordPlay(track.id);
      final playlist = await phone.library.createPlaylist('Road trip');
      await phone.library.addTrackToPlaylist(playlist.id, track.id);
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

      await laptop.library.renamePlaylist(shared.id, 'Renamed');
      await laptop.library.toggleFavorite(track.id);
      await laptop.session.flushUserData();

      await phone.session.refreshLibrary();
      expect(phone.library.playlists.single.name, 'Renamed');
      expect(phone.library.getTrack(track.id)!.isFavorite, isFalse);
    });

    test("signing out removes the account's data from the device, and signing in brings it back", () async {
      final d = await device('device');
      await d.signIn(server);
      final track = d.library.tracks.first;
      await d.library.toggleFavorite(track.id);
      await d.library.recordPlay(track.id);
      final playlist = await d.library.createPlaylist('List');
      await d.library.addTrackToPlaylist(playlist.id, track.id);

      await d.session.logout();
      expect(d.library.tracks, isEmpty);
      expect(d.library.playlists.any((pl) => pl.isServer), isFalse);
      expect(d.library.serverConnected, isFalse);

      expect(await d.session.login('owner', adminPassword, true), isNull);
      final again = d.library.getTrack(track.id)!;
      expect(again.isFavorite, isTrue);
      expect(again.playCount, 1);
      final restored = d.library.playlists.single;
      expect(restored.isServer, isTrue);
      expect(restored.trackIds, [track.id]);
    });

    test('a change made just before a refresh is not undone by it', () async {
      final d = await device('device');
      await d.signIn(server);
      final track = d.library.tracks.first;

      // No flush in between: the refresh itself has to send the pending change before it downloads.
      await d.library.toggleFavorite(track.id);
      await d.session.refreshLibrary();

      expect(d.library.getTrack(track.id)!.isFavorite, isTrue);
      expect((await serverData(admin)).favorites, [track.id]);
    });

    test('another account signing in later does not inherit what the device showed for the first', () async {
      final (guest, _) = await registerGuest(server, admin);
      final d = await device('shared');
      await d.signIn(server);
      final track = d.library.tracks.first;
      await d.library.toggleFavorite(track.id);
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
      final repo = MockRepository();
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
      await library.initialize();
      final session = ServerSession(library, repo, ServerStreamingClient(client));
      await session.initialize();
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

      await library.createPlaylist('One too many');
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

      await library.toggleFavorite('s1');
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
      final repo = MockRepository()
        ..settings['server_url'] = 'http://wiretune.test'
        ..settings['library_source'] = 'server'
        ..settings['auth_token'] = 'stored';
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
      await library.initialize();
      final session = ServerSession(library, repo, ServerStreamingClient(client));
      addTearDown(session.dispose);
      await session.initialize();
      expect(session.state, ServerConnectionState.offline); // a stored server source starts offline
      await session.connect();
      expect(session.state, ServerConnectionState.offline);
      expect(session.statusMessage, contains('connection was lost'));
    });
  });

  test("while the server cannot be reached its tracks cannot be changed, but local ones can", () async {
    final repo = MockRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    await library.initialize();
    await library.replaceTracks([
      TestSupport.makeServerTrack('s1', 'Server song'),
      TestSupport.makeTrack('l1', 'Local song'),
    ]);

    final session = ServerSession(
      library,
      repo,
      ServerStreamingClient(MockClient((_) => throw StateError('no request expected'))),
    );
    addTearDown(session.dispose);
    await session.initialize();
    expect(library.serverConnected, isFalse);

    await library.toggleFavorite('s1');
    await library.recordPlay('s1');
    expect(library.getTrack('s1')!.isFavorite, isFalse);
    expect(library.getTrack('s1')!.playCount, 0);

    await library.toggleFavorite('l1');
    expect(library.getTrack('l1')!.isFavorite, isTrue);
  });
}
