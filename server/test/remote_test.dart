// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// A player's remote-control connection at the protocol level: what it sends, and everything it was sent.
class Peer {
  Peer._(this.socket) {
    socket.listen((message) => messages.add(jsonDecode(message as String) as Map<String, Object?>));
  }

  final WebSocket socket;
  final List<Map<String, Object?>> messages = [];

  static Future<Peer> connect(ServerFixture server, String token, String id, {String name = ''}) async {
    final peer = Peer._(await openSocket(server, token));
    peer.send({
      'type': 'hello',
      'device': {'id': id, 'name': name, 'kind': 'phone'},
    });
    return peer;
  }

  void send(Object message) => socket.add(message is String ? message : jsonEncode(message));

  /// The latest list of the other devices the server sent.
  List<String> get devices => [
    for (final d in (messages.lastWhere((m) => m['type'] == 'devices')['devices'] as List).cast<Map>())
      d['id'] as String,
  ];

  Iterable<Map<String, Object?>> ofType(String type) => messages.where((m) => m['type'] == type);

  Future<void> close() => socket.close();
}

Future<WebSocket> openSocket(ServerFixture server, String token) =>
    WebSocket.connect('ws://127.0.0.1:${server.server.port}/api/remote', headers: {'Authorization': 'Bearer $token'});

