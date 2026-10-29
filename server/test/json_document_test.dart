// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:wiretune_server/src/http_utils.dart';

/// [bytes] of JSON, e.g. a big library; small ones stay where they are, big ones go to another isolate.
JsonDocument _document(int bytes) =>
    JsonDocument(utf8.encode(jsonEncode([for (var i = 0; i * 12 < bytes; i++) 'a$i'])));

Request _request({String? acceptEncoding, String? ifNoneMatch}) => Request(
  'GET',
  Uri.parse('http://localhost/api/tracks'),
  headers: {'accept-encoding': ?acceptEncoding, 'if-none-match': ?ifNoneMatch},
);

void main() {
  for (final (name, size) in [('a small', 1000), ('a big', 300 * 1024)]) {
    group('$name document', () {
      test('has the SHA-1 of its bytes as the version, worked out once', () async {
        final document = _document(size);
        expect(await document.etag, '"${sha1.convert(document.bytes)}"');
        expect(identical(document.etag, document.etag), isTrue);
      });

      test('has a gzip form that decompresses to its bytes, made once', () async {
        final document = _document(size);
        expect(gzip.decode(await document.gzipped), document.bytes);
        expect(identical(document.gzipped, document.gzipped), isTrue);
      });

      test(
        'is answered with the compressed form to a player that accepts it, and not modified to one that has it',
        () async {
          final document = _document(size);
          final etag = await document.etag;

          final plain = await versionedJson(_request(), document);
          expect(plain.headers['content-encoding'], isNull);
          expect(await plain.read().expand((c) => c).toList(), document.bytes);

          final compressed = await versionedJson(_request(acceptEncoding: 'br, gzip;q=0.8'), document);
          expect(compressed.headers['content-encoding'], 'gzip');
          expect(compressed.headers['etag'], etag);
          expect(gzip.decode(await compressed.read().expand((c) => c).toList()), document.bytes);

          final unchanged = await versionedJson(_request(acceptEncoding: 'gzip', ifNoneMatch: etag), document);
          expect(unchanged.statusCode, 304);
          expect(await unchanged.readAsString(), isEmpty);
        },
      );
    });
  }
}
