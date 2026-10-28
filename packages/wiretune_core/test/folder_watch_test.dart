// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

@TestOn('linux || mac-os || windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The folder watch: a burst of changes to the music is one call, once things are quiet; other changes are none.
void main() {
  test(
    'music added to the folder is reported once it settles; other files, hidden ones and downloads are not',
    () async {
      final root = Directory.systemTemp.createTempSync('wiretune_watch_');
      addTearDown(() => root.deleteSync(recursive: true));
      final album = Directory(p.join(root.path, 'Album'))..createSync();
      final downloads = Directory(p.join(root.path, 'Wiretune'))..createSync();

      var settled = 0;
      final watch = FolderWatch(() => settled++, quiet: const Duration(milliseconds: 300));
      addTearDown(watch.stop);
      watch.watch(root.path, skip: downloads.path);
      await watch.ready;

      File(p.join(album.path, 'notes.txt')).writeAsStringSync('x');
      File(p.join(album.path, '.01.flac')).writeAsStringSync('x'); // hidden, as an unfinished copy often is
      File(p.join(downloads.path, '01 Downloaded.flac')).writeAsStringSync('x');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(settled, 0);

      // Three tracks and a cover arrive one after another: one call, after the last.
      for (final name in ['01.flac', '02.flac', '03.flac', 'cover.jpg']) {
        File(p.join(album.path, name)).writeAsStringSync('x');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // However long the system takes to tell, and then no second call once it has settled.
      await until(() => settled > 0);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(settled, 1);

      File(p.join(album.path, '02.flac')).deleteSync();
      await until(() => settled > 1);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(settled, 2);
    },
  );
}
