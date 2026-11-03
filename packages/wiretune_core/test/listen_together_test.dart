// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Listening together as one player sees it: the group, the invites, the server's clock, and coming back after the
/// connection dropped.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late LibraryService library;
  late ServerSession session;
  late FakeRemoteHub hub;
  late RemoteClient remote;
  late ListenTogether together;

  Map<String, Object?> device(String account, String id) => {
    'accountId': account,
    'username': account == 'user-1' ? 'owner' : 'anna',
    'deviceId': id,
    'deviceName': '',
  };
  Map<String, Object?> group(String hostAccount, String hostDevice, [List<Map<String, Object?>> members = const []]) =>
      {'id': 'g1', 'host': device(hostAccount, hostDevice), 'members': members};

  setUp(() async {
    final saved = (RemoteClient.firstRetry, ListenTogether.clockAskInterval);
    RemoteClient.firstRetry = const Duration(milliseconds: 20);
    ListenTogether.clockAskInterval = const Duration(milliseconds: 5);
    addTearDown(() {
      RemoteClient.firstRetry = saved.$1;
      ListenTogether.clockAskInterval = saved.$2;
    });
    library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();
    session = await signedInSession(library);
    hub = FakeRemoteHub();
    remote = RemoteClient(session, connector: hub.connect)
      ..configure(id: 'phone', name: 'Pocket', kind: DeviceKind.phone, enabled: true);
    together = ListenTogether(remote);
    await until(() => remote.isConnected);
  });
  tearDown(() {
    together.dispose();
    remote.dispose();
    session.dispose();
  });

  test('a host starts a group, invites, sets its clock by the server, and hears the requests', () async {
    expect(together.isAvailable, isTrue);
    together.start(['user-2']);
    expect(hub.ofType('listenStart').single['invite'], ['user-2']);
    hub.deliver({'type': 'listen', 'group': group('user-1', 'phone')});
    await pumpEventQueue();
    expect([together.isHost, together.isMember], [true, false]);

    // The server's clock runs five seconds ahead; the quickest answer counts.
    await until(() => hub.ofType('time').length >= 3);
    for (final ask in hub.ofType('time').toList()) {
      final sent = ask['t']! as int;
      hub.deliver({'type': 'time', 't': sent, 'server': sent + 5000});
    }
    await until(() => together.hasClock);
    expect(together.serverNow().difference(DateTime.now().toUtc()).inMilliseconds, inInclusiveRange(4500, 5100));

    final requests = <(String, RemoteAction)>[];
    together.requestReceived.listen((r) => requests.add((r.$1, r.$2.action)));
    hub.deliver({'type': 'listenCommand', 'from': 'anna', 'command': const RemoteCommand(RemoteAction.next).toJson()});
    await pumpEventQueue();
    expect(requests, [('anna', RemoteAction.next)]);

    together.publish(
      ListeningState(
        queue: const ['s1'],
        queueIndex: 0,
        playing: true,
        position: Duration.zero,
        at: DateTime.utc(2026),
      ),
    );
    expect(hub.ofType('listenState'), hasLength(1));

    together.leave();
    expect(together.group, isNull, reason: 'at once');
    expect(hub.ofType('listenLeave'), hasLength(1));
  });

  test('an invited member joins, follows the state, and hears when the group ends', () async {
    hub.deliver({
      'type': 'listenInvites',
      'invites': [
        {
          'group': 'g1',
          'host': {'id': 'user-2', 'username': 'anna'},
        },
        {'group': 'broken'},
      ],
    });
    await pumpEventQueue();
    expect(together.invites.map((i) => (i.groupId, i.host.username)), [('g1', 'anna')]);

    together.join('g1');
    expect(hub.ofType('listenJoin').single['group'], 'g1');
    hub.deliver({
      'type': 'listen',
      'group': group('user-2', 'desk', [device('user-1', 'phone')]),
    });
    await pumpEventQueue();
    expect(together.isMember, isTrue);

    final states = <ListeningState>[];
    together.stateReceived.listen(states.add);
    final state = ListeningState(
      queue: const ['a', 'b'],
      queueIndex: 1,
      playing: true,
      position: const Duration(seconds: 61),
      at: DateTime.utc(2026, 11, 3, 12),
    );
    hub.deliver({'type': 'listenState', 'state': state.toJson()});
    hub.deliver({'type': 'listenState', 'state': 'nonsense'});
    await pumpEventQueue();
    expect(states.single.trackId, 'b');
    expect(states.single.positionAt(DateTime.utc(2026, 11, 3, 12, 0, 9)), const Duration(seconds: 70));

    // A member asks; a host's request would not be its to hear.
    together.request(const RemoteCommand(RemoteAction.next));
    expect(hub.ofType('listenCommand'), hasLength(1));

    var ended = 0;
    together.ended.listen((_) => ended++);
    hub.deliver({'type': 'listen', 'group': null});
    await pumpEventQueue();
    expect([together.group, ended], [null, 1]);
  });

  test('a member whose connection dropped joins again once it is back', () async {
    together.join('g1');
    hub.deliver({
      'type': 'listen',
      'group': group('user-2', 'desk', [device('user-1', 'phone')]),
    });
    await pumpEventQueue();
    var ended = 0;
    together.ended.listen((_) => ended++);

    await hub.drop();
    await until(() => hub.connections == 2 && remote.isConnected);
    hub.deliver({'type': 'listen', 'group': null}); // what the server says to a player in no group
    await pumpEventQueue();
    expect(hub.ofType('listenJoin'), hasLength(2), reason: 'asked to be let in again');
    expect(ended, 0);

    hub.deliver({'type': 'listen', 'group': null}); // the group is gone
    await pumpEventQueue();
    expect(ended, 1);
  });
}
