// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wiretune/src/widgets/links.dart';

/// A track of several artists ("Future, Lil Durk") links each of them, the way TIDAL does.
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

  testWidgets('one artist is a plain link', (tester) async {
    final opened = await show(tester, ['AC/DC']);
    await tester.tap(find.text('AC/DC'));
    expect(opened, ['AC/DC']);
  });
}
