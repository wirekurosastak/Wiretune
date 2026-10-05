// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The string table: three complete languages that agree on their placeholders, and the lookup rules.
void main() {
  tearDown(() => Localizer.instance.setLanguage('en'));

  Set<String> placeholders(String text) => RegExp(r'\{(\d+)(?::[^}]*)?\}').allMatches(text).map((m) => m[1]!).toSet();

  test('every key is translated into all three languages', () {
    for (final MapEntry(:key, :value) in allStrings.entries) {
      final (hu, en, de) = value;
      expect([hu, en, de].every((s) => s.trim().isNotEmpty), isTrue, reason: key);
    }
  });

  test('the translations of a key use the same placeholders', () {
    for (final MapEntry(:key, :value) in allStrings.entries) {
      final (hu, en, de) = value;
      expect(placeholders(hu), placeholders(en), reason: '$key (hu)');
      expect(placeholders(de), placeholders(en), reason: '$key (de)');
    }
  });

  test('a singular form belongs to a plural key with the same placeholders', () {
    for (final key in allStrings.keys.where((k) => k.endsWith('_One'))) {
      final plural = key.substring(0, key.length - 4);
      expect(allStrings.containsKey(plural), isTrue, reason: key);
      expect(placeholders(allStrings[key]!.$2), placeholders(allStrings[plural]!.$2), reason: key);
    }
  });

  test('format picks the singular form for one and the plural otherwise', () {
    Localizer.instance.setLanguage('en');
    expect(Localizer.format('TrackCount', [1]), '1 track');
    expect(Localizer.format('TrackCount', [3]), '3 tracks');
  });

  test('an unknown key shows up bracketed, and the language follows setLanguage', () {
    expect(Localizer.get('NoSuchKey'), '[NoSuchKey]');
    Localizer.instance.setLanguage('de');
    expect(Localizer.get('Rename'), 'Umbenennen');
    Localizer.instance.setLanguage('hu');
    expect(Localizer.get('Rename'), 'Átnevezés');
  });
}
