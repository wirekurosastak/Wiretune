// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// What the bell holds ("From friends"): invites to listen together and to Blends, and the music the other accounts of
/// the server recommended; and recommending music to them, and inviting them to Blends.
class FriendsViewModel extends ChangeNotifier {
  FriendsViewModel(
    this._session,
    this._library,
    this.recommendations,
    this.together,
    this.blends,
    this.playlistInvites, {
    required this.notify,
  }) {
    _unsubscribers.addAll([
      playlistInvites.changed.listen((_) => notifyListeners()),
      recommendations.changed.listen((_) => notifyListeners()),
      together.changed.listen((_) => notifyListeners()),
      blends.changed.listen((_) => notifyListeners()),
      _session.stateChanged.listen((_) => notifyListeners()),
    ]);
  }

  final ServerSession _session;
  final LibraryService _library;
  final Recommendations recommendations;
  final ListenTogether together;
  final Blends blends;
  final PlaylistInvites playlistInvites;

  /// Shows a notice, with its Undo when given.
  final void Function(String message, {bool isError, VoidCallback? undo}) notify;
  final List<void Function()> _unsubscribers = [];

  /// The bell is there while signed in to a server: the friends are its other accounts.
  bool get isAvailable => _session.isLoggedIn;

  /// What the bell's count says: the recommendations that came since it was opened, and the open invites (to listen
  /// together and to Blends).
  int get unseenCount =>
      recommendations.unseenCount + invites.length + blendInvitations.length + playlistInvites.items.length;

  /// Joins a playlist a friend shares ([join]), or turns it down.
  Future<void> answerPlaylistInvite(PlaylistInvite invite, {required bool join}) async {
    try {
      await playlistInvites.answer(invite, join: join);
      if (join) notify(Localizer.format('PlaylistJoined', [invite.name]));
    } catch (e) {
      notify(Localizer.format('ChangeRefused', ['$e']), isError: true);
    }
  }

  /// Shares [playlist] with exactly [chosen]: invites the ones it isn't shared with yet, and stops sharing it with the
  /// others. The notice of new ones has an Undo, which puts back whom it was shared with.
  Future<void> sharePlaylist(Playlist playlist, List<AccountInfo> chosen, {bool tell = true}) async {
    final previous = [...playlist.sharing.members, ...playlist.sharing.invited];
    final before = {for (final a in previous) a.id};
    final after = {for (final a in chosen) a.id};
    try {
      for (final id in after.difference(before)) {
        await _session.setPlaylistMember(playlist.id, id, true);
      }
      for (final id in before.difference(after)) {
        await _session.setPlaylistMember(playlist.id, id, false);
      }
      await _session.refreshUserData(); // whom it is shared with, as the server has it
      final added = [
        for (final a in chosen)
          if (!before.contains(a.id)) a.username,
      ];
      if (tell && added.isNotEmpty) {
        final shared = _library.getPlaylist(playlist.id) ?? playlist;
        notify(
          Localizer.format('PlaylistSharedTo', [
            added.length == 1 ? added.single : Localizer.format('PeopleCount', [added.length]),
          ]),
          undo: () => unawaited(sharePlaylist(shared, previous, tell: false)),
        );
      }
    } catch (e) {
      notify(Localizer.format('ChangeRefused', ['$e']), isError: true);
    }
  }

  /// The invitations to Blends this account got.
  List<Blend> get blendInvitations => blends.invitations;

  /// Accepts an invitation to a Blend: it is on the Playlists page from now on.
  Future<void> acceptBlend(Blend blend) async {
    try {
      await blends.invite(blend.other);
      notify(Localizer.format('BlendAccepted', [blend.other.username]));
    } catch (e) {
      notify(Localizer.format('ChangeRefused', ['$e']), isError: true);
    }
  }

  /// Turns down an invitation to a Blend.
  void declineBlend(Blend blend) => unawaited(blends.leave(blend));

  /// Invites [to] to Blends, one each: theirs once they accept. The notice has an Undo, which takes the new
  /// invitations back.
  Future<void> inviteToBlend(List<AccountInfo> to) async {
    try {
      final before = {for (final b in blends.items) b.id};
      final sent = [
        for (final account in to) await blends.invite(account),
      ].where((b) => !before.contains(b.id) && b.state == BlendState.inviting).toList();
      final who = to.length == 1 ? to.single.username : Localizer.format('PeopleCount', [to.length]);
      notify(
        Localizer.format('BlendInvited', [who]),
        undo: sent.isEmpty
            ? null
            : () {
                for (final blend in sent) {
                  unawaited(blends.leave(blend));
                }
              },
      );
    } catch (e) {
      notify(Localizer.format('ChangeRefused', ['$e']), isError: true);
    }
  }

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
      // What it recommended goes with the block, and so does a Blend with it.
      if (block) unawaited(recommendations.refresh());
      if (block) unawaited(blends.refresh());
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
    playlistInvites.dispose();
    super.dispose();
  }
}
