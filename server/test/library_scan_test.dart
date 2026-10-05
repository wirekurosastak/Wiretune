// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
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
  }) async {
    started.complete();
    await (cancellationToken ?? CancellationToken.none).whenCancelled.timeout(const Duration(minutes: 1));
    throw const OperationCanceledException();
  }
}

/// The background scan loop of the server.
void main() {
  setUpAll(useTempDataDirectory);

  test('stopping cancels a running scan instead of waiting for it', () async {
    final root = Directory.systemTemp.createTempSync('wiretune_scan_').path;
    final scanner = _EndlessScanner();
    final library = LibraryService(MockRepository(), scanner, coverCacheDirectory: p.join(root, 'Covers'));
    final scans = LibraryScanService(library, ServerPaths(root, root, p.join(root, 'Covers')));

    scans.start();
    await scanner.started.future;
    // systemd gives a service 90 seconds after SIGTERM before it kills it.
    await scans.stop().timeout(const Duration(seconds: 5));
    expect(library.isScanning, isFalse);
    expect(scans.lastScanCompletedUtc, isNull);
  });
}
