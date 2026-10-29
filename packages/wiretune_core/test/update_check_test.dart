// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The update check, against a stub of GitHub's latest-release route and its downloads.
void main() {
  late Directory dir;
  late List<String> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wiretune_update_');
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final apk = utf8.encode('the new player');
  final apkSum = '${sha256.convert(apk)}';

  String latest(String tag, {Map<String, String>? files}) => jsonEncode({
    'tag_name': tag,
    'html_url': 'https://github.test/releases/$tag',
    'assets': [
      for (final MapEntry(:key, :value) in (files ?? {'wiretune.apk': 'https://dl.test/wiretune.apk'}).entries)
        {'name': key, 'browser_download_url': value},
      {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://dl.test/SHA256SUMS.txt'},
    ],
  });

  UpdateCheck create(http.Response Function(http.Request request) respond) => UpdateCheck(
    client: MockClient((request) async {
      requests.add('${request.url}');
      return respond(request);
    }),
    latestUrl: Uri.parse('https://api.test/latest'),
  );

  http.Response route(http.Request request, {String tag = 'v1.1.2026', List<int>? file, String? sums}) =>
      switch (request.url.path) {
        '/latest' => http.Response(latest(tag), 200),
        '/wiretune.apk' => http.Response.bytes(file ?? apk, 200),
        '/SHA256SUMS.txt' => http.Response(sums ?? '$apkSum  wiretune.apk\n0000  other\n', 200),
        _ => http.Response('', 404),
      };

  test('versions compare part by part, a missing part as 0', () {
    expect(UpdateCheck.compareVersions('1.1.2026', '1.0.2026'), 1);
    expect(UpdateCheck.compareVersions('1.10.2026', '1.9.2026'), 1);
    expect(UpdateCheck.compareVersions('1.0.2026', '1.0.2026'), 0);
    expect(UpdateCheck.compareVersions('1.0', '1.0.0'), 0);
    expect(UpdateCheck.compareVersions('1.0.2026', '2.0.2025'), -1);
    expect(UpdateCheck.currentVersion, WiretuneInfo.version.substring(0, WiretuneInfo.version.lastIndexOf('.')));
  });

  test('a newer release is offered, the same or an older one is not', () async {
    final check = create(route);
    final release = await check.newer('1.0.2026');
    expect(release?.version, '1.1.2026');
    expect(release?.files.keys, containsAll(['wiretune.apk', 'SHA256SUMS.txt']));
    expect(await check.newer('1.1.2026'), isNull);
    expect(await check.newer('1.2.2026'), isNull);
    expect(requests, everyElement('https://api.test/latest'));
  });

  test('no release yet is nothing newer; an error or a strange answer throws', () async {
    expect(await create((_) => http.Response('{"message":"Not Found"}', 404)).newer('1.0.2026'), isNull);
    expect(
      create((_) => http.Response('rate limited', 403)).newer('1.0.2026'),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('403'))),
    );
    expect(create((_) => http.Response('<html>', 200)).newer('1.0.2026'), throwsA(isA<UpdateException>()));
    expect(
      create((_) => http.Response('{"tag_name":"nightly"}', 200)).newer('1.0.2026'),
      throwsA(isA<UpdateException>()),
      reason: 'a tag that is no version',
    );
  });

  test('only https files count, and a file is found by its whole name', () async {
    final check = create(
      (_) => http.Response(
        latest(
          'v1.1.2026',
          files: {
            'wiretune_1.1.2026-3_amd64.deb': 'https://dl.test/a.deb',
            'wiretune_1.1.2026-3_amd64.deb.zsync': 'https://dl.test/a.zsync',
            'plain.apk': 'http://dl.test/plain.apk',
          },
        ),
        200,
      ),
    );
    final release = (await check.newer('1.0.2026'))!;
    expect(release.files.containsKey('plain.apk'), isFalse);
    expect(release.fileMatching(RegExp(r'wiretune_1\.1\.2026-[0-9]+_amd64\.deb')), 'wiretune_1.1.2026-3_amd64.deb');
    expect(release.fileMatching(RegExp(r'wiretune_1\.1\.2026-[0-9]+_arm64\.deb')), isNull);
  });

  test('a download is checked against the release checksums and reports its progress', () async {
    final check = create(route);
    final release = (await check.newer('1.0.2026'))!;
    final progress = <double>[];
    final file = await check.download(release, 'wiretune.apk', dir.path, onProgress: progress.add);
    expect(file.readAsBytesSync(), apk);
    expect(progress.last, 1.0);
  });

  test('a file whose checksum differs, or that the checksums leave out, is refused and not kept', () async {
    final tampered = create((request) => route(request, file: utf8.encode('something else')));
    final release = (await tampered.newer('1.0.2026'))!;
    expect(
      tampered.download(release, 'wiretune.apk', dir.path),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('checksum'))),
    );
    await Future<void>.delayed(Duration.zero);
    expect(File('${dir.path}/wiretune.apk').existsSync(), isFalse);

    final unlisted = create((request) => route(request, sums: '$apkSum  another.apk\n'));
    expect(
      unlisted.download((await unlisted.newer('1.0.2026'))!, 'wiretune.apk', dir.path),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('lists no'))),
    );
    expect(unlisted.download(const Release('1.1.2026', {}), 'wiretune.apk', dir.path), throwsA(isA<UpdateException>()));
  });
}
