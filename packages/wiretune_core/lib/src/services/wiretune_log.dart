// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

enum LogLevel { debug, info, warn, error }

/// The log of the player or the server: `[time] [LEVEL] [category] message` lines on the console and in a file that is
/// moved to `.1` at 10 MiB. Every line passes through [redact], because stream URLs carry tokens. Its own failures
/// (opening, moving or closing its file) are let go of: the log must never stop what it records.
abstract final class WiretuneLog {
  static const int _maxLogBytes = 10 * 1024 * 1024;
  static final RegExp _tokenPattern = RegExp(r'''token=[^&\s"']+''');

  static String? _logFilePath;
  static RandomAccessFile? _file;
  static int _bytesWritten = 0;
  static bool _initAttempted = false;

  /// Info by default: Debug lines carry paths, server addresses and device names. `WIRETUNE_LOG_LEVEL` (debug, info,
  /// warn, error) raises or lowers it for a troubleshooting session.
  static LogLevel minimumLevel = _levelFromEnvironment() ?? LogLevel.info;

  /// Whether lines are also printed to the console (the Flutter app turns it off in release builds).
  static bool writeToConsole = true;

  /// The settings a background isolate needs to log like this one (isolates do not share static state).
  static (String?, LogLevel, bool) get isolateSettings => (_logFilePath, minimumLevel, writeToConsole);

  /// The log file, once [initialize] opened one.
  static String? get logPath => _logFilePath;

  /// Applies [isolateSettings] of the spawning isolate; call it first thing in a background isolate.
  static void adoptIsolateSettings((String?, LogLevel, bool) settings) {
    _logFilePath = settings.$1;
    minimumLevel = settings.$2;
    writeToConsole = settings.$3;
  }

  static LogLevel? _levelFromEnvironment() {
    final value = Platform.environment['WIRETUNE_LOG_LEVEL']?.trim().toLowerCase();
    if (value == null) return null;
    for (final level in LogLevel.values) {
      if (level.name == value) return level;
    }
    return null;
  }

  /// Opens the log file. Calling it again with another path switches files (the server uses its own data directory);
  /// calling it without arguments after a successful open does nothing.
  static void initialize({String? path, LogLevel? level}) {
    if (level != null) minimumLevel = level;
    if (_file != null && (path == null || path == _logFilePath)) return;

    _initAttempted = true;
    _logFilePath = path ?? _logFilePath ?? _defaultLogPath();
    _openFile(_logFilePath!);
    info('WiretuneLog', '=== Wiretune logging initialized (Log: $_logFilePath, Level: ${minimumLevel.name}) ===');
  }

  static void _openFile(String path) {
    try {
      _file?.closeSync();
    } catch (_) {}
    _file = null;

    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      if (file.existsSync() && file.lengthSync() > _maxLogBytes) {
        final backup = File('$path.1');
        try {
          if (backup.existsSync()) backup.deleteSync();
        } catch (_) {}
        try {
          file.renameSync(backup.path);
        } catch (_) {}
      }
      final handle = File(path).openSync(mode: FileMode.append);
      final length = handle.lengthSync();
      // If the rotation above failed (file in use), do not retry it on every line: count from zero again.
      _bytesWritten = length > _maxLogBytes ? 0 : length;
      _file = handle;
    } catch (e) {
      try {
        stderr.writeln("[WiretuneLog] Failed to open log file '$path': $e");
      } catch (_) {}
    }
  }

  static void _writeLine(String line) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeStringSync('$line\n');
      _bytesWritten += line.length + 1;
      if (_bytesWritten > _maxLogBytes && _logFilePath != null) _openFile(_logFilePath!);
    } catch (_) {
      // Logging must never take the application down.
    }
  }

  static void log(LogLevel level, String category, String message, [Object? error, StackTrace? stackTrace]) {
    if (level.index < minimumLevel.index) return;

    final line = _format(DateTime.now(), level, category, message, error, stackTrace);

    if (writeToConsole) {
      try {
        if (level.index >= LogLevel.warn.index) {
          stderr.writeln(line);
        } else {
          stdout.writeln(line);
        }
      } catch (_) {
        // No console.
      }
    }

    if (!_initAttempted) initialize();
    _writeLine(line);
  }

  /// `[time] [LEVEL] [category] message`, with the error and its stack trace, and every token blanked.
  static String _format(
    DateTime time,
    LogLevel level,
    String category,
    String message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${time.millisecond.toString().padLeft(3, '0')}';
    final errorText = error == null ? '' : ' | Exception: $error${stackTrace == null ? '' : '\n$stackTrace'}';
    return redact('[$stamp] [${level.name.toUpperCase().padRight(5)}] [$category] $message$errorText');
  }

  /// Replaces the value of every `token=` query parameter with `***`.
  static String redact(String text) => text.replaceAll(_tokenPattern, 'token=***');

  static void debug(String category, String message) => log(LogLevel.debug, category, message);
  static void info(String category, String message) => log(LogLevel.info, category, message);
  static void warn(String category, String message) => log(LogLevel.warn, category, message);
  static void error(String category, String message, [Object? error, StackTrace? stackTrace]) =>
      log(LogLevel.error, category, message, error, stackTrace);

  static String _defaultLogPath() {
    try {
      return p.join(AppPaths.getDataDirectory(), 'wiretune.log');
    } catch (_) {
      return p.join(Directory.systemTemp.path, 'wiretune.log');
    }
  }
}
