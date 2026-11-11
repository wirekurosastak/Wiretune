// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:wiretune_core/wiretune_core.dart';

import 'artist_lookup_service.dart';
import 'style_lookup_service.dart';

/// What the players get to tell which music of the library is alike: [facts], from what the server looked up online,
/// the same for every account; and [pairsOf] an account, from what it plays.
class RelatedMusicService {
  RelatedMusicService(this._db, this._library, this._artists, this._styles);

  final DatabaseManager _db;
  final LibraryService _library;
  final ArtistLookupService _artists;
  final StyleLookupService _styles;

  /// The most artists kept alike to one.
  static const int kept = 30;

  /// A new sitting begins after this long without a play.
  static const Duration sittingGap = Duration(minutes: 45);

  /// A sitting of more artists than this (a whole library on shuffle) says nothing about which go together.
  static const int widestSitting = 50;

  /// The library's artists alike by Deezer's listeners, and the styles of the artists and albums.
  ///
  /// Two artists of the library are alike when Deezer relates one to the other (the higher in its list of twenty, the
  /// more), and also when Deezer relates both to the same artists: that finds what goes together in a small library,
  /// where an artist's twenty are mostly artists it doesn't have.
  RelatedMusicFacts facts() {
    final names = {for (final artist in _library.artists) ArtistLookupService.artistKey(artist.name): artist.name};
    final related = <String, List<String>>{
      for (final MapEntry(:key, value: name) in names.entries)
        if (_artists.relatedOf(name) case final list?)
          key: [for (final other in list) ArtistLookupService.artistKey(other)],
    };
    // Who lists each artist (in the library or not), and where.
    final listedBy = <String, List<(String, int)>>{};
    for (final MapEntry(key: artist, value: list) in related.entries) {
      for (final (rank, other) in list.indexed) {
        listedBy.putIfAbsent(other, () => []).add((artist, rank));
      }
    }

    final similar = <String, Weights>{};
    for (final MapEntry(key: artist, value: list) in related.entries) {
      final direct = <String, double>{};
      final shared = <String, int>{};
      for (final (rank, other) in list.indexed) {
        if (other != artist && names.containsKey(other)) {
          direct[other] = math.max(direct[other] ?? 0, _rankWeight(rank));
        }
        for (final (lister, _) in listedBy[other] ?? const <(String, int)>[]) {
          if (lister != artist) shared[lister] = (shared[lister] ?? 0) + 1;
        }
      }
      for (final (lister, rank) in listedBy[artist] ?? const <(String, int)>[]) {
        direct[lister] = math.max(direct[lister] ?? 0, _rankWeight(rank));
      }
      final scores = <String, double>{};
      for (final other in {...direct.keys, ...shared.keys}) {
        final overlap = (shared[other] ?? 0) / math.sqrt(list.length * (related[other]?.length ?? list.length));
        final score = math.max(direct[other] ?? 0, math.min(1.0, 1.5 * overlap));
        if (score >= 0.1) scores[other] = score;
      }
      if (scores.isNotEmpty) similar[artist] = _top(scores);
    }

    Weights styles(List<Style>? list) => {
      for (final (name, weight) in list ?? const <Style>[]) name: weight.toDouble(),
    };
    return RelatedMusicFacts(
      similarArtists: similar,
      artistStyles: {
        for (final MapEntry(:key, value: name) in names.entries)
          if (_styles.ofArtist(name) case final list?) key: styles(list),
      },
      albumStyles: {
        for (final album in _library.albums)
          if (_styles.ofAlbum(album.id) case final list?) album.id: styles(list),
      },
    );
  }

  /// 1 for the first of Deezer's twenty, down to 0.5 for the last.
  static double _rankWeight(int rank) => 1 - 0.5 * rank / 19;

  static Weights _top(Map<String, double> scores) {
    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return {for (final entry in ranked.take(kept)) entry.key: (entry.value * 1000).round() / 1000};
  }

  /// What the play log of [userId] last made, by the log's size and newest play and the library it was made with, so a
  /// request that changes nothing costs a count.
  final Map<String, ((int, int?, int), ListeningPairs)> _made = {};

  /// Which artists [userId] plays in the same sitting (plays less than [sittingGap] apart): two artists go together
  /// the more often they share a sitting, against how often each is played at all, and the surer the more sittings
  /// say so; a sitting of many artists counts for less between each two of them, one of more than [widestSitting] not
  /// at all.
  ListeningPairs pairsOf(String userId) {
    final db = _db.connection;
    final row = db.select('SELECT COUNT(*) AS n, MAX(played_at) AS last FROM user_play_log WHERE user_id = ?', [
      userId,
    ]).first;
    // The library too: the plays are of tracks, the pairs of their artists.
    final version = (row['n'] as int, row['last'] as int?, identityHashCode(_library.tracks));
    final made = _made[userId];
    if (made != null && made.$1 == version) return made.$2;

    final together = <String, Map<String, double>>{};
    final sittings = <String, int>{};
    var sitting = <String>{};
    int? last;
    void close() {
      for (final artist in sitting) {
        sittings[artist] = (sittings[artist] ?? 0) + 1;
      }
      if (sitting.length >= 2 && sitting.length <= widestSitting) {
        final weight = 1 / (sitting.length - 1);
        for (final a in sitting) {
          for (final b in sitting) {
            if (a != b) together.putIfAbsent(a, () => {})[b] = (together[a]![b] ?? 0) + weight;
          }
        }
      }
      sitting = {};
    }

    final gap = sittingGap.inMicroseconds;
    for (final play in db.select('SELECT track_id, played_at FROM user_play_log WHERE user_id = ? ORDER BY played_at', [
      userId,
    ])) {
      final at = play['played_at'] as int;
      if (last != null && at - last > gap) close();
      last = at;
      final track = _library.getTrack(play['track_id'] as String);
      if (track == null) continue;
      for (final name in track.albumArtistNames) {
        if (!Track.isUnknownArtist(name)) sitting.add(ArtistLookupService.artistKey(name));
      }
    }
    close();

    final pairs = <String, Weights>{};
    for (final MapEntry(key: a, value: others) in together.entries) {
      final scores = <String, double>{};
      for (final MapEntry(key: b, value: weight) in others.entries) {
        // Damped by one: two artists heard together once are less sure to go together than ones heard so often.
        final score = weight / (math.sqrt(sittings[a]! * sittings[b]!) + 1);
        if (score >= 0.05) scores[b] = math.min(1.0, score);
      }
      if (scores.isNotEmpty) pairs[a] = _top(scores);
    }
    final result = ListeningPairs(pairs);
    _made[userId] = (version, result);
    return result;
  }
}
