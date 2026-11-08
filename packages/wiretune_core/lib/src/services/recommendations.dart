// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import '../models/protocol.dart';
import '../util/event.dart';
import 'library_service.dart';
import 'remote_client.dart';
import 'server_session.dart';
import 'wiretune_log.dart';

/// What the other accounts of the server recommended to this one (the bell), kept up to date: downloaded when the
/// session signs in, again whenever the server says it changed, and forgotten when the session signs out.
class Recommendations {
  Recommendations(this._session, this._library, RemoteClient remote) {
    _unsubscribers.addAll([
      _session.stateChanged.listen((_) => _sessionChanged()),
      remote.recommendationsChanged.listen((_) => unawaited(refresh())),
      // What this library has decides what can be shown.
      _library.libraryChanged.listen((_) => changed.emit(null)),
    ]);
    _sessionChanged();
  }

  final ServerSession _session;
  final LibraryService _library;
  final List<void Function()> _unsubscribers = [];

  List<Recommendation> _all = const [];

  /// The account [_all] belongs to.
  String? _account;

  /// Raised when [items] or [unseenCount] may have changed.
  final Event<void> changed = Event<void>();

  /// The ones whose artist, album or track this library has, the newest first. What the account hides never shows,
  /// whoever recommends it: a hidden track, or one of a hidden album or artist, is left out as the hidden album or
  /// artist is.
  List<Recommendation> get items => [
    for (final recommendation in _all)
      if (isInLibrary(recommendation)) recommendation,
  ];

  /// How many of [items] came since the bell was last opened, on any of the account's players.
  int get unseenCount => items.where((r) => !r.seen).length;

  bool isInLibrary(Recommendation recommendation) => switch (recommendation.kind) {
    RecommendationKind.track => _library.resolveTracks([recommendation.itemId]).any((t) => !_library.isTrackHidden(t)),
    RecommendationKind.album => _library.getAlbum(recommendation.itemId) != null,
    RecommendationKind.artist => _library.getArtist(recommendation.itemId) != null,
  };

  void _sessionChanged() {
    final account = _session.isLoggedIn ? _session.currentUser?.id : null;
    if (account == _account) return;
    _account = account;
    _all = const [];
    changed.emit(null);
    if (account != null) unawaited(refresh());
  }

  /// Downloads them again; a failure leaves what was shown.
  Future<void> refresh() async {
    final account = _account;
    if (account == null) return;
    try {
      final all = await _session.getRecommendations();
      if (_account != account) return; // signed out or in as another meanwhile
      _all = all;
      changed.emit(null);
    } catch (e) {
      WiretuneLog.debug('Recommendations', 'Could not download the recommendations: $e');
    }
  }

  /// The bell was opened: what it holds now has been seen, here and on the account's other players.
  Future<void> markSeen() async {
    if (_all.every((r) => r.seen)) return;
    _all = [for (final r in _all) r.seen ? r : r.copyWith(seen: true)];
    changed.emit(null);
    try {
      await _session.markRecommendationsSeen();
    } catch (e) {
      WiretuneLog.debug('Recommendations', 'Could not mark the recommendations seen: $e');
    }
  }

  /// Takes [recommendation] away, here at once and then on the server; a server that can't be reached brings it back
  /// with the next download.
  Future<void> dismiss(Recommendation recommendation) async {
    _all = [
      for (final r in _all)
        if (r.id != recommendation.id) r,
    ];
    changed.emit(null);
    try {
      await _session.removeRecommendation(recommendation.id);
    } catch (e) {
      WiretuneLog.debug('Recommendations', 'Could not dismiss a recommendation: $e');
      unawaited(refresh());
    }
  }

  /// The other accounts of the server, to recommend to or listen together with.
  Future<List<AccountInfo>> otherAccounts() async {
    final me = _session.currentUser?.id;
    return [
      for (final account in await _session.getAccounts())
        if (account.id != me) account,
    ];
  }

  /// Recommends [itemId] to the accounts [to]. Returns what takes it back. Throws when the server can't be reached or
  /// refuses it.
  Future<Future<void> Function()> send(RecommendationKind kind, String itemId, List<String> to, String note) async {
    final ids = await _session.recommend(kind, itemId, to, RecommendationRules.cleanNote(note));
    return () async {
      for (final id in ids) {
        await _session.removeRecommendation(id);
      }
    };
  }

  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
  }
}
