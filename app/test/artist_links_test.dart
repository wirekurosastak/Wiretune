// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wiretune/src/theme/app_theme.dart';
import 'package:wiretune/src/theme/palette.dart';
import 'package:wiretune/src/widgets/links.dart';
import 'package:wiretune/src/widgets/page_parts.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// A track of several artists ("Future, Lil Durk") links each of them on a computer; on a phone a tap asks which,
/// the way TIDAL does.
void main() {
  Future<List<String>> show(WidgetTester tester, List<String> names) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ArtistLinks(names, style: const TextStyle(fontSize: 13), onOpen: opened.add),
        ),
      ),
    );
    return opened;
  }

  testWidgets('each name opens its own artist', (tester) async {
    final opened = await show(tester, ['Future', 'Lil Durk']);
    expect(find.text('Future, Lil Durk', findRichText: true), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('Lil Durk'));
    await tester.tapOnText(find.textRange.ofSubstring('Future'));
    expect(opened, ['Lil Durk', 'Future']);
  });

  testWidgets('the keyboard or a remote opens the main artist', (tester) async {
    final opened = await show(tester, ['Future', 'Lil Durk']);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, ['Future']);
  });

  testWidgets("on a phone a tap on the names asks which artist to open, as TIDAL does, so a finger can't miss", (
    tester,
  ) async {
    Localizer.instance.setLanguage('en');
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(accent: Palette.dark.neutral, isTv: false),
        home: PhoneChrome(
          child: Scaffold(
            body: Center(
              child: ArtistLinks(['Future', 'Lil Durk'], style: const TextStyle(fontSize: 13), onOpen: opened.add),
            ),
          ),
        ),
      ),
    );
    await tester.tapOnText(find.textRange.ofSubstring('Future'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'not the name under the finger');
    expect(find.text(Localizer.get('ChooseArtist')), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Lil Durk'));
    await tester.pumpAndSettle();
    expect(opened, ['Lil Durk']);
    expect(find.text(Localizer.get('ChooseArtist')), findsNothing);
  });

  testWidgets('one artist is a plain link', (tester) async {
    final opened = await show(tester, ['AC/DC']);
    await tester.tap(find.text('AC/DC'));
    expect(opened, ['AC/DC']);
  });
}
