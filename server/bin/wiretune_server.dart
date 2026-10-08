// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

const String _about =
    'Wiretune server ${WiretuneInfo.version}: indexes a music folder and streams it to the Wiretune players.\n'
    '${WiretuneInfo.copyright}. Free software under the GNU AGPL v3 (with the terms in NOTICE.md), with no warranty.\n'
    'Source: ${WiretuneInfo.sourceUrl}';

const String _environment =
    'Every option can also be set in the environment: --scan-interval 0 is WIRETUNE_SCAN_INTERVAL=0, --trust-proxy is\n'
    'WIRETUNE_TRUST_PROXY=true. The command line wins.';

/// Starts the server: `wiretune_server --library /srv/music` (docs/server.md has every option).
Future<void> main(List<String> args) async {
  final ServerOptions options;
  try {
    final results = ServerOptions.parser.parse(args);
    if (results.flag('help')) {
      stdout.writeln('$_about\n\nUsage: wiretune_server [options]\n\n${ServerOptions.parser.usage}\n\n$_environment');
      return;
    }
    if (results.flag('version')) {
      stdout.writeln(WiretuneInfo.version);
      return;
    }
    options = ServerOptions.fromArgs(results);
  } on FormatException catch (e) {
    final hint = e is ArgParserException ? '\n\n${ServerOptions.parser.usage}' : '';
    stderr.writeln('${e.message}$hint');
    exitCode = 64;
    return;
  }

  final WiretuneServer server;
  try {
    server = await WiretuneServer.start(options);
  } on IncompatibleDatabaseException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen on ${options.host}:${options.port}: ${e.osError?.message ?? e.message}');
    exitCode = 1;
    return;
  }

  final done = Completer<void>();
  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    // A second Ctrl+C while the first one is still closing must not close everything again.
    if (stopping) return;
    stopping = true;
    WiretuneLog.info('Server', 'Shutting down (${signal.name}).');
    await server.close();
    done.complete();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
  await done.future;
  exit(0);
}
