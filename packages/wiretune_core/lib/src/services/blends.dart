// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import '../models/protocol.dart';
import '../util/event.dart';
import 'remote_client.dart';
import 'server_session.dart';
import 'wiretune_log.dart';

/// The account's Blends (playlists the server mixes from its listening and a friend's), kept up to date: downloaded when
/// the session signs in, again whenever the server says they changed or this account's own data did (what it hides and
/// loves changes the mix), and forgotten when the session signs out.
class Blends {
  Blends(this._session, RemoteClient remote) {
    _unsubscribers.addAll([
      _session.stateChanged.listen((_) => _sessionChanged()),
      remote.blendsChanged.listen((_) => unawaited(refresh())),
      remote.accountDataChanged.listen((_) => unawaited(refresh())),
    ]);
    _sessionChanged();
  }

  final ServerSession _session;
  final List<void Function()> _unsubscribers = [];

  /// The account [items] belong to.
  String? _account;

  /// Raised when [items] changed.
  final Event<void> changed = Event<void>();

  /// By the other account's name: the active ones, the invitations this account got, and the ones it sent.
  List<Blend> items = const [];

  List<Blend> get active => [
    for (final blend in items)
      if (blend.state == BlendState.active) blend,
  ];

  /// The invitations this account got and hasn't answered.
  List<Blend> get invitations => [
    for (final blend in items)
      if (blend.state == BlendState.invited) blend,
  ];

  void _sessionChanged() {
    final account = _session.isLoggedIn ? _session.currentUser?.id : null;
    if (account == _account) return;
    _account = account;
    items = const [];
    changed.emit(null);
    if (account != null) unawaited(refresh());
  }

  /// Downloads them again (their mixes follow the listening); a failure leaves what was shown.
  Future<void> refresh() async {
    final account = _account;
    if (account == null) return;
    try {
      final blends = await _session.getBlends();
      if (_account != account) return; // signed out or in as another meanwhile
      items = blends;
      changed.emit(null);
    } catch (e) {
      WiretuneLog.debug('Blends', 'Could not download the Blends: $e');
    }
  }

  /// Invites [account] to a Blend, or accepts its invitation; the Blend as it now stands. Throws when the server can't
  /// be reached or refuses it.
  Future<Blend> invite(AccountInfo account) async {
    final blend = await _session.inviteToBlend(account.id);
    items = [
      for (final b in items)
        if (b.id != blend.id) b,
      blend,
    ]..sort((a, b) => a.other.username.toLowerCase().compareTo(b.other.username.toLowerCase()));
    changed.emit(null);
    return blend;
  }

  /// Leaves [blend] (or turns down or takes back its invitation), here at once and then on the server; a server that
  /// can't be reached brings it back with the next download.
  Future<void> leave(Blend blend) async {
    items = [
      for (final b in items)
        if (b.id != blend.id) b,
    ];
    changed.emit(null);
    try {
      await _session.leaveBlend(blend.id);
    } catch (e) {
      WiretuneLog.debug('Blends', 'Could not leave a Blend: $e');
      unawaited(refresh());
    }
  }

  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
  }
}
