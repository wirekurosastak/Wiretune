// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../models/audio_format.dart';
import 'app_paths.dart';
import 'metadata_scanner.dart';
import 'wiretune_log.dart';

/// Calls [onSettled] once the music in a folder has stopped changing for [quiet] (files added, changed, moved or
/// deleted, a cover put next to them), so that a scan reads it without anyone asking. Only a computer's own disks
/// report changes (Linux, macOS, Windows); a phone and a network share report none, and are left to the scans that run
/// anyway.
class FolderWatch {
  FolderWatch(this.onSettled, {this.quiet = const Duration(seconds: 10)});

  final void Function() onSettled;
  final Duration quiet;

  String? _folder;
  String? _skip;
  DirectoryWatcher? _watcher;
  StreamSubscription<WatchEvent>? _events;
  Timer? _settle;

  /// Completes once changes are being reported (at once when nothing is watched).
  Future<void> get ready => _watcher?.ready ?? Future.value();

  /// Whether this system reports changes; elsewhere [watch] does nothing (the fallback would read the whole folder
  /// every second).
  static bool get isSupported => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Watches [folder] instead of the one watched so far; changes under [skip] (a folder inside it) don't count. A
  /// folder that is missing, or can't be watched, is tried again on the next call.
  void watch(String folder, {String? skip}) {
    final root = AppPaths.fullPath(folder);
    if (_events != null && root == _folder && skip == _skip) return;
    stop();
    if (!isSupported || !Directory(root).existsSync()) return;
    _folder = root;
    _skip = skip;
    final watcher = _watcher = DirectoryWatcher(root);
    _events = watcher.events.listen(
      _onEvent,
      onError: (Object e) {
        WiretuneLog.warn('FolderWatch', "Cannot watch '$root' for changes ($e); the scans still find them.");
        stop();
      },
      onDone: stop, // the folder itself went away
    );
  }

  void _onEvent(WatchEvent event) {
    if (!_counts(event.path)) return;
    _settle?.cancel();
    _settle = Timer(quiet, onSettled);
  }

  /// A change to music or to a cover, outside hidden folders (which the scans skip too) and outside [_skip].
  bool _counts(String path) {
    final name = p.basename(path);
    if (!AudioFileTypes.isSupported(name) && !MetadataScanner.folderCoverNames.contains(name.toLowerCase())) {
      return false;
    }
    if (p.split(p.relative(path, from: _folder)).any((part) => part.startsWith('.'))) return false;
    final skip = _skip;
    return skip == null || !AppPaths.isPathUnderRoot(path, skip);
  }

  void stop() {
    _settle?.cancel();
    _settle = null;
    unawaited(_events?.cancel());
    _events = null;
    _watcher = null;
    _folder = null;
  }
}
