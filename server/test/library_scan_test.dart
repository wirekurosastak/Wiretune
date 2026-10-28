// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// A scan that only ends when it is cancelled, like the first scan of a very large library.
class _EndlessScanner extends MetadataScanner {
  final Completer<void> started = Completer<void>();

  @override
  Future<List<Track>> scanDirectory(
    String rootPath, {
    String? coverCacheDirectory,
    void Function(ScanProgressReport report)? onProgress,
    CancellationToken? cancellationToken,
    Map<String, Track>? knownTracks,
    String? skip,
  }) async {
    started.complete();
    final token = cancellationToken ?? CancellationToken.none;
    for (var i = 0; i < 6000 && !token.isCancelled; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw const OperationCanceledException();
  }
}

/// The background scan loop of the server.
void main() {
  setUpAll(useTempDataDirectory);

  test('stopping cancels a running scan instead of waiting for it', () async {
    final root = Directory.systemTemp.createTempSync('wiretune_scan_').path;
    final scanner = _EndlessScanner();
    final library = LibraryService(testRepository(), scanner, coverCacheDirectory: p.join(root, 'Covers'));
    final scans = LibraryScanService(library, ServerPaths(root, root, p.join(root, 'Covers')));

    scans.start();
    await scanner.started.future;
    // systemd gives a service 90 seconds after SIGTERM before it kills it.
    await scans.stop().timeout(const Duration(seconds: 5));
    expect(library.isScanning, isFalse);
    expect(scans.lastScanAt, isNull);
  });

  test('music copied into the folder is scanned once the copying stops, without being asked', () async {
    final root = Directory.systemTemp.createTempSync('wiretune_watch_scan_').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final music = p.join(root, 'Music');
    writeWav(p.join(music, 'Album', '01 One.wav'), 44100);
    final library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: p.join(root, 'Covers'));
    final scans = LibraryScanService(
      library,
      ServerPaths(music, root, p.join(root, 'Covers')),
      watchDelay: const Duration(milliseconds: 200),
    );
    var scanned = 0;
    scans.onScanned = () => scanned++;
    addTearDown(scans.stop);

    scans.start();
    await until(() => scanned > 0);
    expect(library.tracks, hasLength(1));

    writeWav(p.join(music, 'Album', '02 Two.wav'), 44100);
    writeWav(p.join(music, 'Album', '03 Three.wav'), 44100);
    await until(() => library.tracks.length == 3);
    expect(library.tracks, hasLength(3));
  }, testOn: 'linux || mac-os || windows');
}
