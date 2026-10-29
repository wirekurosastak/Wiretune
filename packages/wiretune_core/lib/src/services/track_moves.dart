// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import '../models/library_models.dart';
import 'track_deduplication.dart';

/// Finds the files that were moved or renamed between two scans. A track is known by its file path, so a moved file is
/// a new track and a missing one; this pairs them, so that favourites, play counts, playlists and hidden items follow
/// the file instead of staying with a track that is gone.
abstract final class TrackMoves {
  /// The tracks of [gone] (their paths no longer exist) that [appeared] (new paths) under another path, as old track ID
  /// -> new track ID. A pair needs no rival: it is made only when it is the one candidate on both sides, so that two
  /// copies of a song never swap their data. Two passes:
  ///
  /// 1. The same size and length: the file itself, moved.
  /// 2. The same title, artist and album, and nearly the same length: the song, tagged or encoded again.
  static Map<String, String> pair(Iterable<Track> gone, Iterable<Track> appeared) {
    final moved = <String, String>{};
    var goneLeft = gone.toList();
    var appearedLeft = appeared.toList();
    if (goneLeft.isEmpty || appearedLeft.isEmpty) return moved;

    void pairBy(String? Function(Track track) key, bool Function(Track before, Track after) accepts) {
      final before = _grouped(goneLeft, key);
      final after = _grouped(appearedLeft, key);
      final paired = <String>{};
      for (final MapEntry(key: group, value: olds) in before.entries) {
        final news = after[group];
        if (olds.length != 1 || news == null || news.length != 1 || !accepts(olds.single, news.single)) continue;
        moved[olds.single.id] = news.single.id;
        paired
          ..add(olds.single.id)
          ..add(news.single.id);
      }
      goneLeft = goneLeft.where((t) => !paired.contains(t.id)).toList();
      appearedLeft = appearedLeft.where((t) => !paired.contains(t.id)).toList();
    }

    pairBy(
      (t) =>
          t.fileSizeBytes > 0 && t.duration > Duration.zero ? '${t.fileSizeBytes}|${t.duration.inMilliseconds}' : null,
      (_, _) => true,
    );
    pairBy((t) {
      final title = TrackDeduplication.cleanTitle(t.title);
      final artist = TrackDeduplication.cleanArtist(t.primaryArtist);
      if (title.isEmpty || artist.isEmpty || t.title == Track.unknownTitle || Track.isUnknownArtist(t.primaryArtist)) {
        return null;
      }
      return '$title|$artist|${TrackDeduplication.cleanAlbum(t.album)}';
    }, (before, after) => (before.duration - after.duration).inMilliseconds.abs() <= _tolerance.inMilliseconds);
    return moved;
  }

  /// How far apart the lengths of a song in two files may be (another encoder pads or trims a little).
  static const Duration _tolerance = Duration(seconds: 2);

  static Map<String, List<Track>> _grouped(List<Track> tracks, String? Function(Track track) key) {
    final groups = <String, List<Track>>{};
    for (final track in tracks) {
      final group = key(track);
      if (group != null) groups.putIfAbsent(group, () => []).add(track);
    }
    return groups;
  }
}