/// Waits for the server's close (the socket's stream must be listened to); its code. Watches the state rather than
/// `done`, which never completes for a socket that sent nothing.
Future<int?> closedWith(WebSocket socket) async {
  for (var i = 0; i < 250 && socket.readyState != WebSocket.closed; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(socket.readyState, WebSocket.closed, reason: 'the server closes the connection');
  return socket.closeCode;
}

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late ServerFixture server;
  late Api admin;
  late String adminToken;

  setUp(() async {
    server = await ServerFixture.start();
    final (client, auth) = await setupAdmin(server);
    admin = client;
    adminToken = auth.token;
  });
  tearDown(() async => server.close());

  test('the players of one account see each other, their states and their commands; nobody else does', () async {
    final desktop = await Peer.connect(server, adminToken, 'desktop-1', name: 'Living room');
    final phone = await Peer.connect(server, adminToken, 'phone-1', name: 'Pocket');
    bool sees(Peer peer, String id) => peer.ofType('devices').isNotEmpty && peer.devices.contains(id);
    await until(() => sees(desktop, 'phone-1') && sees(phone, 'desktop-1'));
    expect(phone.devices, ['desktop-1']);
    expect(desktop.devices, ['phone-1']);
    final listed = (phone.ofType('devices').last['devices'] as List).single as Map;
    expect((listed['name'], listed['kind']), ('Living room', 'phone'));

    // Another account, on the same server: sees none of them, and its commands reach none of them.
    final (guest, _) = await registerGuest(server, admin);
    final stranger = await Peer.connect(server, guest.token!, 'stranger-1');
    await until(() => stranger.ofType('devices').isNotEmpty);
    expect(stranger.devices, isEmpty);
    stranger.send({
      'type': 'command',
      'to': 'desktop-1',
      'command': {'action': 'pause'},
    });

    desktop.send({
      'type': 'state',
      'state': {'playing': true, 'positionMs': 1234},
    });
    await until(() => phone.ofType('state').isNotEmpty);
    expect(phone.ofType('state').single, {
      'type': 'state',
      'device': 'desktop-1',
      'state': {'playing': true, 'positionMs': 1234},
    });

    phone.send({
      'type': 'command',
      'to': 'desktop-1',
      'command': {'action': 'next'},
    });
    await until(() => desktop.ofType('command').isNotEmpty);
    expect(desktop.ofType('command').single, {
      'type': 'command',
      'from': 'phone-1',
      'command': {'action': 'next'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stranger.ofType('state'), isEmpty);
    expect(stranger.ofType('command'), isEmpty);
    expect(desktop.ofType('command'), hasLength(1), reason: "the stranger's command must not arrive");

    // A player that joins later is told what the others play right away; one that leaves is gone from the list.
    final laptop = await Peer.connect(server, adminToken, 'laptop-1');
    await until(() => laptop.ofType('state').isNotEmpty && sees(phone, 'laptop-1'));
    expect(laptop.ofType('state').single['device'], 'desktop-1');
    await laptop.close();
    await until(() => !sees(phone, 'laptop-1'));
    expect(phone.devices, ['desktop-1']);

    for (final peer in [desktop, phone, stranger]) {
      await peer.close();
    }
  });

  test('only a sign-in token in the header opens it, only as a WebSocket, and never from a web page', () async {
    final streamToken = json(await admin.post('/api/auth/stream-token'))['token'] as String;
    for (final token in [streamToken, 'not-a-token']) {
      await expectLater(
        openSocket(server, token),
        throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', 401)),
      );
    }
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${server.server.port}/api/remote?token=$adminToken'),
      throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', 401)),
    );
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:${server.server.port}/api/remote',
        headers: {'Authorization': 'Bearer $adminToken', 'Origin': 'http://evil.example'},
      ),
      throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', 403)),
    );
    final plain = await http.get(
      Uri.parse('${server.baseUrl}/api/remote'),
      headers: {'Authorization': 'Bearer $adminToken'},
    );
    expect(plain.statusCode, 426);
  });

  test(
    'a player that breaks the rules is disconnected, and the same device connecting again replaces itself',
    () async {
      final noHello = await openSocket(server, adminToken);
      noHello
        ..listen((_) {}) // the close arrives on the stream
        ..add(jsonEncode({'type': 'state', 'state': {}}));
      expect(await closedWith(noHello), 1008);

      final garbage = await Peer.connect(server, adminToken, 'garbage');
      garbage.send('{not json');
      expect(await closedWith(garbage.socket), 1008);

      final huge = await Peer.connect(server, adminToken, 'huge');
      huge.send({
        'type': 'state',
        'state': {'pad': 'x' * (RemoteRules.maxMessageLength + 1)},
      });
      expect(await closedWith(huge.socket), 1009);

      final badId = await Peer.connect(server, adminToken, 'x' * 200);
      expect(await closedWith(badId.socket), 1008);

      final first = await Peer.connect(server, adminToken, 'same-device');
      final watcher = await Peer.connect(server, adminToken, 'watcher');
      await until(() => watcher.ofType('devices').isNotEmpty);
      expect(watcher.devices, ['same-device']);
      final second = await Peer.connect(server, adminToken, 'same-device');
      expect(await closedWith(first.socket), RemoteRules.closeReplaced);
      // The watcher saw it leave and come back: one device, the new connection.
      await until(() => watcher.ofType('devices').length == 3);
      expect(watcher.devices, ['same-device']);
      await until(() => second.ofType('devices').isNotEmpty);
      expect(second.devices, ['watcher']);
      expect(server.server.remote.devicesOf(json(await admin.get('/api/auth/me'))['id'] as String), 2);
      await second.close();
      await watcher.close();
    },
  );

  test('an account has a limit of devices, and deleting it ends its connections', () async {
    final (guest, info) = await registerGuest(server, admin);
    final peers = [
      for (var i = 0; i < RemoteRules.maxDevicesPerAccount; i++) await Peer.connect(server, guest.token!, 'device-$i'),
    ];
    await until(() => server.server.remote.devicesOf(info.id) == RemoteRules.maxDevicesPerAccount);
    final extra = await Peer.connect(server, guest.token!, 'one-too-many');
    expect(await closedWith(extra.socket), RemoteRules.closeTooManyDevices);
    // Connections that never say hello count too: twice the devices, and the next one is turned away at the door.
    final silent = [
      for (var i = 0; i < RemoteRules.maxDevicesPerAccount; i++)
        (await openSocket(server, guest.token!))..listen((_) {}),
    ];
    await expectLater(
      openSocket(server, guest.token!),
      throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', 429)),
    );

    expect((await admin.delete('/api/users/${info.id}')).statusCode, 200);
    for (final socket in [for (final peer in peers) peer.socket, ...silent]) {
      expect(await closedWith(socket), RemoteRules.closeSignedOut);
    }
    expect(server.server.remote.devicesOf(info.id), 0);
  });

  test("a password change ends the account's connections, and the new token opens one again", () async {
    final (guest, info) = await registerGuest(server, admin);
    final peer = await Peer.connect(server, guest.token!, 'phone');
    await until(() => server.server.remote.devicesOf(info.id) == 1);

    final changed = await guest.post('/api/auth/change-password', {'newPassword': 'another-password'});
    expect(changed.statusCode, 200);
    expect(await closedWith(peer.socket), RemoteRules.closeSignedOut);
    await expectLater(
      openSocket(server, guest.token!),
      throwsA(isA<WebSocketException>().having((e) => e.httpStatusCode, 'status', 401)),
    );

    final again = await Peer.connect(server, AuthResponse.fromJson(json(changed)).token, 'phone');
    await until(() => server.server.remote.devicesOf(info.id) == 1);
    await again.close();
  });

  test('a connection ends when the token it was opened with expires', () async {
    final me = UserInfo.fromJson(json(await admin.get('/api/auth/me')));
    final secret = (server.server.repository.getSetting('jwt_secret'))!;
    final shortLived = Jwt(secret).sign({
      'sub': me.id,
      'name': me.username,
      'role': 'admin',
      'aud': AuthService.audience,
      'exp': DateTime.now().toUtc().add(const Duration(seconds: 2)).millisecondsSinceEpoch ~/ 1000,
    });
    final peer = await Peer.connect(server, shortLived, 'short-lived');
    await until(() => peer.ofType('devices').isNotEmpty);
    expect(await closedWith(peer.socket), RemoteRules.closeSignedOut);
  });

  test('two signed-in players, through the client: each sees the other, its playback and its commands', () async {
    Future<(ServerSession, RemoteClient)> player(String id, String name, DeviceKind kind) async {
      final repo = testRepository();
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, '$id-covers'));
      final session = ServerSession(library, repo);
      final remote = RemoteClient(session);
      addTearDown(() {
        remote.dispose();
        session.dispose();
      });
      library.initialize();
      session.initialize();
      await session.connect(server.baseUrl);
      expect(await session.login('owner', adminPassword, false), isNull);
      remote.configure(id: id, name: name, kind: kind, enabled: true);
      return (session, remote);
    }

    final (_, desktop) = await player('desktop-id', 'Desk', DeviceKind.desktop);
    final (phoneSession, phone) = await player('phone-id', 'Phone', DeviceKind.phone);
    await until(() => phone.devices.length == 1 && desktop.devices.length == 1);
    expect(
      (phone.devices.single.id, phone.devices.single.name, phone.devices.single.kind),
      ('desktop-id', 'Desk', DeviceKind.desktop),
    );

    final track = TestSupport.makeTrack('t1', 'Blue in Green');
    desktop.publish(RemotePlayback(track: track, playing: true, position: const Duration(seconds: 42), volume: 70));
    await until(() => phone.device('desktop-id')?.playback != null);
    final playback = phone.device('desktop-id')!.playback!;
    expect(
      (playback.track?.title, playback.playing, playback.position, playback.volume),
      ('Blue in Green', true, const Duration(seconds: 42), 70.0),
    );

    final received = <(String, RemoteCommand)>[];
    desktop.commandReceived.listen(received.add);
    expect(phone.send('desktop-id', const RemoteCommand(RemoteAction.seek, position: Duration(seconds: 90))), isTrue);
    await until(() => received.isNotEmpty);
    expect(
      (received.single.$1, received.single.$2.action, received.single.$2.position),
      ('phone-id', RemoteAction.seek, const Duration(seconds: 90)),
    );

    // Signing out ends it, and the other side sees the device go.
    await phoneSession.logout();
    await until(() => desktop.devices.isEmpty);
    expect(phone.isConnected, isFalse);
  });
}
