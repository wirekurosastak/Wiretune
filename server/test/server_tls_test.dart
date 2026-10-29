// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/wiretune_server.dart';

import 'support.dart';

/// The server speaking HTTPS itself, with a certificate made here (skipped without `openssl`).
void main() {
  final openssl = hasTool('openssl', 'version');
  late Directory folder;
  late String certificate;
  late String key;

  ServerOptions options({String? cert, String? privateKey}) => ServerOptions(
    musicFolder: p.join(folder.path, 'library'),
    dataDirectory: p.join(folder.path, 'data'),
    scanIntervalMinutes: 0,
    setupCode: setupCode,
    host: '127.0.0.1',
    port: 0,
    tlsCertificate: cert,
    tlsKey: privateKey,
  );

  setUpAll(() {
    WiretuneLog.writeToConsole = false;
    folder = Directory.systemTemp.createTempSync('wiretune_tls_');
    Directory(p.join(folder.path, 'library')).createSync();
    certificate = p.join(folder.path, 'cert.pem');
    key = p.join(folder.path, 'key.pem');
    if (!openssl) return;
    final made = Process.runSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost',
      '-keyout', key, '-out', certificate, //
    ]);
    if (made.exitCode != 0) throw StateError('openssl failed: ${made.stderr}');
  });
  tearDownAll(() => folder.deleteSync(recursive: true));

  group('with a certificate', skip: openssl ? false : 'openssl is not installed', () {
    test('the server answers HTTPS, and no longer plain HTTP', () async {
      final server = await WiretuneServer.start(options(cert: certificate, privateKey: key));
      addTearDown(server.close);

      // The certificate is self-signed, so this client has to be told to accept it.
      final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
      addTearDown(client.close);
      final request = await client.getUrl(Uri.parse('https://127.0.0.1:${server.port}/api/auth/setup-required'));
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(jsonDecode(await response.transform(utf8.decoder).join()), {'setupRequired': true});

      final plain = HttpClient();
      addTearDown(plain.close);
      await expectLater(
        plain.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/auth/setup-required')).then((r) => r.close()),
        throwsA(isA<Exception>()),
      );

      // A client that doesn't trust the certificate is refused, as it should be.
      final strict = HttpClient();
      addTearDown(strict.close);
      await expectLater(
        strict.getUrl(Uri.parse('https://127.0.0.1:${server.port}/api/auth/setup-required')).then((r) => r.close()),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('a key that does not belong to the certificate stops the start', () async {
      final other = p.join(folder.path, 'other-key.pem');
      final made = Process.runSync('openssl', ['genrsa', '-out', other, '2048']);
      expect(made.exitCode, 0);
      await expectLater(
        WiretuneServer.start(options(cert: certificate, privateKey: other)),
        throwsA(isA<TlsException>()),
      );
    });
  });
}
