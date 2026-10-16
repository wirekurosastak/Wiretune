// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';

import 'auth_service.dart';

/// The players of each account that are online, so that each sees what the others play and can control them
/// (docs/api.md#remote-control). The hub only passes messages on, between the players of one account; nothing is
/// stored, and a player is forgotten the moment its connection closes.
class RemoteHub {
  /// A player has this long to introduce itself.
  static const Duration helloTimeout = Duration(seconds: 10);

  /// More messages than this in [_rateWindow] close the connection: a player sends a few on each change, not a stream.
  static const int _rateLimit = 200;
  static const Duration _rateWindow = Duration(seconds: 10);

  final Map<String, Map<String, _Peer>> _accounts = {};
  final Set<_Peer> _peers = {};

  /// The players of [userId] that are online.
  int devicesOf(String userId) => _accounts[userId]?.length ?? 0;

  /// Whether [userId] may open another connection: twice as many as it may have devices (a few may still be saying
  /// hello), and no more. Asked before the upgrade, so that one too many is refused before it is a WebSocket.
  bool canJoin(String userId) => _peers.where((p) => p.userId == userId).length < 2 * RemoteRules.maxDevicesPerAccount;

  /// Takes over the WebSocket of a signed-in player; [principal]'s token decides the account, and how long it may stay.
  void join(WebSocket socket, Principal principal) {
    socket.pingInterval = RemoteRules.pingInterval;
    final peer = _Peer(socket, principal.userId);
    _peers.add(peer);
    peer.helloTimer = Timer(helloTimeout, () => _close(peer, 1008, 'No hello.'));
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

  /// Tells the players of [userId] that the account's favourites, playlists or hidden items changed, so that each
  /// downloads them again; [except] is the one that made the change (it already shows it).
  void dataChanged(String userId, {String? except}) {
    for (final peer in _accounts[userId]?.values ?? const <_Peer>[]) {
      if (peer.id != except) _send(peer, const {'type': 'dataChanged'});
    }
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
        _sendToOthers(peer, {'type': 'state', 'device': peer.id, 'state': state});
      case 'command':
        final to = message['to'];
        final command = message['command'];
        if (to is! String || command is! Map) return _close(peer, 1008, 'A command needs "to" and "command".');
        // Only to another player of the same account; one that has just gone is no error.
        final target = _accounts[peer.userId]?[to];
        if (target != null && target != peer) {
          _send(target, {'type': 'command', 'from': peer.id, 'command': command});
        }
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
    peer
      ..name = RemoteRules.cleanName(device['name'])
      ..kind = DeviceKind.parse(device['kind']);
    WiretuneLog.debug('Remote', "Device '${peer.name}' (${peer.kind.name}) is online for account ${peer.userId}.");

    _announceDevices(peer.userId);
    for (final other in _accounts[peer.userId]!.values) {
      final state = other.state;
      if (other != peer && state != null) _send(peer, {'type': 'state', 'device': other.id, 'state': state});
    }
  }

  void _leave(_Peer peer) {
    if (!_peers.remove(peer)) return;
    peer.helloTimer?.cancel();
    peer.expiryTimer?.cancel();
    final devices = _accounts[peer.userId];
    if (devices == null || devices[peer.id] != peer) return; // never registered, or replaced
    devices.remove(peer.id);
    if (devices.isEmpty) {
      _accounts.remove(peer.userId);
    } else {
      _announceDevices(peer.userId);
    }
  }

  /// Tells each player of the account which others are online.
  void _announceDevices(String userId) {
    final devices = _accounts[userId]?.values.toList() ?? const <_Peer>[];
    for (final peer in devices) {
      _send(peer, {
        'type': 'devices',
        'devices': [
          for (final other in devices)
            if (other != peer) {'id': other.id, 'name': other.name, 'kind': other.kind.name},
        ],
      });
    }
  }

  void _sendToOthers(_Peer from, Map<String, Object?> message) {
    final text = jsonEncode(message);
    for (final peer in _accounts[from.userId]?.values ?? const <_Peer>[]) {
      if (peer != from) _sendText(peer, text);
    }
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
    unawaited(peer.socket.close(code, reason).catchError((Object _) => null));
  }
}

class _Peer {
  _Peer(this.socket, this.userId);

  final WebSocket socket;
  final String userId;

  /// Set by its hello.
  String? id;
  String name = '';
  DeviceKind kind = DeviceKind.desktop;

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
