// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// What the bell holds ("From friends"): the music the other accounts of the server recommended, and recommending
/// music to them.
class FriendsViewModel extends ChangeNotifier {
  FriendsViewModel(this._session, this._library, this.recommendations, {required this.notify}) {
    _unsubscribers.addAll([
      recommendations.changed.listen((_) => notifyListeners()),
      _session.stateChanged.listen((_) => notifyListeners()),
    ]);
  }

  final ServerSession _session;
  final LibraryService _library;
  final Recommendations recommendations;

  /// Shows a notice, with its Undo when given.
  final void Function(String message, {bool isError, VoidCallback? undo}) notify;
  final List<void Function()> _unsubscribers = [];

  /// The bell is there while signed in to a server: the friends are its other accounts.
  bool get isAvailable => _session.isLoggedIn;

  /// What the bell's count says.
  int get unseenCount => recommendations.unseenCount;

  List<Recommendation> get items => recommendations.items;

  /// The bell was opened.
  void opened() => unawaited(recommendations.markSeen());

  void dismiss(Recommendation recommendation) => unawaited(recommendations.dismiss(recommendation));

  Track? trackOf(Recommendation r) =>
      r.kind == RecommendationKind.track ? _library.resolveTracks([r.itemId]).firstOrNull : null;

  Album? albumOf(Recommendation r) => r.kind == RecommendationKind.album ? _library.getAlbum(r.itemId) : null;

  Artist? artistOf(Recommendation r) => r.kind == RecommendationKind.artist ? _library.getArtist(r.itemId) : null;

  /// The other accounts, the people music can be recommended to. Throws when the server can't be reached.
  Future<List<AccountInfo>> otherAccounts() => recommendations.otherAccounts();

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
