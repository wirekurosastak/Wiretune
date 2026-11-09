// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';

import 'auth_service.dart';

/// The players of each account that are online, so that each sees what the others play and can control them
/// (docs/api.md#remote-control), and the players listening together, across accounts (docs/api.md#listen-together).
/// The hub only passes messages on; nothing is stored, and a player is forgotten the moment its connection closes (a
/// group's host gets a little while to come back).
class RemoteHub {
  /// A player has this long to introduce itself.
  static const Duration _helloTimeout = Duration(seconds: 10);

  /// More messages than this in [_rateWindow] close the connection: a player sends a few on each change, not a stream.
  static const int _rateLimit = 200;
  static const Duration _rateWindow = Duration(seconds: 10);

  final Map<String, Map<String, _Peer>> _accounts = {};
  final Set<_Peer> _peers = {};
  final Map<String, _Group> _groups = {};

  /// How long a group waits for its host to come back; tests shorten it.
  Duration hostGrace = RemoteRules.listenHostGrace;

  /// Whether the account `userId` blocked the account `otherId`: then `otherId` can't invite it to listen together.
  /// The server sets it; none are blocked without it.
  bool Function(String userId, String otherId) blocks = (_, _) => false;

  /// The players of [userId] that are online.
  int devicesOf(String userId) => _accounts[userId]?.length ?? 0;

  /// Whether [userId] may open another connection: twice as many as it may have devices (a few may still be saying
  /// hello), and no more. Asked before the upgrade, so that one too many is refused before it is a WebSocket.
  bool canJoin(String userId) => _peers.where((p) => p.userId == userId).length < 2 * RemoteRules.maxDevicesPerAccount;

  /// Takes over the WebSocket of a signed-in player; [principal]'s token decides the account, and how long it may stay.
  void join(WebSocket socket, Principal principal) {
    socket.pingInterval = RemoteRules.pingInterval;
    final peer = _Peer(socket, principal.userId, principal.username);
    _peers.add(peer);
    peer.helloTimer = Timer(_helloTimeout, () => _close(peer, 1008, 'No hello.'));
    final expires = principal.expiresAt;
    if (expires != null) {
      final left = expires.difference(DateTime.now().toUtc());
      peer.expiryTimer = Timer(left.isNegative ? Duration.zero : left, () {
        _close(peer, RemoteRules.closeSignedOut, 'The sign-in expired.');
      });
    }
    socket.listen(
      (data) => _onMessage(peer, data),
      onDone: () => _leave(peer),
      onError: (Object _) => _leave(peer),
      cancelOnError: true,
    );
  }

