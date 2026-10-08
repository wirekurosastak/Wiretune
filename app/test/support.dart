// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/testing.dart';
import 'package:wiretune_core/wiretune_core.dart';

export 'package:wiretune_core/testing.dart';

MainViewModel createMainViewModel(
  LibraryService library, [
  WiretuneAudioEngine? engine,
  ServerSession? session,
  RemoteClient? remote,
]) => MainViewModel(
  engine ?? TestSupport.createEngine(),
  library,
  session ?? ServerSession(library, MockRepository()),
  remote: remote,
);

LibraryService createLibrary([List<Track> tracks = const []]) {
  final repo = MockRepository()..saveTracks(tracks);
  return LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
}

/// Waits (briefly) until [condition] holds; true when it does.
Future<bool> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

/// Writes a small cover (a 4 x 4 PNG in four colours) into [directory] and returns its path.
String writeCover(Directory directory) {
  final file = File(p.join(directory.path, 'cover.png'));
  file.writeAsBytesSync(
    base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAJ0lEQVR4nGN44JDg0PDA4UDDgw0GDHDWA4cEBjjLoeEBA5zlcKABAJiSGYEhhgnzAAAAAElFTkSuQmCC',
    ),
  );
  return file.path;
}
