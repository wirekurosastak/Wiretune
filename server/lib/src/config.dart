// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:args/args.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The server's settings. They come from the command line; every option can also be given in the environment
/// (`--scan-interval 0` is `WIRETUNE_SCAN_INTERVAL=0`, `--trust-proxy` is `WIRETUNE_TRUST_PROXY=true`), and the command
/// line wins.
class ServerOptions {
  ServerOptions({
    this.libraryPath,
    this.dataDirectory,
    this.host = '0.0.0.0',
    this.port = 5200,
    this.scanIntervalMinutes = 30,
    this.setupCode,
    this.trustProxy = false,
    this.logLevel = LogLevel.info,
  });

  /// The music folder, absolute or relative to the working directory. Null: the user's music folder.
  final String? libraryPath;

  /// Where the database, cover cache and log live. Null: `Wiretune/Server` in the user's application data.
  final String? dataDirectory;

  /// The address to listen on: `0.0.0.0` (every IPv4 interface), `::` (every interface), `127.0.0.1`, a host name.
  final String host;

  /// The port to listen on; 0 picks a free one.
  final int port;

  /// Background rescans; 0 turns them off (scans at start-up and on request still run).
  final int scanIntervalMinutes;

  /// The code that creates the first account. Null: a random one at every start, printed in the log.
  final String? setupCode;

  /// Whether the client's address comes from `X-Forwarded-For`: only behind a reverse proxy.
  final bool trustProxy;

  final LogLevel logLevel;

  static final ArgParser parser = ArgParser(usageLineLength: 120)
    ..addOption('library', valueHelp: 'folder', help: 'The music folder. Default: your Music folder.')
    ..addOption(
      'data-dir',
      valueHelp: 'folder',
      help: 'Database, cover cache and log. Default: Wiretune/Server in your app data.',
    )
    ..addOption('host', valueHelp: 'address', defaultsTo: '0.0.0.0', help: 'Where to listen: 0.0.0.0, ::, 127.0.0.1, …')
    ..addOption('port', valueHelp: 'number', defaultsTo: '5200')
    ..addOption('scan-interval', valueHelp: 'minutes', defaultsTo: '30', help: 'Background rescans; 0 turns them off.')
    ..addOption(
      'setup-code',
      valueHelp: 'code',
      help: 'The code for creating the first account. Default: a random one.',
    )
    ..addFlag('trust-proxy', negatable: false, help: 'Take the client address from X-Forwarded-For (behind a proxy).')
    ..addOption('log-level', valueHelp: 'level', defaultsTo: 'info', help: 'debug, info, warn or error.')
    ..addFlag('version', negatable: false, help: 'Show the version.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  /// Reads the options from [results], falling back to the `WIRETUNE_*` variables of [environment]. Throws
  /// [FormatException] for a value that does not fit.
  static ServerOptions fromArgs(ArgResults results, [Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String variable(String name) => 'WIRETUNE_${name.toUpperCase().replaceAll('-', '_')}';
    String? fromEnv(String name) {
      final value = env[variable(name)]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    String? text(String name) => results.wasParsed(name) ? results.option(name) : fromEnv(name) ?? results.option(name);
    int number(String name, int max) {
      final value = text(name)!;
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < 0 || parsed > max) {
        throw FormatException('--$name (${variable(name)}) must be a whole number from 0 to $max, not "$value".');
      }
      return parsed;
    }

    final level = text('log-level')!;
    return ServerOptions(
      libraryPath: text('library'),
      dataDirectory: text('data-dir'),
      host: text('host')!,
      port: number('port', 65535),
      scanIntervalMinutes: number('scan-interval', 60 * 24 * 365),
      setupCode: text('setup-code'),
      trustProxy: results.flag('trust-proxy') || const {'1', 'true', 'yes'}.contains(fromEnv('trust-proxy')),
      logLevel:
          LogLevel.values.asNameMap()[level.toLowerCase()] ??
          (throw FormatException('--log-level (WIRETUNE_LOG_LEVEL) must be debug, info, warn or error, not "$level".')),
    );
  }

  /// The music folder to scan: [libraryPath] made absolute, or the user's music folder when none was given. A folder
  /// that does not exist (yet) is kept: the scans say so in the log until it appears, e.g. once a share is mounted.
  String resolveLibraryRoot() {
    final configured = libraryPath;
    if (configured != null && configured.trim().isNotEmpty) return AppPaths.fullPath(configured);
    final music = AppPaths.fullPath(AppPaths.musicFolder());
    WiretuneLog.warn('Server', "No music folder given; using '$music'. Choose one with --library.");
    return music;
  }
}
