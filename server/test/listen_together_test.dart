// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Listening together through the hub: a host invites accounts, their players join, and the hub passes the host's
/// playback to them and their requests to the host, across accounts.
void main() {
  setUpAll(useTempDataDirectory);

  late ServerFixture server;
  late String adminToken;
  late String guestToken;
  late UserInfo guest;
  late String otherToken;

  setUp(() async {
    server = await ServerFixture.start();
    final (admin, auth) = await setupAdmin(server);
    adminToken = auth.token;
    (_, guest) = await registerGuest(server, admin);
    guestToken = (await login(server, 'guest', guestPassword)).$2.token;
    await registerGuest(server, admin, 'other');
    otherToken = (await login(server, 'other', guestPassword)).$2.token;
  });
  tearDown(() => server.close());

  Future<Peer> connect(String token, String id, {String name = ''}) async {
    final peer = await Peer.connect(server, token, id, name: name);
    addTearDown(peer.close);
    await until(() => peer.ofType('devices').isNotEmpty);
    return peer;
  }

  Map<String, Object?>? groupOf(Peer peer) => peer.ofType('listen').lastOrNull?['group'] as Map<String, Object?>?;
  List<Object?> invitesOf(Peer peer) => (peer.ofType('listenInvites').lastOrNull?['invites'] as List?) ?? const [];

  test("the server's clock answers a time", () async {
    final peer = await connect(adminToken, 'desk');
    peer.send({'type': 'time', 't': 12345});
    await until(() => peer.ofType('time').isNotEmpty);
    final answer = peer.ofType('time').single;
    expect(answer['t'], 12345);
    expect((answer['server']! as int) - DateTime.now().millisecondsSinceEpoch, inInclusiveRange(-2000, 2000));
  });

  test('a host invites, an invited player joins and hears the playback; its requests reach the host', () async {
    final host = await connect(adminToken, 'desk', name: 'Living room');
    final phone = await connect(guestToken, 'guest-phone', name: 'Pocket');
    final stranger = await connect(otherToken, 'other-phone');

    host.send({
      'type': 'listenStart',
      'invite': [guest.id],
    });
    await until(() => groupOf(host) != null && invitesOf(phone).isNotEmpty);
    final groupId = groupOf(host)!['id'] as String;
    expect(invitesOf(phone), [
      {
        'group': groupId,
        'host': {'id': (groupOf(host)!['host'] as Map)['accountId'], 'username': 'owner'},
      },
    ]);
    expect(invitesOf(stranger), isEmpty);

    // Not invited: turned away.
    stranger.send({'type': 'listenJoin', 'group': groupId});
    await until(() => stranger.ofType('listen').isNotEmpty);
    expect(groupOf(stranger), isNull);

    // What the host plays before anyone joins is passed to whoever joins later.
    final state = {
      'queue': ['a', 'b'],
      'queueIndex': 1,
      'playing': true,
      'positionMs': 61000,
      'at': 1700000000000,
    };
    host.send({'type': 'listenState', 'state': state});
    phone.send({'type': 'listenJoin', 'group': groupId});
    await until(() => (groupOf(host)?['members'] as List?)?.length == 1 && phone.ofType('listenState').isNotEmpty);
    expect(phone.ofType('listenState').single['state'], state);
    final members = groupOf(phone)!['members'] as List;
    expect(members.single, {
      'accountId': guest.id,
      'username': 'guest',
      'deviceId': 'guest-phone',
      'deviceName': 'Pocket',
    });
    expect((groupOf(phone)!['host'] as Map)['deviceName'], 'Living room');

    host.send({
      'type': 'listenState',
      'state': {...state, 'playing': false},
    });
    await until(() => phone.ofType('listenState').length == 2);
    expect(stranger.ofType('listenState'), isEmpty);

    // A member's request goes to the host, named; a member can't tell what plays.
    phone.send({
      'type': 'listenCommand',
      'command': {'action': 'next'},
    });
    phone.send({'type': 'listenState', 'state': state});
    await until(() => host.ofType('listenCommand').isNotEmpty);
    expect(host.ofType('listenCommand').single, {
      'type': 'listenCommand',
      'from': 'guest',
      'command': {'action': 'next'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(phone.ofType('listenState'), hasLength(2));
  });

  test('a member leaves; the host leaving ends the group and its invites', () async {
    final host = await connect(adminToken, 'desk');
    final phone = await connect(guestToken, 'guest-phone');
    final tablet = await connect(guestToken, 'guest-tablet');
    host.send({
      'type': 'listenStart',
      'invite': [guest.id],
    });
    await until(() => invitesOf(tablet).isNotEmpty);
    final groupId = groupOf(host)!['id'] as String;
    phone.send({'type': 'listenJoin', 'group': groupId});
    tablet.send({'type': 'listenJoin', 'group': groupId});
    await until(() => (groupOf(host)?['members'] as List?)?.length == 2);

    tablet.send({'type': 'listenLeave'});
    await until(() => (groupOf(host)?['members'] as List?)?.length == 1);
    expect(groupOf(tablet), isNull);

    host.send({'type': 'listenLeave'});
    await until(() => groupOf(phone) == null && groupOf(host) == null);
    await until(() => invitesOf(tablet).isEmpty);
  });

  test("a host's dropped connection keeps the group a while; it comes back to it, or the group ends", () async {
    server.server.remote.hostGrace = const Duration(milliseconds: 600);
    var host = await connect(adminToken, 'desk');
    final phone = await connect(guestToken, 'guest-phone');
    host.send({
      'type': 'listenStart',
      'invite': [guest.id],
    });
    await until(() => invitesOf(phone).isNotEmpty);
    final groupId = groupOf(host)!['id'] as String;
    phone.send({'type': 'listenJoin', 'group': groupId});
    await until(() => (groupOf(host)?['members'] as List?)?.length == 1);

    await host.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    host = await connect(adminToken, 'desk');
    await until(() => groupOf(host)?['id'] == groupId);
    expect((groupOf(host)!['members'] as List).single['deviceId'], 'guest-phone');
    expect(groupOf(phone), isNotNull, reason: 'the member stayed in');

    await host.close();
    await until(() => groupOf(phone) == null, reason: 'the host did not come back');
    await until(() => invitesOf(phone).isEmpty);
  });

  test('two accounts, through the client: invite, join, the clock, the playback and a request', () async {
    Future<(RemoteClient, ListenTogether)> player(String username, String password, String id) async {
      final repo = testRepository();
      final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(server.root, '$id-covers'));
      final session = ServerSession(library, repo);
      final remote = RemoteClient(session);
      final together = ListenTogether(remote);
      addTearDown(() {
        together.dispose();
        remote.dispose();
        session.dispose();
      });
      library.initialize();
      session.initialize();
      await session.connect(server.baseUrl);
      expect(await session.login(username, password, false), isNull);
      remote.configure(id: id, name: id, kind: DeviceKind.phone, enabled: true);
      await until(() => remote.isConnected);
      return (remote, together);
    }

    final (_, host) = await player('owner', adminPassword, 'desk');
    final (_, member) = await player('guest', guestPassword, 'guest-phone');
    host.start([guest.id]);
    await until(() => host.isHost && member.invites.isNotEmpty);
    expect(member.invites.single.host.username, 'owner');

    member.join(member.invites.single.groupId);
    await until(() => member.isMember && host.group!.members.isNotEmpty);
    expect(host.group!.members.single.username, 'guest');
    expect(member.group!.host.deviceId, 'desk');
    await until(() => host.hasClock && member.hasClock);
    expect(member.serverNow().difference(DateTime.now().toUtc()).inMilliseconds.abs(), lessThan(1000));

    final states = <ListeningState>[];
    member.stateReceived.listen(states.add);
    host.publish(
      ListeningState(
        queue: const ['t1', 't2'],
        queueIndex: 1,
        playing: true,
        position: const Duration(seconds: 12),
        at: host.serverNow(),
      ),
    );
    await until(() => states.isNotEmpty);
    expect((states.single.trackId, states.single.playing), ('t2', true));

    final requests = <(String, RemoteAction)>[];
    host.requestReceived.listen((r) => requests.add((r.$1, r.$2.action)));
    member.request(const RemoteCommand(RemoteAction.next));
    await until(() => requests.isNotEmpty);
    expect(requests, [('guest', RemoteAction.next)]);

    var ended = 0;
    member.ended.listen((_) => ended++);
    host.leave();
    await until(() => ended == 1 && member.group == null);
  });

  test('a message of listening together that is not one closes the connection', () async {
    for (final message in [
      {'type': 'time'},
      {'type': 'listenStart', 'invite': 'everyone'},
      {
        'type': 'listenInvite',
        'invite': [3],
      },
      {'type': 'listenJoin'},
      {'type': 'listenState', 'state': 'playing'},
      {'type': 'listenCommand', 'command': 'next'},
    ]) {
      final peer = await connect(adminToken, 'desk');
      peer.send(message);
      expect(await closedWith(peer.socket), 1008, reason: '$message');
    }
  });
}
