// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';

import 'config.dart';

/// Keeps the server library in sync with the music folder: scans at start-up, on a fixed interval and whenever a scan
/// is requested through the API. Scans are incremental (unchanged files are not read again).
class LibraryScanService {
  LibraryScanService(this._library, this._paths, {Duration? interval}) : _interval = interval;

  final LibraryService _library;
  final ServerPaths _paths;
  final Duration? _interval;

  Completer<void> _trigger = Completer<void>();
  final CancellationToken _cancellation = CancellationToken();
  bool _stopped = false;
  Future<void>? _loop;

  DateTime? lastScanAt;

  /// Why the last scan didn't run or failed, in English and as a code ([ErrorCodes]); null after one that went well.
  String? lastScanError;
  String? lastScanProblem;

  void _problem(String code, String message) {
    lastScanProblem = code;
    lastScanError = message;
  }

  void start() => _loop ??= _run();

  /// Asks for a scan; requests made while one is pending are merged into it.
  void requestScan() {
    if (!_trigger.isCompleted) _trigger.complete();
  }

  /// Ends the loop. A scan that is running stops after the files it is reading now, and the index keeps its last state.
  Future<void> stop() async {
    _stopped = true;
    _cancellation.cancel();
    requestScan();
    await _loop;
  }

  Future<void> _run() async {
    await Future<void>.delayed(Duration.zero);
    while (!_stopped) {
      await scanOnce();
      if (_stopped) break;

      // Wake up on an explicit request or when the interval elapses, whichever comes first.
      final trigger = _trigger.future;
      final interval = _interval;
      await (interval == null ? trigger : trigger.timeout(interval, onTimeout: () {}));
      _trigger = Completer<void>();
    }
  }

  Future<void> scanOnce() async {
    final root = _paths.musicFolder;
    try {
      if (!Directory(root).existsSync()) {
        _problem(ErrorCodes.folderMissing, 'Library folder does not exist: $root');
        WiretuneLog.warn('LibraryScan', lastScanError!);
        return;
      }

      // An unmounted network share usually shows up as an empty mount point; never wipe the library for that. This only
      // applies to the folder the index was built from: pointing the server at a new, empty folder is deliberate.
      if (_library.tracks.isNotEmpty &&
          _library.musicFolder == AppPaths.fullPath(root) &&
          Directory(root).listSync().isEmpty) {
        _problem(
          ErrorCodes.folderLooksUnmounted,
          'Library folder is empty (unmounted share?): $root. Keeping the existing index.',
        );
        WiretuneLog.warn('LibraryScan', lastScanError!);
        return;
      }

      final started = DateTime.now();
      if (await _library.scanFolder(root, cancellationToken: _cancellation)) {
        lastScanAt = DateTime.now().toUtc();
        lastScanError = null;
        lastScanProblem = null;
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        WiretuneLog.info(
          'LibraryScan',
          'Scan complete in ${seconds.toStringAsFixed(1)}s: ${_library.tracks.length} tracks, ${_library.albums.length} albums, ${_library.artists.length} artists.',
        );
      }
    } catch (e, s) {
      _problem(ErrorCodes.scanFailed, '$e');
      WiretuneLog.error('LibraryScan', 'Scan failed: $e', e, s);
    }
  }
}
