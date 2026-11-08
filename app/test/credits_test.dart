// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// A track's credits from its menu: what the server knows, one line per role, an instrument by its name.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
  });

  testWidgets("a track's menu opens its credits, one line per role and per instrument", (tester) async {
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        tracks: [TestSupport.makeServerTrack('s1', 'The Seed', artist: 'The Roots', album: 'Phrenology')],
        respond: (request) => request.url.path == '/api/tracks/s1/credits'
            ? http.Response(
                jsonEncode({
                  'credits': [
                    for (final credit in const [
                      Credit(CreditRoles.composer, 'Cody ChesnuTT'),
                      Credit(CreditRoles.composer, 'Black Thought'),
                      Credit(CreditRoles.producer, 'Questlove'),
                      Credit(CreditRoles.instrument, 'Jef Lee Johnson', detail: 'Guitar'),
                    ])
                      credit.toJson(),
                  ],
                }),
                200,
                headers: {'content-type': 'application/json'},
              )
            : null,
      ),
    ))!;
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);

    final row = find.ancestor(of: find.text('The Seed'), matching: find.byType(InkWell)).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('Credits')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    expect(find.text(Localizer.get('CreditComposer')), findsOneWidget);
    expect(find.text('Cody ChesnuTT, Black Thought'), findsOneWidget, reason: 'one line, both names');
    expect(find.text(Localizer.get('CreditProducer')), findsOneWidget);
    expect(find.text('Guitar'), findsOneWidget, reason: 'an instrument by its name');
    expect(find.text('Jef Lee Johnson'), findsOneWidget);
  });

  testWidgets("a file only this device has shows the composer its tags name, or says nothing is known", (tester) async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'Naima', artist: 'John Coltrane', album: 'Giant Steps')
        ..details = const TrackDetails(composer: 'John Coltrane'),
      TestSupport.makeTrack('2', 'Mr. P.C.', artist: 'John Coltrane', album: 'Giant Steps'),
    ]);
    library.initialize();
    final vm = createMainViewModel(library);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);

    Future<void> openCredits(String title) async {
      final row = find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
      await settle(tester);
      await tester.tap(find.text(Localizer.get('Credits')));
      await settle(tester);
    }

    await openCredits('Naima');
    expect(find.text(Localizer.get('CreditComposer')), findsOneWidget);
    expect(find.text('John Coltrane'), findsWidgets);
    await tester.tapAt(const Offset(200, 40)); // away from the sheet
    await settle(tester);

    await openCredits('Mr. P.C.');
    expect(find.text(Localizer.get('CreditsNone')), findsOneWidget);
  });
}
