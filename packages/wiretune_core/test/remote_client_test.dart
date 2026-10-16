// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

Future<bool> until(bool Function() condition, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

/// The remote-control client on its own: when it connects, how it comes back, when it gives up, and what it accepts.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late LibraryService library;
  late ServerSession session;

  setUp(() async {
    library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();
    session = await signedInSession(library);
  });
  tearDown(() => session.dispose());

  test('it connects while switched on and signed in, says who it is, and leaves on sign-out', () async {
    final hub = FakeRemoteHub();
    final client = RemoteClient(session, connector: hub.connect);
    addTearDown(client.dispose);

    client.configure(id: 'desk', name: '  Living\troom  ', kind: DeviceKind.desktop, enabled: false);
    await pumpEventQueue();
    expect(hub.connections, 0);

    client.configure(id: 'desk', name: '  Living\troom  ', kind: DeviceKind.desktop, enabled: true);
    expect(await until(() => client.isConnected), isTrue);
    expect(hub.ofType('hello').single, {
      'type': 'hello',
      'device': {'id': 'desk', 'name': 'Livingroom', 'kind': 'desktop'},
    });

    // A rename is a second hello on the same connection.
    client.configure(id: 'desk', name: 'Study', kind: DeviceKind.desktop, enabled: true);
    expect(((hub.ofType('hello').last['device'] as Map)['name']), 'Study');
    expect(hub.connections, 1);

    await session.logout();
    expect(client.isConnected, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.connections, 1);
  });

  test('a dropped connection comes back and tells its state again; a refusal is not retried', () async {
    final hub = FakeRemoteHub();
    final client = RemoteClient(session, connector: hub.connect);
    addTearDown(client.dispose);
    client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
    expect(await until(() => client.isConnected), isTrue);
    client.publish(const RemotePlayback(playing: true, position: Duration(seconds: 7)));
    await pumpEventQueue();
    expect(hub.ofType('state'), hasLength(1));

    await hub.drop();
    await pumpEventQueue();
    expect(client.isConnected, isFalse);
    expect(await until(() => hub.connections == 2, within: const Duration(seconds: 4)), isTrue);
    expect(await until(() => hub.ofType('state').length == 2), isTrue);
    expect((hub.ofType('state').last['state'] as Map)['positionMs'], 7000);

    // The server turns the token away: asking again with the same one would only be turned away again.
    var attempts = 0;
    final refused = RemoteClient(
      session,
      connector: (uri, token) async {
        attempts++;
        throw const RemoteRefusedException('HTTP 401');
      },
    );
    addTearDown(refused.dispose);
    refused.configure(id: 'phone', name: '', kind: DeviceKind.phone, enabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect((attempts, refused.isConnected), (1, false));
  });

  test('a server from before remote control is asked once, not every minute', () async {
    final old = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => old.close(force: true));
    var asked = 0;
    old.listen((request) {
      asked++;
      request.response
        ..statusCode = 404
        ..close();
    });
    final elsewhere = await signedInSession(library, serverUrl: 'http://127.0.0.1:${old.port}');
    addTearDown(elsewhere.dispose);
    final client = RemoteClient(elsewhere); // the real WebSocket
    addTearDown(client.dispose);
    client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect((asked, client.isConnected), (1, false));
  });

  test('closed for good: replaced, too many devices or signed out, it stays away', () async {
    for (final code in [RemoteRules.closeReplaced, RemoteRules.closeTooManyDevices, RemoteRules.closeSignedOut]) {
      var connections = 0;
      late StreamController<Object?> incoming;
      final client = RemoteClient(
        session,
        connector: (uri, token) async {
          connections++;
          incoming = StreamController();
          return RemoteChannel(
            messages: incoming.stream,
            send: (_) {},
            close: () => incoming.close(),
            closeCode: () => code,
          );
        },
      );
      client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
      expect(await until(() => client.isConnected), isTrue);
      expect(client.problem, isNull);
      await incoming.close();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect((connections, client.isConnected), (1, false), reason: 'close code $code');
      // The settings say why it stopped.
      expect(client.problem, switch (code) {
        RemoteRules.closeReplaced => RemoteProblem.replaced,
        RemoteRules.closeTooManyDevices => RemoteProblem.tooManyDevices,
        _ => RemoteProblem.ended,
      });
      client.dispose();
    }
  });

  test(
    'a server without remote control, or one that refuses the token, is told apart; signing out forgets it',
    () async {
      for (final (status, problem) in [(404, RemoteProblem.unsupported), (401, RemoteProblem.ended)]) {
        final client = RemoteClient(
          session,
          connector: (uri, token) async => throw RemoteRefusedException('HTTP $status', status),
        );
        client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
        expect(await until(() => client.problem != null), isTrue);
        expect(client.problem, problem);
        client.dispose();
      }

      final client = RemoteClient(
        session,
        connector: (uri, token) async => throw const RemoteRefusedException('HTTP 404', 404),
      );
      addTearDown(client.dispose);
      client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
      expect(await until(() => client.problem == RemoteProblem.unsupported), isTrue);
      await session.logout();
      expect(client.problem, isNull);
    },
  );

  test('what does not keep to the protocol is ignored', () async {
    final hub = FakeRemoteHub();
    final client = RemoteClient(session, connector: hub.connect);
    addTearDown(client.dispose);
    final commands = <(String, RemoteCommand)>[];
    client.commandReceived.listen(commands.add);
    client.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
    expect(await until(() => client.isConnected), isTrue);
    hub.devices([('phone', 'Phone', DeviceKind.phone), ('desk', 'Me myself', DeviceKind.desktop)]);
    await pumpEventQueue();
    expect([for (final d in client.devices) d.id], ['phone'], reason: 'this device is not one of the others');

    for (final junk in [
      'not json',
      '[1, 2]',
      jsonEncode({'type': 'unknown'}),
      jsonEncode({'type': 'devices', 'devices': 'nope'}),
      jsonEncode({'type': 'state', 'device': 'nobody', 'state': const RemotePlayback().toJson()}),
      jsonEncode({
        'type': 'state',
        'device': 'phone',
        'state': {'playing': true}, // no position, no volume, no queue
      }),
      jsonEncode({
        'type': 'command',
        'from': 'stranger',
        'command': {'action': 'pause'},
      }),
      jsonEncode({
        'type': 'command',
        'from': 'phone',
        'command': {'action': 'seek', 'positionMs': -5},
      }),
      jsonEncode({
        'type': 'command',
        'from': 'phone',
        'command': {'action': 'reboot'},
      }),
    ]) {
      hub.deliverRaw(junk);
    }
    hub.deliverRaw(utf8.encode('binary')); // text frames only
    await pumpEventQueue();
    expect(commands, isEmpty);
    expect(client.device('phone')!.playback, isNull);

    hub.command('phone', const RemoteCommand(RemoteAction.volume, volume: 250));
    await pumpEventQueue();
    expect((commands.single.$1, commands.single.$2.volume), ('phone', 100.0), reason: 'clamped to 0..100');
  });

  test('a state and a command survive the trip, and the limits hold', () {
    final track = TestSupport.makeServerTrack('t1', 'Naima', artist: 'John Coltrane');
    final state = RemotePlayback(
      track: track,
      playing: true,
      position: const Duration(seconds: 42),
      volume: 55,
      muted: true,
      shuffle: true,
      repeat: RepeatMode.one,
      queue: const ['t0', 't1'],
      queueIndex: 1,
    );
    final back = RemotePlayback.fromJson(jsonDecode(jsonEncode(state.toJson())))!;
    expect((back.track!.id, back.track!.title, back.track!.duration), ('t1', 'Naima', track.duration));
    expect(
      (back.playing, back.position, back.volume, back.muted, back.shuffle, back.repeat, back.queueIndex),
      (true, const Duration(seconds: 42), 55.0, true, true, RepeatMode.one, 1),
    );
    expect(back.queue, ['t0', 't1']);
    expect(back.track!.filePath, isEmpty, reason: 'a path on one device means nothing on another');

    Map<String, Object?> with_(String key, Object? value) => {...state.toJson(), key: value};
    expect(RemotePlayback.fromJson(with_('queue', List.filled(RemoteRules.maxQueueLength + 1, 't'))), isNull);
    expect(RemotePlayback.fromJson(with_('queue', ['ok', 'bad\nid'])), isNull);
    expect(RemotePlayback.fromJson(with_('track', {'title': 'no id'})), isNull);
    expect(RemotePlayback.fromJson(with_('queueIndex', 9))!.queueIndex, -1);

    final play = RemoteCommand.fromJson(
      const RemoteCommand(RemoteAction.playTracks, trackIds: ['a', 'b'], index: -1).toJson(),
    )!;
    expect((play.action, play.index), (RemoteAction.playTracks, -1));
    expect(play.trackIds, ['a', 'b']);
    expect(
      RemoteCommand.fromJson({
        'action': 'playTracks',
        'trackIds': ['a'],
        'index': 1,
        'positionMs': 0,
      }),
      isNull,
    );
    expect(RemoteCommand.fromJson({'action': 'mute'}), isNull);
    expect(RemoteRules.cleanName('x' * 100), hasLength(RemoteRules.maxDeviceNameLength));
  });
}
