// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import '../models/library_models.dart';

/// What the library has that is like an artist or an album: the rows at the bottom of their pages (Related artists,
/// Similar albums). Built from what the tracks say, each where the library has it: who they credit together (in
/// either direction: a guest on the artist's tracks, the artist as a guest on others'), their genre (from the tags or
/// looked up by the server), when they came out and their tempo. A library without genres still gets the artists and
/// albums that share names; one with them gets more. Era and tempo only order what names or genre already found, never
/// make a match alone.
abstract final class Related {
  /// The most a row shows.
  static const int max = 12;

  // Worked out once for each artist and album the library has: a new library (a scan, a sync) makes new ones.
  static final Expando<List<Artist>> _artists = Expando();
  static final Expando<List<Album>> _moreBy = Expando();
  static final Expando<List<Album>> _albums = Expando();

  /// [artists], kept for [artist] until the library makes it anew.
  static List<Artist> artistsOf(Artist artist, List<Artist> all, Iterable<Track> tracks) =>
      _artists[artist] ??= artists(artist, all, tracks);

  /// [moreBy], kept for [album] until the library makes it anew.
  static List<Album> moreByOf(Album album, List<Album> all) => _moreBy[album] ??= moreBy(album, all);

  /// [albums], kept for [album] until the library makes it anew.
  static List<Album> albumsOf(Album album, List<Album> all) => _albums[album] ??= albums(album, all);

  /// The artists of [all] most like [artist], the closest first.
  static List<Artist> artists(Artist artist, List<Artist> all, Iterable<Track> tracks) {
    final self = _key(artist.name);
    final byKey = {for (final other in all) _key(other.name): other};
    final score = <String, double>{};
    // Credited together on a track: whoever else it names, whichever of them is the guest.
    for (final track in tracks) {
      final names = {
        for (final name in [...track.artistNames, ...track.albumArtistNames]) _key(name),
      };
      if (!names.contains(self)) continue;
      for (final name in names) {
        if (name != self && byKey.containsKey(name)) score[name] = (score[name] ?? 0) + 3;
      }
    }
    for (final name in score.keys) {
      score[name] = score[name]!.clamp(0, 12).toDouble();
    }
    final genre = _mainGenre(artist.tracks);
    final year = _medianYear(artist.tracks);
    for (final MapEntry(key: name, value: other) in byKey.entries) {
      if (name == self) continue;
      var points = score[name] ?? 0;
      if (genre != null && _mainGenre(other.tracks) == genre) points += 2;
      if (points == 0) continue;
      points += _closeness(year, _medianYear(other.tracks), within: 5);
      score[name] = points;
    }
    final ranked = score.entries.toList()
      ..sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        return byScore != 0 ? byScore : byKey[b.key]!.trackCount.compareTo(byKey[a.key]!.trackCount);
      });
    return [for (final entry in ranked.take(max)) byKey[entry.key]!];
  }

  /// The other albums of [album]'s artists, the newest first: More by.
  static List<Album> moreBy(Album album, List<Album> all) {
    final names = {for (final name in album.artistNames) _key(name)};
    return [
      for (final other in all)
        if (other.id != album.id && other.artistNames.any((name) => names.contains(_key(name)))) other,
    ]..sort((a, b) => (b.releaseYear ?? 0).compareTo(a.releaseYear ?? 0));
  }

  /// The albums of [all] by other artists most like [album], the closest first: Similar albums.
  static List<Album> albums(Album album, List<Album> all) {
    final own = {for (final name in album.artistNames) _key(name)};
    final credited = _credited(album.tracks)..removeAll(own);
    final genre = _mainGenre(album.tracks);
    final year = album.releaseYear ?? _medianYear(album.tracks);
    final bpm = _medianBpm(album.tracks);
    final scored = <(Album, double)>[];
    for (final other in all) {
      if (other.id == album.id || other.artistNames.any((name) => own.contains(_key(name)))) continue;
      var points = 0.0;
      if (_credited(other.tracks).any(credited.contains) || other.artistNames.any((n) => credited.contains(_key(n)))) {
        points += 3;
      }
      if (genre != null && _mainGenre(other.tracks) == genre) points += 2;
      if (points == 0) continue;
      points += _closeness(year, other.releaseYear ?? _medianYear(other.tracks), within: 3);
      final otherBpm = _medianBpm(other.tracks);
      // Tempo weighs least: it says less than the era does about how alike two albums are.
      if (bpm != null && otherBpm != null && (bpm - otherBpm).abs() <= bpm * 0.1) points += 0.25;
      scored.add((other, points));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (other, _) in scored.take(max)) other];
  }

  static String _key(String name) => name.trim().toLowerCase();

  /// Every name the tracks credit, as keys.
  static Set<String> _credited(Iterable<Track> tracks) => {
    for (final track in tracks)
      for (final name in [...track.artistNames, ...track.albumArtistNames]) _key(name),
  };

  /// The genre most of [tracks] have; null when none has one.
  static String? _mainGenre(Iterable<Track> tracks) {
    final counts = <String, int>{};
    for (final track in tracks) {
      final genre = track.genre?.trim().toLowerCase();
      if (genre != null && genre.isNotEmpty) counts[genre] = (counts[genre] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  static int? _medianYear(Iterable<Track> tracks) => _median([for (final t in tracks) ?t.releaseYear]);

  static int? _medianBpm(Iterable<Track> tracks) => _median([for (final t in tracks) ?t.bpm]);

  static int? _median(List<int> values) {
    if (values.isEmpty) return null;
    values.sort();
    return values[values.length ~/ 2];
  }

  /// Up to 1 for two years [within] years apart or closer, the closer the more.
  static double _closeness(int? a, int? b, {required int within}) {
    if (a == null || b == null) return 0;
    final apart = (a - b).abs();
    return apart > within ? 0 : 1 - apart / (within + 1);
  }
}
