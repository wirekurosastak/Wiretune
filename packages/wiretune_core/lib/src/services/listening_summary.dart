// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import '../models/library_models.dart';

/// What someone listened to most in a time (a year, or all time): how long, how many plays, and the tracks, artists,
/// albums and genres they played most, each with its count. Made from how often each track was played.
class ListeningSummary {
  const ListeningSummary._({
    required this.listened,
    required this.plays,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.genres,
  });

  /// How many of each a summary names at most.
  static const int topTracks = 10, topOthers = 5;

  final Duration listened;
  final int plays;
  final List<({Track track, int plays})> tracks;

  /// By the first artist each track credits.
  final List<({String name, int plays})> artists;

  /// By album ID: the library's album of that ID.
  final List<({String albumId, int plays})> albums;
  final List<({String name, int plays})> genres;

  bool get isEmpty => plays == 0;

  /// The summary of [counts]: each track played that many times.
  static ListeningSummary of(Map<Track, int> counts) {
    var listened = Duration.zero;
    var plays = 0;
    final artists = <String, int>{};
    final names = <String, String>{};
    final albums = <String, int>{};
    final genres = <String, int>{};
    final genreNames = <String, String>{};
    for (final MapEntry(key: track, value: count) in counts.entries) {
      if (count <= 0) continue;
      plays += count;
      listened += track.duration * count;
      final artist = track.primaryArtist.trim();
      final key = artist.toLowerCase();
      artists[key] = (artists[key] ?? 0) + count;
      names.putIfAbsent(key, () => artist);
      albums[track.albumId] = (albums[track.albumId] ?? 0) + count;
      final genre = track.genre?.trim();
      if (genre != null && genre.isNotEmpty) {
        genres[genre.toLowerCase()] = (genres[genre.toLowerCase()] ?? 0) + count;
        genreNames.putIfAbsent(genre.toLowerCase(), () => genre);
      }
    }
    List<MapEntry<K, int>> top<K>(Map<K, int> counts, int count) =>
        (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(count).toList();
    return ListeningSummary._(
      listened: listened,
      plays: plays,
      tracks: [
        for (final entry in top({
          for (final MapEntry(:key, :value) in counts.entries)
            if (value > 0) key: value,
        }, topTracks))
          (track: entry.key, plays: entry.value),
      ],
      artists: [for (final entry in top(artists, topOthers)) (name: names[entry.key]!, plays: entry.value)],
      albums: [for (final entry in top(albums, topOthers)) (albumId: entry.key, plays: entry.value)],
      genres: [for (final entry in top(genres, topOthers)) (name: genreNames[entry.key]!, plays: entry.value)],
    );
  }
}
