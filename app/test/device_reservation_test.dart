// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/audio/device_reservation.dart';

import 'support.dart';

/// The ALSA card reservation, on a private bus against a stand-in for the sound server that holds the card the way
/// WirePlumber does: Wiretune takes the card, keeps it while it plays, and the card goes back to the sound server
/// however Wiretune's connection ends (closed by the player or by the system when the process dies).
void main() {
  setUpAll(useTempDataDirectory);

  final hasBus = () {
    try {
      return Process.runSync('dbus-daemon', ['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  late Process daemon;
  late String address;
  final clients = <DBusClient>[];

  DBusClient connect() {
    final client = DBusClient(DBusAddress(address));
    clients.add(client);
    return client;
  }

  setUp(() async {
    if (!hasBus) return;
    daemon = await Process.start('dbus-daemon', ['--session', '--nofork', '--print-address=1']);
    address = await daemon.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
  });

  tearDown(() async {
    if (!hasBus) return;
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    daemon.kill();
    await daemon.exitCode;
  });

  const card = 7;
  final name = AlsaCardReservation.nameOf(card);

  /// The sound server: holds the card open to replacement and lets go of it when asked.
  Future<_SoundServer> soundServer() async {
    final bus = connect();
    final server = _SoundServer(card);
    await bus.registerObject(server);
    await bus.requestName(name, flags: {DBusRequestNameFlag.allowReplacement, DBusRequestNameFlag.doNotQueue});
    return server;
  }

  test('the sound server is asked to let go, and the card is Wiretune\'s', () async {
    final server = await soundServer();
    final bus = connect();

    final reservation = await AlsaCardReservation.acquire(card, bus: bus);

    expect(reservation, isNotNull);
    expect(server.requests, [AlsaCardReservation.priority]);
    expect(await connect().getNameOwner(name), bus.uniqueName);
  }, skip: !hasBus);

  test('while Wiretune plays, nobody else takes the card', () async {
    await soundServer();
    await AlsaCardReservation.acquire(card, bus: connect());
    final other = connect();

    final asked = await DBusRemoteObject(
      other,
      name: name,
      path: DBusObjectPath('/org/freedesktop/ReserveDevice1/Audio$card'),
    ).callMethod('org.freedesktop.ReserveDevice1', 'RequestRelease', [const DBusInt32(100)]);
    final replaced = await other.requestName(
      name,
      flags: {DBusRequestNameFlag.replaceExisting, DBusRequestNameFlag.doNotQueue},
    );

    expect(asked.returnValues.single.asBoolean(), isFalse);
    expect(replaced, DBusRequestNameReply.exists);
  }, skip: !hasBus);

  test('the card goes back when Wiretune\'s connection ends, released or not', () async {
    await soundServer();
    final reservation = (await AlsaCardReservation.acquire(card, bus: connect()))!;
    final observer = connect();

    // Releasing is closing the connection, which is what the system does to a process that crashes or is killed.
    await reservation.release();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await observer.getNameOwner(name), isNull);
    final serverAgain = connect();
    expect(
      await serverAgain.requestName(name, flags: {DBusRequestNameFlag.doNotQueue}),
      DBusRequestNameReply.primaryOwner,
    );
  }, skip: !hasBus);

  test('a holder that does not let go leaves the card alone', () async {
    final bus = connect();
    await bus.registerObject(_SoundServer(card, release: false));
    await bus.requestName(name, flags: {DBusRequestNameFlag.allowReplacement, DBusRequestNameFlag.doNotQueue});

    expect(await AlsaCardReservation.acquire(card, bus: connect()), isNull);
    expect(await connect().getNameOwner(name), bus.uniqueName);
  }, skip: !hasBus);

  test('without a bus there is no reservation, and no error', () async {
    final unreachable = DBusClient(DBusAddress('unix:path=/nonexistent/wiretune-test-bus'));
    expect(await AlsaCardReservation.acquire(card, bus: unreachable), isNull);
  });

  group('the card the player holds', () {
    late List<String> log;
    late Set<int> refused;

    /// Claims that take a while, as the sound server's answer does, and write down what happened in which order.
    ExclusiveCardHolder holder() => ExclusiveCardHolder(
      settle: Duration.zero,
      claim: (card) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (refused.contains(card)) {
          log.add('refused $card');
          return null;
        }
        log.add('claim $card');
        return () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          log.add('release $card');
        };
      },
    );

    setUp(() {
      log = [];
      refused = {};
    });

    test('overlapping requests run in order, and every claim but the last is given back', () async {
      final cards = holder();
      await Future.wait([cards.hold(1), cards.hold(2), cards.release(), cards.hold(1), cards.hold(1)]);
      expect(log, ['claim 1', 'release 1', 'claim 2', 'release 2', 'claim 1']);
      expect(cards.card, 1);

      await cards.release();
      await cards.release();
      expect(log.last, 'release 1');
      expect(log.where((e) => e.startsWith('claim')).length, log.where((e) => e.startsWith('release')).length);
      expect(cards.card, isNull);
    });

    test('a card that cannot be had leaves nothing held, and the one before is given back', () async {
      final cards = holder();
      refused.add(2);
      expect(await cards.hold(1), isTrue);
      expect(await cards.hold(2), isFalse);
      expect(cards.card, isNull);
      expect(log, ['claim 1', 'release 1', 'refused 2']);
    });

    test('a release that fails does not block the next claim', () async {
      var first = true;
      final cards = ExclusiveCardHolder(
        settle: Duration.zero,
        claim: (card) async {
          if (!first) return () async {};
          first = false;
          return () async => throw StateError('the bus is gone');
        },
      );
      expect(await cards.hold(1), isTrue);
      expect(await cards.hold(2), isTrue);
      expect(cards.card, 2);
    });
  });
}

/// Answers `RequestRelease` the way the sound server does, and remembers the priorities it was asked with.
class _SoundServer extends DBusObject {
  _SoundServer(int card, {this.release = true}) : super(DBusObjectPath('/org/freedesktop/ReserveDevice1/Audio$card'));

  final bool release;
  final List<int> requests = [];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name != 'RequestRelease') return DBusMethodErrorResponse.unknownMethod();
    requests.add(methodCall.values.single.asInt32());
    return DBusMethodSuccessResponse([DBusBoolean(release)]);
  }
}