  /// Tells the players of [userId] that what it was recommended changed (one came or went, the bell was opened
  /// elsewhere); [except] is the one that changed it.
  void recommendationsChanged(String userId, {String? except}) {
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      if (peer.id != except) _send(peer, const {'type': 'recommendationsChanged'});
    }
  }

  /// Tells the players of [userId] that its invitations to playlists changed: one came, or went; [except] is the one
  /// that changed it.
  void playlistInvitesChanged(String userId, {String? except}) {
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      if (peer.id != except) _send(peer, const {'type': 'playlistInvitesChanged'});
    }
  }

  /// Tells the players of [userId] that its Blends changed: one was asked for, accepted or left; [except] is the one
  /// that changed it.
  void blendsChanged(String userId, {String? except}) {
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      if (peer.id != except) _send(peer, const {'type': 'blendsChanged'});
    }
  }

  /// Tells the players of [userId] that the account's favourites, playlists or hidden items changed, so that each
  /// downloads them again; [except] is the one that made the change (it already shows it).
  void dataChanged(String userId, {String? except}) {
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      if (peer.id != except) _send(peer, const {'type': 'dataChanged'});
    }
  }

  /// [userId] blocked [otherId]: the invites of [otherId]'s group are gone for it.
  void blocked(String userId, String otherId) {
    // The blocked account no longer sees this one's shared players.
    _announceDevices(otherId);
    var changed = false;
    for (final group in _groups.values) {
      if (group.hostKey.$1 == otherId) changed |= group.invited.remove(userId);
    }
    if (changed) _announceInvites(userId);
  }

  /// The account [userId] is called [username] now: its groups and its invites say so, and its own players hear of it
  /// (`accountChanged`), so each shows the new name.
  void renamed(String userId, String username) {
    final peers = _peers.where((p) => p.userId == userId).toList();
    for (final peer in peers) {
      peer.username = username;
    }
    for (final group in {for (final peer in peers) ?peer.group}) {
      _announceGroup(group);
    }
    for (final group in _groups.values) {
      if (group.hostKey.$1 == userId) group.invited.forEach(_announceInvites);
    }
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      _send(peer, const {'type': 'accountChanged'});
    }
    // The others see its shared players by its name.
    if (peers.any((p) => p.sharing != DeviceSharing.off)) _announceDevicesToAll();
  }

  /// Tells every player that the library changed (a scan found music added, changed or removed, or a new cover), so
  /// that each downloads the track list again.
  void libraryChanged() {
    for (final devices in _accounts.values) {
      for (final peer in devices.values) {
        _send(peer, const {'type': 'libraryChanged'});
      }
    }
  }

  /// Ends the connections of an account whose tokens no longer stand: it was deleted, or its password changed.
  void disconnectAccount(String userId, String reason) {
    for (final peer in _peers.where((p) => p.userId == userId).toList()) {
      _close(peer, RemoteRules.closeSignedOut, reason);
    }
  }

  /// Ends every connection (the server is stopping).
  Future<void> close() async {
    final peers = _peers.toList();
    for (final peer in peers) {
      _close(peer, WebSocketStatus.goingAway, 'The server is stopping.');
    }
    for (final group in _groups.values) {
      group.hostAway?.cancel();
    }
    _groups.clear();
    // A connection that ends in an error has ended too: that is all the server waits for.
    await Future.wait([for (final peer in peers) peer.socket.done.catchError((Object _) => null)]);
  }

  void _onMessage(_Peer peer, Object? data) {
    if (!peer.withinRate(_rateLimit, _rateWindow)) return _close(peer, 1008, 'Too many messages.');
    if (data is! String) return _close(peer, 1003, 'Text messages only.');
    if (data.length > RemoteRules.maxMessageLength) return _close(peer, 1009, 'The message is too long.');

    Object? message;
    try {
      message = jsonDecode(data);
    } on FormatException {
      return _close(peer, 1008, 'The message is not JSON.');
    }
    if (message is! Map) return _close(peer, 1008, 'The message is not a JSON object.');

    final type = message['type'];
    if (peer.id == null && type != 'hello') return _close(peer, 1008, 'Say hello first.');
    switch (type) {
      case 'hello':
        _hello(peer, message['device']);
      case 'state':
        final state = message['state'];
        if (state is! Map) return _close(peer, 1008, 'A state must be a JSON object.');
        peer.state = state;
        _sendToViewers(peer, {'type': 'state', 'device': peer.id, 'state': state});
      case 'command':
        final to = message['to'];
        final command = message['command'];
        if (to is! String || command is! Map) return _close(peer, 1008, 'A command needs "to" and "command".');
        // To another player of the account, or one of another account that lets others play on it (and didn't block
        // this one's); one that has just gone is no error.
        final target =
            _accounts[peer.userId]?[to] ??
            _peers.where((p) => p.id == to && p.userId != peer.userId && _sees(peer, p)).firstOrNull;
        if (target != null && target != peer) {
          _send(target, {
            'type': 'command',
            'from': peer.id,
            if (target.userId != peer.userId) 'account': {'id': peer.userId, 'username': peer.username},
            'command': command,
          });
        }
      case 'time':
        // The server's clock, for the players listening together to count on one.
        final sent = message['t'];
        if (sent is! num) return _close(peer, 1008, 'A time needs "t".');
        _send(peer, {'type': 'time', 't': sent, 'server': DateTime.now().millisecondsSinceEpoch});
      case 'listenStart' || 'listenInvite':
        final invite = _accountIds(message['invite']);
        if (invite == null) return _close(peer, 1008, 'An invite is a list of account IDs.');
        type == 'listenStart' ? _startGroup(peer, invite) : _invite(peer, invite);
      case 'listenJoin':
        final id = message['group'];
        if (id is! String) return _close(peer, 1008, 'A join needs "group".');
        _joinGroup(peer, id);
      case 'listenLeave':
        _leaveGroup(peer);
      case 'listenState':
        final state = message['state'];
        if (state is! Map) return _close(peer, 1008, 'A state must be a JSON object.');
        final group = peer.group;
        if (group == null || group.host != peer) return; // only the host tells what plays; a late one is no error
        group.state = state;
        final text = jsonEncode({'type': 'listenState', 'state': state});
        for (final member in group.members) {
          _sendText(member, text);
        }
      case 'listenCommand':
        final command = message['command'];
        if (command is! Map) return _close(peer, 1008, 'A command must be a JSON object.');
        final group = peer.group;
        final host = group?.host;
        if (group == null || host == null || host == peer) return;
        _send(host, {'type': 'listenCommand', 'from': peer.username, 'command': command});
      default:
        return _close(peer, 1008, 'Unknown message type.');
    }
  }

  /// Registers the player, or renames it when it says hello again.
  void _hello(_Peer peer, Object? device) {
    if (device is! Map) return _close(peer, 1008, 'A hello needs a device.');
    final id = device['id'];
    if (id is! String || UserDataRules.validateId(id) != null) return _close(peer, 1008, 'The device ID is not valid.');
    if (peer.id != null && peer.id != id) return _close(peer, 1008, 'A connection keeps its device ID.');

    if (peer.id == null) {
      final previous = _accounts[peer.userId]?[id];
      if (previous != null) {
        // The same device connecting again (after a network change, or a restart) takes the place of its old connection.
        _close(previous, RemoteRules.closeReplaced, 'This device connected again.');
      } else if (devicesOf(peer.userId) >= RemoteRules.maxDevicesPerAccount) {
        return _close(peer, RemoteRules.closeTooManyDevices, 'Too many devices are connected to this account.');
      }
      peer
        ..id = id
        ..helloTimer?.cancel();
      _accounts.putIfAbsent(peer.userId, () => {})[id] = peer;
    }
    final shared = peer.sharing != DeviceSharing.off;
    peer
      ..name = RemoteRules.cleanName(device['name'])
      ..kind = DeviceKind.parse(device['kind'])
      ..sharing = DeviceSharing.parse(device['sharing']);
    WiretuneLog.debug('Remote', "Device '${peer.name}' (${peer.kind.name}) is online for account ${peer.userId}.");

    // A device the other accounts see (or saw) changes their lists too.
    shared || peer.sharing != DeviceSharing.off ? _announceDevicesToAll() : _announceDevices(peer.userId);
    for (final other in _peers) {
      final state = other.state;
      if (other != peer && state != null && _sees(peer, other)) {
        _send(peer, {'type': 'state', 'device': other.id, 'state': state});
      }
    }
    // A host that dropped off takes its group back; anyone invited hears of the open invites.
    final hosted = _groups.values.where((g) => g.host == null && g.hostKey == (peer.userId, id)).firstOrNull;
    if (hosted != null && peer.group == null) {
      hosted
        ..hostAway?.cancel()
        ..hostAway = null
        ..host = peer;
      peer.group = hosted;
      _announceGroup(hosted);
    } else if (peer.group == null) {
      // A player that was in a group before its connection dropped learns that it no longer is.
      _send(peer, const {'type': 'listen', 'group': null});
    }
    _sendInvites(peer);
  }

  void _leave(_Peer peer) {
    if (!_peers.remove(peer)) return;
    peer.helloTimer?.cancel();
    peer.expiryTimer?.cancel();
    final group = peer.group;
    if (group != null && group.host == peer) {
      // The host's connection may only have dropped (a phone between networks): its group waits for it a while, the
      // others playing on meanwhile.
      peer.group = null;
      group
        ..host = null
        ..hostAway = Timer(hostGrace, () => _endGroup(group));
    } else if (group != null) {
      _leaveGroup(peer);
    }
    final devices = _accounts[peer.userId];
    if (devices == null || devices[peer.id] != peer) return; // never registered, or replaced
    devices.remove(peer.id);
    if (devices.isEmpty) _accounts.remove(peer.userId);
    peer.sharing != DeviceSharing.off ? _announceDevicesToAll() : _announceDevices(peer.userId);
  }

  /// Whether [viewer] sees [device]: a player of its own account, or another account's that lets others play on it,
  /// unless that account blocked the viewer's.
  bool _sees(_Peer viewer, _Peer device) =>
      device.userId == viewer.userId || (device.sharing != DeviceSharing.off && !blocks(device.userId, viewer.userId));

  /// Tells each player of the account which others it sees are online.
  void _announceDevices(String userId) {
    for (final peer in _accounts[userId]?.values.toList() ?? const <_Peer>[]) {
      _sendDevices(peer);
    }
  }

  /// [_announceDevices] for every account: a device that others see came, went or changed.
  void _announceDevicesToAll() {
    for (final devices in _accounts.values.toList()) {
      for (final peer in devices.values.toList()) {
        _sendDevices(peer);
      }
    }
  }

  /// The players [peer] sees ([_sees]), another account's with whose it is.
  void _sendDevices(_Peer peer) => _send(peer, {
    'type': 'devices',
    'devices': [
      for (final devices in _accounts.values)
        for (final other in devices.values)
          if (other != peer && _sees(peer, other))
            {
              'id': other.id,
              'name': other.name,
              'kind': other.kind.name,
              if (other.userId != peer.userId) 'account': {'id': other.userId, 'username': other.username},
            },
    ],
  });

  /// Sends [message] about [from] to every other player that sees it.
  void _sendToViewers(_Peer from, Map<String, Object?> message) {
    final text = jsonEncode(message);
    for (final devices in _accounts.values) {
      for (final peer in devices.values) {
        if (peer != from && _sees(peer, from)) _sendText(peer, text);
      }
    }
  }

  // ── Listening together ───────────────────────────────────────────────────────────────────────────

  /// [value] as the account IDs of an invite, or null when it is not one.
  static Set<String>? _accountIds(Object? value) {
    if (value is! List || value.length > RemoteRules.maxListenInvites) return null;
    final ids = <String>{};
    for (final id in value) {
      if (id is! String || UserDataRules.validateId(id) != null) return null;
      ids.add(id);
    }
    return ids;
  }

  /// [host] starts a group and invites the accounts [invite]; it leaves the group it was in. A host that starts again
  /// only invites.
  void _startGroup(_Peer host, Set<String> invite) {
    if (host.id == null) return;
    final current = host.group;
    if (current != null && current.host == host) return _invite(host, invite);
    if (current != null) _leaveGroup(host);
    final group = _Group(newId(), host, (host.userId, host.id!));
    _groups[group.id] = group;
    host.group = group;
    _announceGroup(group);
    _invite(host, invite);
  }

  void _invite(_Peer host, Set<String> invite) {
    final group = host.group;
    if (group == null || group.host != host) return;
    // An account that blocked the host never hears of the invite, and the host isn't told.
    final added = invite
        .where((id) => id != host.userId && !group.invited.contains(id) && !blocks(id, host.userId))
        .toList();
    final room = RemoteRules.maxListenInvites - group.invited.length;
    if (room <= 0) return;
    group.invited.addAll(added.take(room));
    added.take(room).forEach(_announceInvites);
  }

  /// [peer] joins the group [id] when its account was invited; it leaves the one it was in. A group that is gone (or
  /// full) says so.
  void _joinGroup(_Peer peer, String id) {
    final group = _groups[id];
    if (group != null && group.members.contains(peer)) return;
    if (group == null ||
        !group.invited.contains(peer.userId) ||
        group.host == peer ||
        group.members.length >= RemoteRules.maxListeners) {
      return _send(peer, const {'type': 'listen', 'group': null});
    }
    if (peer.group != null) _leaveGroup(peer);
    group.members.add(peer);
    peer.group = group;
    _announceGroup(group);
    final state = group.state;
    if (state != null) _send(peer, {'type': 'listenState', 'state': state});
  }

  /// [peer] leaves its group; when it is the host, the group ends.
  void _leaveGroup(_Peer peer) {
    final group = peer.group;
    if (group == null) return;
    if (group.host == peer) return _endGroup(group);
    group.members.remove(peer);
    peer.group = null;
    _send(peer, const {'type': 'listen', 'group': null});
    _announceGroup(group);
  }

  void _endGroup(_Group group) {
    if (_groups.remove(group.id) == null) return;
    group.hostAway?.cancel();
    for (final peer in [?group.host, ...group.members]) {
      peer.group = null;
      _send(peer, const {'type': 'listen', 'group': null});
    }
    group.invited.forEach(_announceInvites);
  }

  /// Tells everyone in [group] who is in it.
  void _announceGroup(_Group group) {
    final host = group.host;
    if (host == null) return;
    Map<String, Object?> who(_Peer peer) => {
      'accountId': peer.userId,
      'username': peer.username,
      'deviceId': peer.id,
      'deviceName': peer.name,
    };
    final text = jsonEncode({
      'type': 'listen',
      'group': {
        'id': group.id,
        'host': who(host),
        'members': [for (final member in group.members) who(member)],
      },
    });
    for (final peer in [host, ...group.members]) {
      _sendText(peer, text);
    }
  }

  /// Tells the players of [accountId] which groups invite it.
  void _announceInvites(String accountId) {
    for (final peer in _accounts[accountId]?.values ?? const <_Peer>[]) {
      _sendInvites(peer);
    }
  }

  void _sendInvites(_Peer peer) {
    final invites = [
      for (final group in _groups.values)
        if (group.invited.contains(peer.userId) && group.host != null)
          {
            'group': group.id,
            'host': {'id': group.host!.userId, 'username': group.host!.username},
          },
    ];
    _send(peer, {'type': 'listenInvites', 'invites': invites});
  }

  void _send(_Peer peer, Map<String, Object?> message) => _sendText(peer, jsonEncode(message));

  void _sendText(_Peer peer, String text) {
    try {
      peer.socket.add(text);
    } catch (_) {
      // Closing already; its done handler removes it.
    }
  }

  void _close(_Peer peer, int code, String reason) {
    if (code != WebSocketStatus.goingAway) WiretuneLog.debug('Remote', 'Closing a connection ($code): $reason');
    _leave(peer);
    // Best effort: the other side may be gone already.
    unawaited(peer.socket.close(code, reason).catchError((Object _) => null));
  }
}

