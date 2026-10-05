// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Every part of Wiretune carries one version, [WiretuneInfo.version]; a release changes it everywhere at once.
void main() {
  final parts = WiretuneInfo.version.split('.');
  final name = parts.take(3).join('.');

  test('every pubspec.yaml carries it, as name and build number', () {
    final pubspecs = ['pubspec.yaml', '../wiretune_platform/pubspec.yaml', '../../server/pubspec.yaml'];
    for (final path in [...pubspecs, '../../app/pubspec.yaml']) {
      final version = RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(File(path).readAsStringSync());
      expect(version?.group(1), '$name+${parts[3]}', reason: path);
    }
  });

  test('the Tizen package carries its name (Tizen allows three numbers)', () {
    expect(File('../../app/tizen/tizen-manifest.xml').readAsStringSync(), contains('version="$name"'));
  });
}
