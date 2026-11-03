// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import '../models/protocol.dart';
import '../models/remote.dart';
import '../util/event.dart';
import 'remote_client.dart';

/// Listening together (docs/api.md#listen-together), through the remote-control connection: the group this player
/// hosts or listens in, the open invites of its account, and one clock with the server, by which the members follow
/// the host's position. The player does the playing ([ListeningState] in, [publish] out).
class ListenTogether {
  ListenTogether(this._remote) : _connected = _remote.isConnected {
    _unsubscribers.addAll([
      _remote.listenMessage.listen(_onMessage),
      _remote.devicesChanged.listen((_) => _connectionChanged()),
    ]);
  }

  /// How often the clock is set again while in a group, and how many times it is asked each time (the quickest
  /// answer counts). Tests shorten them.
  static Duration clockInterval = const Duration(minutes: 1);
  static Duration clockAskInterval = const Duration(milliseconds: 150);
  static const int _clockAsks = 5;

  final RemoteClient _remote;
  final List<void Function()> _unsubscribers = [];

  ListeningGroup? _group;
  List<ListeningInvite> _invites = const [];
  bool _connected;
  bool _leaving = false;

  /// The group this player listened in when its connection dropped: it joins again once it is back.
  String? _rejoin;

  /// Raised when the group or the invites change.
  final Event<void> changed = Event<void>();

  /// The group this player was in ended, or it was turned away: not when it left itself.
  final Event<void> ended = Event<void>();

  /// What the host plays, for a member to follow.
  final Event<ListeningState> stateReceived = Event();

  /// A member's request (next, a seek, tracks to queue), for the host, with the member's account name.
  final Event<(String from, RemoteCommand command)> requestReceived = Event();

  ListeningGroup? get group => _group;
  List<ListeningInvite> get invites => _invites;
  bool get isHost => _group != null && _group!.host.deviceId == _remote.deviceId;
  bool get isMember => _group != null && !isHost;

  /// Whether a group can be started or joined: the connection is there.
  bool get isAvailable => _remote.isConnected;

  // ── The clock ──────────────────────────────────────────────────────────────────────────────────

  /// The server's clock minus this one's, from the quickest of the last answers.
  Duration _offset = Duration.zero;
  int? _quickest; // the round trip of the answer [_offset] came from, in ms
  Timer? _clockTimer;
  Timer? _askTimer;

  /// The time by the server's clock.
  DateTime serverNow() => DateTime.now().toUtc().add(_offset);

  /// Whether the server has told its time since this player started or joined a group: until then [serverNow] is
  /// this player's own clock.
  bool get hasClock => _clockSet;
  bool _clockSet = false;

  void _setClock() {
    _askTimer?.cancel();
    _quickest = null;
    var asked = 0;
    void ask() => _remote.sendListen({'type': 'time', 't': DateTime.now().millisecondsSinceEpoch});
    ask();
    _askTimer = Timer.periodic(clockAskInterval, (timer) {
      ask();
      if (++asked >= _clockAsks - 1) timer.cancel();
    });
  }

  void _onTime(Map<Object?, Object?> message) {
    final (sent, server) = (message['t'], message['server']);
    if (sent is! num || server is! num) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final roundTrip = now - sent.toInt();
    if (roundTrip < 0 || (_quickest != null && roundTrip >= _quickest!)) return;
    _quickest = roundTrip;
    _clockSet = true;
    // The server read its clock about halfway through the round trip.
    _offset = Duration(milliseconds: server.toInt() - (sent.toInt() + roundTrip ~/ 2));
  }

  void _keepClock(bool on) {
    if (!on) {
      _clockSet = false;
      _clockTimer?.cancel();
      _clockTimer = null;
      _askTimer?.cancel();
      _askTimer = null;
      return;
    }
    if (_clockTimer != null) return;
    _setClock();
    _clockTimer = Timer.periodic(clockInterval, (_) => _setClock());
  }

  // ── Starting, joining, leaving ─────────────────────────────────────────────────────────────────

  /// Hosts a group, inviting the accounts [accountIds]; a host only invites them too.
  void start(Iterable<String> accountIds) {
    _keepClock(true);
    _remote.sendListen({'type': 'listenStart', 'invite': accountIds.toList()});
  }

  void invite(Iterable<String> accountIds) =>
      _remote.sendListen({'type': 'listenInvite', 'invite': accountIds.toList()});

  /// Listens in the group [groupId] (one this player's account was invited to).
  void join(String groupId) {
    _keepClock(true);
    _remote.sendListen({'type': 'listenJoin', 'group': groupId});
  }

  /// Leaves the group; the host's leaving ends it for everyone.
  void leave() {
    if (_group == null) return;
    _leaving = true;
    _rejoin = null;
    _remote.sendListen({'type': 'listenLeave'});
    _setGroup(null);
  }

  /// The host tells the members what it plays.
  void publish(ListeningState state) {
    if (isHost) _remote.sendListen({'type': 'listenState', 'state': state.toJson()});
  }

  /// A member asks the host for [command] (next, previous, a seek, tracks to queue).
  void request(RemoteCommand command) {
    if (isMember) _remote.sendListen({'type': 'listenCommand', 'command': command.toJson()});
  }

  // ── Messages ───────────────────────────────────────────────────────────────────────────────────

  void _onMessage(Map<Object?, Object?> message) {
    _connected = true; // a message came: connected, whether or not the device list said so yet
    switch (message['type']) {
      case 'time':
        _onTime(message);
      case 'listen':
        final group = ListeningGroup.fromJson(message['group']);
        final rejoin = _rejoin;
        if (group == null && rejoin != null) {
          // Back after a dropped connection: the server forgot this member, which asks to be let in again.
          _rejoin = null;
          return join(rejoin);
        }
        _rejoin = null;
        final had = _group != null;
        _setGroup(group);
        if (group == null && had && !_leaving) ended.emit(null);
        if (group == null) _leaving = false;
      case 'listenInvites':
        final list = message['invites'];
        _invites = [
          if (list is List)
            for (final invite in list)
              if (invite case {
                'group': final String id,
                'host': {'id': final String accountId, 'username': final String name},
              })
                ListeningInvite(id, AccountInfo(accountId, name)),
        ];
        changed.emit(null);
      case 'listenState':
        final state = ListeningState.fromJson(message['state']);
        if (state != null && isMember) stateReceived.emit(state);
      case 'listenCommand':
        final command = RemoteCommand.fromJson(message['command']);
        final from = message['from'];
        if (command != null && from is String && isHost) requestReceived.emit((from, command));
    }
  }

  void _setGroup(ListeningGroup? group) {
    _group = group;
    _keepClock(group != null);
    changed.emit(null);
  }

  void _connectionChanged() {
    final connected = _remote.isConnected;
    if (connected == _connected) return;
    _connected = connected;
    if (!connected) {
      // The server forgets a member whose connection dropped (a host it waits for a while): a member joins again.
      _rejoin = isMember ? _group!.id : null;
      _invites = const [];
      _keepClock(false);
    }
    changed.emit(null);
  }

  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    _keepClock(false);
  }
}