/// Players listening together: the host's music plays on the members' players too.
class _Group {
  _Group(this.id, this.host, this.hostKey);

  final String id;

  /// Null while its connection is gone, for [hostAway].
  _Peer? host;

  /// The host's account and device, by which it takes the group back.
  final (String, String) hostKey;
  Timer? hostAway;
  final Set<_Peer> members = {};
  final Set<String> invited = {};

  /// What the host last said it plays, for a member that joins later.
  Map<Object?, Object?>? state;
}

class _Peer {
  _Peer(this.socket, this.userId, this.username);

  final WebSocket socket;
  final String userId;

  /// The account's name; it changes when the account is renamed ([RemoteHub.renamed]).
  String username;

  /// The group it hosts or listens in.
  _Group? group;

  /// Set by its hello.
  String? id;
  String name = '';
  DeviceKind kind = DeviceKind.desktop;

  /// Whether the other accounts may play on it, as its hello said.
  DeviceSharing sharing = DeviceSharing.off;

  /// The last state it sent, passed to players that connect later.
  Map<Object?, Object?>? state;
  Timer? helloTimer;
  Timer? expiryTimer;

  DateTime _windowStart = DateTime.now();
  int _count = 0;

  bool withinRate(int limit, Duration window) {
    final now = DateTime.now();
    if (now.difference(_windowStart) >= window) {
      _windowStart = now;
      _count = 0;
    }
    return ++_count <= limit;
  }
}
