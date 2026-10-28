// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The local folder stays current without a Scan: music copied in while the player was closed shows at start, the
/// player's own downloads in it are no local music, and a folder that looks empty (an unplugged drive) empties nothing.
void main() {
  setUpAll(useTempDataDirectory);

  late Directory root;
  late LibraryRepository repo;
  late LibraryService library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('wiretune_local_');
    writeWav(p.join(root.path, 'Music', 'Album', '01 One.wav'), 44100);
    repo = testRepository();
    library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(root.path, 'Covers'));
    library.initialize();
    await library.scanFolder(p.join(root.path, 'Music'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<MainViewModel> startPlayer() async {
    final session = ServerSession(library, repo);
    final downloads = DownloadService(
      library,
      session,
      directory: p.join(root.path, 'Music', 'Wiretune'),
      workDirectory: p.join(root.path, 'DownloadCache'),
    );
    final vm = MainViewModel(
      TestSupport.createEngine(),
      library,
      session,
      capabilities: const DeviceCapabilities(supportsLocalFolder: true),
      downloadService: downloads,
    );
    addTearDown(vm.dispose);
    await vm.start();
    return vm;
  }

  test('music copied in while the player was closed shows at start, its own downloads do not', () async {
    writeWav(p.join(root.path, 'Music', 'Album', '02 Two.wav'), 44100);
    writeWav(p.join(root.path, 'Music', 'Wiretune', 'Artist', 'Album', '01 Downloaded.wav'), 44100);

    await startPlayer();
    await until(() => library.tracks.length == 2);
    expect(library.tracks.map((t) => t.title), unorderedEquals(['01 One', '02 Two']));
  });

  test('a folder that looks empty, like an unplugged drive, leaves the library as it is', () async {
    Directory(p.join(root.path, 'Music', 'Album')).deleteSync(recursive: true);

    await startPlayer();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(library.tracks.map((t) => t.title), ['01 One']);
  });
}
