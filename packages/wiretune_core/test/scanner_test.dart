// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  late Directory root;

  setUpAll(useTempDataDirectory);
  setUp(() {
    root = Directory.systemTemp.createTempSync('wiretune_scan_');
    writeWav(p.join(root.path, 'Artist A', 'Album 1', '01 First.wav'), 44100);
    writeWav(p.join(root.path, 'Artist A', 'Album 1', '02 Second.wav'), 44100);
    writeWav(p.join(root.path, 'Artist B', 'Album 2', '01 Third.wav'), 96000);
    File(p.join(root.path, 'Artist A', 'Album 1', 'Folder.JPG')).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    writeWav(p.join(root.path, '.hidden', 'Secret.wav'), 44100);
    writeWav(p.join(root.path, 'Artist B', '.Skipped.wav'), 44100);
    File(p.join(root.path, 'Artist B', 'notes.txt')).writeAsStringSync('not audio');
    File(p.join(root.path, 'Artist B', 'Broken.flac')).writeAsBytesSync(List.filled(64, 1));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('scans recursively, skips hidden and unreadable files, and finds folder covers', () async {
    final reports = <ScanProgressReport>[];
    final tracks = await MetadataScanner().scanDirectory(root.path, onProgress: reports.add);

    expect(tracks.map((t) => t.title).toList()..sort(), ['01 First', '02 Second', '01 Third']..sort());
    final first = tracks.firstWhere((t) => t.title == '01 First');
    expect(first.artist, MetadataScanner.unknownArtist);
    expect(first.album, MetadataScanner.unknownAlbum);
    expect(first.format.codec, 'WAV');
    expect(first.format.isLossless, isTrue);
    expect(first.duration, const Duration(seconds: 1));
    expect(first.coverArtPath, endsWith('Folder.JPG')); // the names are matched ignoring case
    expect(first.hasCoverArt, isTrue);
    expect(first.fileModifiedUtc, isNotNull);
    expect(tracks.firstWhere((t) => t.title == '01 Third').format.isHiRes, isTrue);
    expect(reports.last.scannedFiles, 4); // the broken FLAC counts as scanned, but yields nothing
    expect(reports.last.progressPercentage, 100);
  });

  test('an unchanged file is not read again, a changed one is', () async {
    final scanner = MetadataScanner();
    final first = await scanner.scanDirectory(root.path);
    final known = {for (final t in first) t.filePath: t};

    final again = await scanner.scanDirectory(root.path, knownTracks: known);
    for (final t in again) {
      expect(identical(t, known[t.filePath]), isTrue, reason: t.title);
    }

    final changed = p.join(root.path, 'Artist A', 'Album 1', '02 Second.wav');
    writeWav(changed, 48000, seconds: 2);
    final third = await scanner.scanDirectory(root.path, knownTracks: known);
    final retagged = third.firstWhere((t) => t.filePath == AppPaths.fullPath(changed));
    expect(identical(retagged, known[retagged.filePath]), isFalse);
    expect(retagged.format.sampleRate, 48000);
  });

  test('the library scan stores the folder and keeps user data across rescans', () async {
    final repo = testRepository();
    final library = LibraryService(
      repo,
      MetadataScanner(),
      coverCacheDirectory: p.join(root.path, '..', 'covers_${p.basename(root.path)}'),
    );
    library.initialize();

    expect(await library.scanFolder(root.path), isTrue);
    expect(library.tracks, hasLength(3));
    expect(library.libraryPath, AppPaths.fullPath(root.path));
    expect(repo.getSetting('library_path'), AppPaths.fullPath(root.path));

    final id = library.tracks.first.id;
    library.toggleFavorite(id);
    expect(await library.scanFolder(root.path), isTrue);
    expect(library.getTrack(id)!.isFavorite, isTrue);

    expect(await library.scanFolder(p.join(root.path, 'missing')), isFalse);
  });

  test('a cancelled scan leaves the library alone', () async {
    final repo = testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();
    final token = CancellationToken()..cancel();
    expect(await library.scanFolder(root.path, cancellationToken: token), isFalse);
    expect(library.tracks, isEmpty);
  });
}
