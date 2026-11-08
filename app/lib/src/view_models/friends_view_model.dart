// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// What the bell holds ("From friends"): invites to listen together and the music the other accounts of the server
/// recommended; and recommending music to them.
class FriendsViewModel extends ChangeNotifier {
  FriendsViewModel(this._session, this._library, this.recommendations, this.together, {required this.notify}) {
    _unsubscribers.addAll([
      recommendations.changed.listen((_) => notifyListeners()),
      together.changed.listen((_) => notifyListeners()),
      _session.stateChanged.listen((_) => notifyListeners()),
    ]);
  }

  final ServerSession _session;
  final LibraryService _library;
  final Recommendations recommendations;
  final ListenTogether together;

  /// Shows a notice, with its Undo when given.
  final void Function(String message, {bool isError, VoidCallback? undo}) notify;
  final List<void Function()> _unsubscribers = [];

  /// The bell is there while signed in to a server: the friends are its other accounts.
  bool get isAvailable => _session.isLoggedIn;

  /// What the bell's count says: the recommendations that came since it was opened, and the open invites.
  int get unseenCount => recommendations.unseenCount + invites.length;

  List<Recommendation> get items => recommendations.items;

  /// The invites to listen together, but to the group this player is in already, and the ones dismissed here.
  List<ListeningInvite> get invites => [
    for (final invite in together.invites)
      if (invite.groupId != together.group?.id && !_dismissedInvites.contains(invite.groupId)) invite,
  ];
  final Set<String> _dismissedInvites = {};

  void join(ListeningInvite invite) => together.join(invite.groupId);

  /// Not joining: the invite leaves the bell (on this player).
  void dismissInvite(ListeningInvite invite) {
    _dismissedInvites.add(invite.groupId);
    notifyListeners();
  }

  /// The bell was opened.
  void opened() => unawaited(recommendations.markSeen());

  void dismiss(Recommendation recommendation) => unawaited(recommendations.dismiss(recommendation));

  Track? trackOf(Recommendation r) =>
      r.kind == RecommendationKind.track ? _library.resolveTracks([r.itemId]).firstOrNull : null;

  Album? albumOf(Recommendation r) => r.kind == RecommendationKind.album ? _library.getAlbum(r.itemId) : null;

  Artist? artistOf(Recommendation r) => r.kind == RecommendationKind.artist ? _library.getArtist(r.itemId) : null;

  /// The other accounts, the people music can be recommended to (but the ones this account blocked). Throws when the
  /// server can't be reached. A server from before blocking (it has no list of them) blocks none.
  Future<List<AccountInfo>> otherAccounts() async {
    final (others, blocked) = await (
      recommendations.otherAccounts(),
      _session.getBlocked().catchError((Object _) => const <AccountInfo>[]),
    ).wait;
    final ids = {for (final account in blocked) account.id};
    return [
      for (final account in others)
        if (!ids.contains(account.id)) account,
    ];
  }

  // ── Blocking ───────────────────────────────────────────────────────────────────────────────────

  /// The other accounts, for Settings → Friends, and which of them this account blocked; empty until [loadFriends].
  List<AccountInfo> friends = const [];
  Set<String> blocked = const {};

  /// What went wrong loading or changing them; empty when nothing did.
  String friendsError = '';

  /// Loads [friends] and [blocked].
  Future<void> loadFriends() async {
    if (!isAvailable) return;
    try {
      final (others, blockedAccounts) = await (recommendations.otherAccounts(), _session.getBlocked()).wait;
      friends = others;
      blocked = {for (final account in blockedAccounts) account.id};
      friendsError = '';
    } catch (e) {
      friendsError = Localizer.format('FriendsLoadError', ['$e']);
    }
    notifyListeners();
  }

  /// Blocks [account] (its recommendations and invites stop reaching this one; it isn't told), or unblocks it. Shown at
  /// once; a refusal puts it back and says why.
  Future<void> setBlocked(AccountInfo account, bool block) async {
    final before = blocked;
    blocked = {...before.where((id) => id != account.id), if (block) account.id};
    notifyListeners();
    try {
      await _session.setBlocked(account.id, block);
      friendsError = '';
      // What it recommended goes with the block.
      if (block) unawaited(recommendations.refresh());
    } catch (e) {
      blocked = before;
      friendsError = Localizer.format('ChangeRefused', ['$e']);
    }
    notifyListeners();
  }

  // ── Recommending ───────────────────────────────────────────────────────────────────────────────

  /// The ID the server knows [track] by; null for a file only this device has.
  String? serverIdOf(Track track) {
    final id = _library.sharedId(track);
    return track.isLocal && id == track.id ? null : id;
  }

  /// Whether [tracks] (a track, an album's, an artist's) are on the server, so that its other accounts have them.
  bool canRecommend(Iterable<Track> tracks) => isAvailable && tracks.any((t) => serverIdOf(t) != null);

  /// Recommends [itemId] to [to], with [note]; the notice has an Undo.
  Future<void> recommend(RecommendationKind kind, String itemId, List<AccountInfo> to, {String note = ''}) async {
    try {
      final undo = await recommendations.send(kind, itemId, [for (final account in to) account.id], note);
      final who = to.length == 1 ? to.single.username : Localizer.format('PeopleCount', [to.length]);
      notify(
        Localizer.format('RecommendedTo', [who]),
        undo: () => unawaited(
          undo().catchError((Object e) => notify(Localizer.format('ChangeRefused', ['$e']), isError: true)),
        ),
      );
    } catch (e) {
      notify(Localizer.format('RecommendFailed', ['$e']), isError: true);
    }
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    recommendations.dispose();
    super.dispose();
  }
}
