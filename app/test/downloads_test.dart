// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/cover_image.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The player's side of downloads: a downloaded track plays from its copy, its cover shows from its copy, and signing
/// out takes the downloads away.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  final audio = List<int>.generate(4000, (i) => i & 0xff);
  final cover = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAJ0lEQVR4nGN44JDg0PDA4UDDgw0GDHDWA4cEBjjLoeEBA5zlcKABAJiSGYEhhgnzAAAAAElFTkSuQmCC',
  );

  test('a downloaded track plays from its copy and shows its cover from it; signing out removes it', () async {
    final driver = FakeAudioDriver();
    final library = createLibrary();
    library.initialize();
    final onServer = TestSupport.makeServerTrack('s1', 'Naima', artist: 'John Coltrane', album: 'Giant Steps')
      ..fileSizeBytes = audio.length
      ..hasCoverArt = true;
    final session = await signedInSession(library, tracks: [onServer]);
    final folder = Directory.systemTemp.createTempSync('wiretune_app_downloads_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final downloads = DownloadService(
      library,
      session,
      directory: p.join(folder.path, 'Downloads'),
      client: MockClient((request) async {
        if (request.url.path == '/api/stream/s1') return http.Response.bytes(audio, 200);
        if (request.url.path.startsWith('/api/cover/album/')) {
          return http.Response.bytes(cover, 200, headers: {'content-type': 'image/png'});
        }
        return http.Response('', 404);
      }),
    );
    final vm = MainViewModel(TestSupport.createEngine(driver), library, session, downloadService: downloads);
    addTearDown(vm.dispose);
    await downloads.initialize();

    final track = library.getTrack('s1')!;
    vm.downloads.toggleTrack(track);
    expect(await waitUntil(() => downloads.doneCount == 1), isTrue);
    final copy = downloads.localCopy(track)!;
    expect(File(copy).readAsBytesSync(), audio);

    vm.player.playQueue([track]);
    await pumpEventQueue();
    expect(driver.lastSource, copy);
    expect(vm.audioSettings.signalPath, contains('Downloaded copy'));

    CoverArt.localCopy = downloads.localCover;
    addTearDown(() => CoverArt.localCopy = null);
    final image = CoverArt.provider(track.coverArtPath, decodeWidth: 64)! as ResizeImage;
    expect((image.imageProvider as FileImage).file.path, downloads.localCover(track.coverArtPath!));

    await vm.logout();
    expect(vm.downloads.isTrackDownloaded(track), isFalse);
    expect(await waitUntil(() => !File(copy).existsSync()), isTrue);
    expect(downloads.bytesOnDisk, 0);
  });
}
