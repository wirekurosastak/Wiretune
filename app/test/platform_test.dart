// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wiretune/platform');
  late Directory root;
  late List<MethodCall> calls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('wiretune_platform_');
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
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
}
