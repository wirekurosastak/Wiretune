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
  session ?? ServerSession(library, testRepository()),
  remote: remote,
);

/// A library over a throw-away database that holds [tracks], with [favorites] (track ID -> when marked) and [plays] as
/// an earlier session left them.
LibraryService createLibrary([
  List<Track> tracks = const [],
  Map<String, DateTime?> favorites = const {},
  Map<String, PlayStats> plays = const {},
]) {
  final repo = testRepository()
    ..replaceAllTracks(tracks)
    ..saveUserData([for (final t in tracks) t.id], favorites, plays);
  return LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
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
