// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Downloads against the real server: the copies are the server's files byte for byte. (That a copy plays without the
/// server is the core's download_service_test.)
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test('a downloaded album is the server files, byte for byte', () async {
    final server = await ServerFixture.start();
    addTearDown(server.close);
    final (admin, _) = await setupAdmin(server);
    await server.waitForTracks(admin, 3);

    // The player's files live apart from the server's, which go when the server is closed.
    final player = Directory.systemTemp.createTempSync('wiretune_player_');
    final repo = testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: p.join(player.path, 'Covers'));
    final session = ServerSession(library, repo);
    final downloads = DownloadService(library, session, directory: p.join(player.path, 'Downloads'));
    addTearDown(() {
      downloads.dispose();
      session.dispose();
      player.deleteSync(recursive: true);
    });
    library.initialize();
    session.initialize();
    await downloads.initialize();
    await session.connect(server.baseUrl);
    expect(await session.login('owner', adminPassword, true), isNull);

    // The fixture's files carry no tags: all three are tracks of "Unknown album".
    final album = library.albums.single;
    downloads.setAlbumDownloaded(album.id, true);
    await until(() => downloads.doneCount == 3);
    expect((downloads.doneCount, downloads.wantedCount), (3, 3));
    final files = {
      '01 First': p.join('Artist A', 'Album 1', '01 First.wav'),
      '02 Second': p.join('Artist A', 'Album 1', '02 Second.wav'),
      '01 Third': p.join('Artist B', 'Album 2', '01 Third.wav'),
    };
    for (final track in album.tracks) {
      final original = File(p.join(server.musicFolder, files[track.title])).readAsBytesSync();
      expect(File(downloads.localCopy(track)!).readAsBytesSync(), original, reason: track.title);
    }
  });
}
