// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

Track _track(
  String id, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  int seconds = 200,
  int size = 1000,
}) => Track(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: Duration(seconds: seconds),
  fileSizeBytes: size,
  filePath: '/music/$id.flac',
);

void main() {
  group('a file that moved', () {
    test('is the one with the same size and length, whatever its tags say now', () {
      final moved = TrackMoves.pair([_track('old')], [_track('new', title: 'Renamed', artist: 'Other', album: 'Else')]);
      expect(moved, {'old': 'new'});
    });

    test('is the same song when it was tagged or encoded again, with a length a little different', () {
      final moved = TrackMoves.pair(
        [_track('old', title: 'Song (2011 Remaster)', size: 5000)],
        [_track('new', seconds: 201, size: 9000)],
      );
      expect(moved, {'old': 'new'});
    });

    test('is not another song of the same name, or one with a very different length', () {
      expect(TrackMoves.pair([_track('old')], [_track('new', size: 2000, seconds: 260)]), isEmpty);
      expect(TrackMoves.pair([_track('old')], [_track('new', size: 2000, title: 'Another')]), isEmpty);
      expect(TrackMoves.pair([_track('old')], [_track('new', size: 2000, album: 'Elsewhere')]), isEmpty);
    });

    test('is not guessed when two files fit, so copies never swap their data', () {
      // Two files of the same size and length went, two appeared: which is which can't be told.
      expect(TrackMoves.pair([_track('a'), _track('b')], [_track('c'), _track('d')]), isEmpty);
      // Two copies of a song appeared for the one that went.
      expect(TrackMoves.pair([_track('old')], [_track('copy1', size: 2000), _track('copy2', size: 3000)]), isEmpty);
    });

    test('is found among many files that merely look alike', () {
      final gone = [for (var i = 0; i < 50; i++) _track('old$i', title: 'Song $i', size: 1000 + i, seconds: 100 + i)];
      final appeared = [
        for (var i = 0; i < 50; i++) _track('new$i', title: 'Song $i', size: 1000 + i, seconds: 100 + i),
        _track('fresh', title: 'Never heard', size: 77, seconds: 12),
      ];
      final moved = TrackMoves.pair(gone, appeared);
      expect(moved, {for (var i = 0; i < 50; i++) 'old$i': 'new$i'});
    });

    test('is never a track without a title or artist, which all look alike', () {
      final untitled = _track('old', title: Track.unknownTitle, size: 5000);
      final unnamed = _track('new', title: Track.unknownTitle, size: 6000);
      expect(TrackMoves.pair([untitled], [unnamed]), isEmpty);
      expect(
        TrackMoves.pair(
          [_track('a', artist: Track.unknownArtist)],
          [_track('b', artist: Track.unknownArtist, size: 9)],
        ),
        isEmpty,
      );
    });

    test('needs a track that went and one that appeared', () {
      expect(TrackMoves.pair(const [], [_track('new')]), isEmpty);
      expect(TrackMoves.pair([_track('old')], const []), isEmpty);
    });
  });
}
