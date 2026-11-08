// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The listening summary: how long, how many plays, and what was played most, from each track's count.
void main() {
  Track track(String id, String artist, String album, {String? genre, List<String>? artists}) => Track(
    id: id,
    title: 'Song $id',
    artist: artist,
    artists: artists,
    album: album,
    genre: genre,
    duration: const Duration(minutes: 3),
  );

  test('the time and plays add up; tracks, first artists, albums and genres rank by their plays', () {
    final a1 = track('a1', 'The Roots', 'Phrenology', genre: 'Hip Hop', artists: ['The Roots', 'Cody ChestnuTT']);
    final a2 = track('a2', 'The Roots', 'Phrenology', genre: 'hip hop');
    final b1 = track('b1', 'Norah Jones', 'Come Away With Me', genre: 'Jazz');
    final never = track('c1', 'Outkast', 'Stankonia');
    final summary = ListeningSummary.of({a1: 3, a2: 1, b1: 2, never: 0});

    expect(summary.plays, 6);
    expect(summary.listened, const Duration(minutes: 18));
    expect(summary.tracks.map((t) => (t.track.id, t.plays)), [('a1', 3), ('b1', 2), ('a2', 1)]);
    expect(summary.artists, [(name: 'The Roots', plays: 4), (name: 'Norah Jones', plays: 2)]);
    expect(summary.albums.map((a) => a.plays), [4, 2]);
    expect(summary.albums.first.albumId, a1.albumId);
    expect(summary.genres, [
      (name: 'Hip Hop', plays: 4),
      (name: 'Jazz', plays: 2),
    ], reason: 'one genre whatever its case');
    expect(ListeningSummary.of({never: 0}).isEmpty, isTrue);
  });
}
