// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import '../models/protocol.dart';
import '../util/event.dart';
import 'remote_client.dart';
import 'server_session.dart';
import 'wiretune_log.dart';

/// The invitations to playlists other accounts share with this one (the bell), kept up to date: downloaded when the
/// session signs in, again whenever the server says they changed, and forgotten when the session signs out.
class PlaylistInvites {
  PlaylistInvites(this._session, RemoteClient remote) {
    _unsubscribers.addAll([
      _session.stateChanged.listen((_) => _sessionChanged()),
      remote.playlistInvitesChanged.listen((_) => unawaited(refresh())),
    ]);
    _sessionChanged();
  }

  final ServerSession _session;
  final List<void Function()> _unsubscribers = [];

  /// The account [items] belong to.
  String? _account;

  /// Raised when [items] changed.
  final Event<void> changed = Event<void>();

  /// The newest first.
  List<PlaylistInvite> items = const [];

  void _sessionChanged() {
    final account = _session.isLoggedIn ? _session.currentUser?.id : null;
    if (account == _account) return;
    _account = account;
    items = const [];
    changed.emit(null);
    if (account != null) unawaited(refresh());
  }

  /// Downloads them again; a failure leaves what was shown.
  Future<void> refresh() async {
    final account = _account;
    if (account == null) return;
    try {
      final invites = await _session.getPlaylistInvites();
      if (_account != account) return; // signed out or in as another meanwhile
      items = invites;
      changed.emit(null);
    } catch (e) {
      WiretuneLog.debug('PlaylistInvites', 'Could not download the invitations to playlists: $e');
    }
  }

  /// Joins [invite]'s playlist ([join]: it is among the account's playlists from now on) or turns it down; it leaves
  /// the list at once. Throws when the server can't be reached or refuses it, and the invitation comes back.
  Future<void> answer(PlaylistInvite invite, {required bool join}) async {
    items = [
      for (final i in items)
        if (i.playlistId != invite.playlistId) i,
    ];
    changed.emit(null);
    try {
      await _session.answerPlaylistInvite(invite.playlistId, join);
    } catch (_) {
      unawaited(refresh());
      rethrow;
    }
    if (join) await _session.refreshUserData();
  }

  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
  }
}
