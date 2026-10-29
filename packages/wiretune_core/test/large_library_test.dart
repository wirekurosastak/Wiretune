// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// [count] tracks of artists with four albums of twelve tracks each, like `tool/make_library.dart` makes.
List<Track> _tracks(int count) => [
  for (var i = 0; i < count; i++)
    Track(
      id: 'track-$i',
      title: 'Song $i',
      artist: 'Artist ${i ~/ 48}',
      album: 'Album ${i ~/ 12}',
      albumArtist: 'Artist ${i ~/ 48}',
      trackNumber: i % 12 + 1,
      releaseYear: 1970 + i % 57,
      genre: 'Genre ${i % 20}',
      duration: Duration(seconds: 90 + i % 360),
      filePath: '/music/Artist ${i ~/ 48}/Album ${i ~/ 12}/${i % 12 + 1} - Song $i.mp3',
    ),
];

void main() {
  setUpAll(useTempDataDirectory);

  // The ceilings are about twenty times what a laptop needs (0.6 s for 50,000 tracks, 2026-10-29): they catch a change
  // that makes the work grow faster than the library, not a slow CI machine.
  test('a library of 50,000 tracks is merged in seconds', () {
    final service = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final tracks = _tracks(50000);

    final watch = Stopwatch()..start();
    service.mergeServerTracks(tracks, const UserDataSnapshot([], [], []));
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));

    expect(service.tracks, hasLength(50000));
    expect(service.albums, hasLength(50000 ~/ 12 + 1));
    expect(service.artists, hasLength(50000 ~/ 48 + 1));
  });

  test('the same library merged again changes nothing and is as quick', () {
    final service = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final tracks = _tracks(50000);
    service.mergeServerTracks(tracks, const UserDataSnapshot([], [], []));

    final watch = Stopwatch()..start();
    service.mergeServerTracks(tracks, const UserDataSnapshot([], [], []));
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(service.tracks, hasLength(50000));
  });
}
