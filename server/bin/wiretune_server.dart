import 'dart:async';
import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

/// Starts the server: `wiretune_server --Wiretune:LibraryPath=/srv/music` (see docs/server.md for every setting).
Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('''
Wiretune server

Usage: wiretune_server [--Wiretune:LibraryPath=<folder>] [--Wiretune:Port=5200] [--urls=http://0.0.0.0:5200]
                       [--Wiretune:DataDirectory=<folder>] [--Wiretune:SetupCode=<code>]
                       [--Wiretune:ScanIntervalMinutes=30]

Settings can also come from appsettings.json (section "Wiretune") or environment variables (Wiretune__Port=8080).''');
    return;
  }

  ServerOptions options;
  try {
    options = ServerOptions.load(args);
    options.listenAddresses; // validate early
  } on FormatException catch (e) {
    stderr.writeln('Invalid configuration: ${e.message}');
    exitCode = 2;
    return;
  }

  final server = await WiretuneServer.start(options);

  final done = Completer<void>();
  Future<void> shutdown(ProcessSignal signal) async {
    if (done.isCompleted) return;
    WiretuneLog.info('Server', 'Shutting down (${signal.name}).');
    await server.close();
    done.complete();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
  await done.future;
  exit(0);
}
