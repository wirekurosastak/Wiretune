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
    expect(first.artist, Track.unknownArtist);
    expect(first.album, Track.unknownAlbum);
    expect(first.format.codec, 'WAV');
    expect(first.format.isLossless, isTrue);
    expect(first.duration, const Duration(seconds: 1));
    expect(first.coverArtPath, endsWith('Folder.JPG')); // the names are matched ignoring case
    expect(first.hasCoverArt, isTrue);
    expect(first.fileModifiedAt, isNotNull);
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

  test('a folder cover added, renamed or removed next to unchanged tracks is noticed', () async {
    final scanner = MetadataScanner();
    final album = p.join(root.path, 'Artist B', 'Album 2');
    var known = {for (final t in await scanner.scanDirectory(root.path)) t.filePath: t};
    Future<void> rescan() async =>
        known = {for (final t in await scanner.scanDirectory(root.path, knownTracks: known)) t.filePath: t};
    Track third() => known.values.firstWhere((t) => t.title == '01 Third');
    final first = known.values.firstWhere((t) => t.title == '01 First');
    expect(third().hasCoverArt, isFalse);

    File(p.join(album, 'cover.jpg')).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    await rescan();
    expect(third().coverArtPath, endsWith('cover.jpg'));
    expect(third().hasCoverArt, isTrue);

    File(p.join(album, 'cover.jpg')).renameSync(p.join(album, 'folder.png'));
    await rescan();
    expect(third().coverArtPath, endsWith('folder.png'));

    File(p.join(album, 'folder.png')).deleteSync();
    await rescan();
    expect(third().coverArtPath, isNull);
    expect(third().hasCoverArt, isFalse);

    // The album whose folder did not change was never read again.
    expect(identical(known[first.filePath], first), isTrue);
  });

  test('a new picture in the files is cached anew, and the old one is tidied away', () async {
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final music = Directory.systemTemp.createTempSync('wiretune_embedded_');
    addTearDown(() => music.deleteSync(recursive: true));
    final covers = p.join(music.path, '..', '${p.basename(music.path)}_covers');
    addTearDown(() => Directory(covers).deleteSync(recursive: true));
    final file = p.join(music.path, 'Album', '01 One.wav');
    writeWav(file, 44100, picture: [...png, 1, 2, 3]);
    final library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: covers);
    library.initialize();

    expect(await library.scanFolder(music.path), isTrue);
    final before = library.tracks.single.coverArtPath!;
    expect(File(before).readAsBytesSync(), [...png, 1, 2, 3]);

    writeWav(file, 44100, picture: [...png, 4, 5, 6, 7]);
    expect(await library.scanFolder(music.path), isTrue);
    final after = library.tracks.single.coverArtPath!;
    expect(after, isNot(before));
    expect(File(after).readAsBytesSync(), [...png, 4, 5, 6, 7]);
    expect(File(before).existsSync(), isFalse);
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
    expect(library.musicFolder, AppPaths.fullPath(root.path));
    expect(repo.getSetting('music_folder'), AppPaths.fullPath(root.path));

    final id = library.tracks.first.id;
    library.toggleFavorite(id);
    expect(await library.scanFolder(root.path), isTrue);
    expect(library.isFavorite(id), isTrue);

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
