// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

/// The server's options: the command line, the environment, and what does not parse.
void main() {
  ServerOptions parse(List<String> args, [Map<String, String> environment = const {}]) =>
      ServerOptions.fromArgs(ServerOptions.parser.parse(args), environment);

  test('without options the server listens everywhere on 5200 and picks its own folders', () {
    final options = parse([]);
    expect(options.host, '0.0.0.0');
    expect(options.port, 5200);
    expect(options.scanIntervalMinutes, 30);
    expect(options.trustProxy, isFalse);
    expect(options.logLevel, LogLevel.info);
    expect([options.libraryPath, options.dataDirectory, options.setupCode], everyElement(isNull));
  });

  test('every option can come from the environment, and the command line wins', () {
    const environment = {
      'WIRETUNE_LIBRARY': '/srv/music',
      'WIRETUNE_DATA_DIR': '/var/lib/wiretune',
      'WIRETUNE_HOST': '127.0.0.1',
      'WIRETUNE_PORT': '8080',
      'WIRETUNE_SCAN_INTERVAL': '0',
      'WIRETUNE_SETUP_CODE': 'ABCD-EFGH',
      'WIRETUNE_TRUST_PROXY': 'true',
      'WIRETUNE_LOG_LEVEL': 'debug',
    };
    final fromEnvironment = parse([], environment);
    expect(fromEnvironment.libraryPath, '/srv/music');
    expect(fromEnvironment.dataDirectory, '/var/lib/wiretune');
    expect(fromEnvironment.host, '127.0.0.1');
    expect(fromEnvironment.port, 8080);
    expect(fromEnvironment.scanIntervalMinutes, 0);
    expect(fromEnvironment.setupCode, 'ABCD-EFGH');
    expect(fromEnvironment.trustProxy, isTrue);
    expect(fromEnvironment.logLevel, LogLevel.debug);

    final overridden = parse(['--port', '9000', '--library=/mnt/music'], environment);
    expect(overridden.port, 9000);
    expect(overridden.libraryPath, '/mnt/music');
    expect(overridden.scanIntervalMinutes, 0); // still from the environment
  });

  test('a value that does not fit is refused, naming the option and its variable', () {
    final badPort = throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('WIRETUNE_PORT')));
    expect(() => parse(['--port', '70000']), badPort);
    expect(() => parse([], {'WIRETUNE_PORT': 'many'}), badPort);
    expect(() => parse(['--log-level', 'loud']), throwsFormatException);
    expect(() => parse(['--colour']), throwsFormatException);
  });
}
