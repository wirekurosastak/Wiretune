// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/settings_view_models.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wiretune/platform');
  late Directory root;
  late List<MethodCall> calls;
  Object? answer;

  setUp(() {
    root = Directory.systemTemp.createTempSync('wiretune_platform_');
    calls = [];
    answer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test('on iOS the downloads folder is created and kept out of backups; elsewhere nothing is asked', () async {
    final downloads = p.join(root.path, 'Downloads');

    await AppPlatform.forTesting(system: 'android').excludeFromBackup(downloads);
    expect(calls, isEmpty);

    await AppPlatform.forTesting(system: 'ios').excludeFromBackup(downloads);
    expect(Directory(downloads).existsSync(), isTrue);
    expect(calls.single.method, 'excludeFromBackup');
    expect(calls.single.arguments, downloads);
  });

  test('Android phones scan a folder of their own; TVs and iPhones play from a server', () {
    expect(AppPlatform.forTesting(system: 'android').supportsLocalFolder, isTrue);
    expect(AppPlatform.forTesting(system: 'android', tv: true).supportsLocalFolder, isFalse);
    expect(AppPlatform.forTesting(system: 'ios').supportsLocalFolder, isFalse);
    expect(AppPlatform.forTesting(system: 'linux').supportsLocalFolder, isTrue);
  });

  test('reading the music is asked for on Android only, and the answer is passed on', () async {
    expect(await AppPlatform.forTesting(system: 'linux').requestAudioAccess(), isTrue);
    expect(calls, isEmpty);

    final android = AppPlatform.forTesting(system: 'android');
    answer = false;
    expect(await android.requestAudioAccess(), isFalse);
    answer = true;
    expect(await android.requestAudioAccess(), isTrue);
    expect(calls.map((c) => c.method), ['requestAudioAccess', 'requestAudioAccess']);
  });

  test('a folder scan asks for the permission first and reads nothing without it', () async {
    final data = useTempDataDirectory();
    addTearDown(() => data.deleteSync(recursive: true));
    final library = createLibrary();
    var granted = false;
    var asked = 0;
    final settings = ServerSettingsViewModel(
      library,
      ServerSession(library, testRepository()),
      supportsLocalFolder: true,
      requestFolderAccess: () async {
        asked++;
        return granted;
      },
    )..localFolder = root.path;

    await settings.scanLocalFolder();
    expect(asked, 1);
    expect(settings.localFolderIsError, isTrue);
    expect(settings.localFolderMessage, Localizer.get('FolderAccessDenied'));
    expect(library.musicFolder, isNot(root.path), reason: 'nothing was scanned');

    granted = true;
    await settings.scanLocalFolder();
    expect(asked, 2);
    expect(settings.localFolderIsError, isFalse);
    expect(library.musicFolder, AppPaths.fullPath(root.path));
  });
}
