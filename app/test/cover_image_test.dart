// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wiretune/src/widgets/cover_image.dart';

/// The server's covers are kept on disk: downloaded once, shown from the file after that (also after a restart), and
/// downloaded again only when the cover changed.
void main() {
  final png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAJ0lEQVR4nGN44JDg0PDA4UDDgw0GDHDWA4cEBjjLoeEBA5zlcKABAJiSGYEhhgnzAAAAAElFTkSuQmCC',
  );

  testWidgets('a cover is downloaded once, then read from the disk; a new version is downloaded again', (tester) async {
    final cache = Directory.systemTemp.createTempSync('wiretune_covers_');
    addTearDown(() => cache.deleteSync(recursive: true));
    final asked = <String>[];
    CoverArt.serverUrl = 'http://server:5200';
    CoverArt.authToken = 'sign-in-token';
    CoverArt.cacheDirectory = cache.path;
    CoverArt.client = MockClient((request) async {
      asked.add('${request.url}');
      expect(request.headers['Authorization'], 'Bearer sign-in-token');
      return http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
    });
    addTearDown(() {
      CoverArt.serverUrl = null;
      CoverArt.authToken = null;
      CoverArt.cacheDirectory = null;
      CoverArt.client = http.Client();
    });

    Future<void> show(String url) async => tester.runAsync(() async {
      final loaded = Completer<void>();
      final stream = CoverArt.provider(url, decodeWidth: 64)!.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((_, _) => loaded.complete(), onError: loaded.completeError);
      stream.addListener(listener);
      await loaded.future;
      stream.removeListener(listener);
    });

    await show('http://server:5200/api/cover/album/a1?v=1');
    expect(asked, hasLength(1));
    expect(cache.listSync(), hasLength(1));

    // As after a restart: the memory is empty, the disk is not.
    imageCache
      ..clear()
      ..clearLiveImages();
    expect(imageCache.currentSize + imageCache.liveImageCount, 0);
    await show('http://server:5200/api/cover/album/a1?v=1');
    expect(asked, hasLength(1));

    await show('http://server:5200/api/cover/album/a1?v=2');
    expect(asked, ['http://server:5200/api/cover/album/a1?v=1', 'http://server:5200/api/cover/album/a1?v=2']);
  });
}
