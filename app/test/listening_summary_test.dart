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

/// The listening summary, opened from the card at the top of Playlists: this year from the server's play log, or all
/// time from the play counts; nothing hidden counts.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
  });

  Future<void> openSummary(WidgetTester tester) async {
    await tester.tap(find.text(Localizer.get('ListeningSummary')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
  }

  testWidgets('without a server, all time: the most played first, with the minutes and plays, a hidden one left out', (
    tester,
  ) async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue'),
      TestSupport.makeTrack('2', 'Naima', artist: 'John Coltrane', album: 'Giant Steps'),
      TestSupport.makeTrack('3', 'Secret', artist: 'Nobody', album: 'Hidden'),
    ]);
    library.initialize();
    for (final id in ['1', '1', '2', '3', '3', '3']) {
      library.recordPlay(id);
    }
    library.setHidden(HiddenKind.track, '3', true);
    final vm = createMainViewModel(library);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await openSummary(tester);

    expect(find.text(Localizer.get('SummaryThisYear')), findsNothing, reason: 'no play log without a server');
    expect(find.text(Localizer.format('SummaryPlays', [3])), findsOneWidget, reason: 'the hidden plays left out');
    expect(find.text('Secret'), findsNothing);
    final miles = tester.getTopLeft(find.text('Miles Davis').first).dy;
    expect(miles, lessThan(tester.getTopLeft(find.text('John Coltrane').first).dy), reason: 'played more');
  });

  testWidgets('a top track plays the top tracks from it; Back from an album opened there brings the summary back', (
    tester,
  ) async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue'),
      TestSupport.makeTrack('2', 'Naima', artist: 'John Coltrane', album: 'Giant Steps'),
    ]);
    library.initialize();
    for (final id in ['1', '1', '2']) {
      library.recordPlay(id);
    }
    final vm = createMainViewModel(library);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await openSummary(tester);

    await tester.tap(find.text('Naima').last);
    await settle(tester);
    expect([for (final item in vm.player.queueItems) item.track.title], ['So What', 'Naima']);
    expect(vm.player.currentTrack?.title, 'Naima');
    expect(vm.player.playingFrom, Localizer.get('ListeningSummary'));

    await openSummary(tester);
    await tester.tap(find.text('Giant Steps').last);
    await settle(tester);
    expect((vm.selectedTab, vm.selectedSection), (AppSection.playlists, AppSection.albums));
    expect(vm.tryNavigateBack(), isTrue);
    await settle(tester);
    await settle(tester);
    expect(vm.selectedSection, AppSection.playlists);
    expect(find.text(Localizer.get('SummaryTopAlbums').toUpperCase()), findsOneWidget, reason: 'the summary again');
  });

  testWidgets("with a server, this year from its play log; all time from the counts", (tester) async {
    final asked = <String>[];
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        tracks: [
          TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps'),
          TestSupport.makeServerTrack('s2', 'Naima', artist: 'John Coltrane', album: 'Giant Steps', trackNumber: 2),
        ],
        respond: (request) {
          // An account from before this year: its year is in the play log alone.
          final old = UserInfo('user-1', 'owner', true, DateTime.utc(2020), null);
          if (request.url.path == '/api/auth/me') return http.Response(jsonEncode(old.toJson()), 200);
          if (request.url.path == '/api/auth/login') {
            return http.Response(jsonEncode(AuthResponse('t', old, DateTime.utc(2099)).toJson()), 200);
          }
          if (request.url.path != '/api/me/plays' || request.method != 'GET') return null;
          asked.add(request.url.query);
          return http.Response(
            jsonEncode({
              'plays': {'s2': 4},
              'since': formatIsoUtc(DateTime.utc(2026, 11, 8)),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      ),
    ))!;
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await openSummary(tester);

    final from = parseIsoUtc(Uri.splitQueryString(asked.first)['from']);
    expect(from, DateTime(DateTime.now().year).toUtc(), reason: 'from the start of this year, here');
    expect(find.text(Localizer.format('SummaryPlays', [4])), findsWidgets);
    expect(find.text('Naima'), findsOneWidget);
    expect(find.textContaining('2026-11-08'), findsOneWidget, reason: 'counted since the log began');

    // This month: from its first day.
    await tester.tap(find.text(Localizer.get('SummaryThisMonth')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
    final now = DateTime.now();
    expect(parseIsoUtc(Uri.splitQueryString(asked.last)['from']), DateTime(now.year, now.month).toUtc());

    await tester.tap(find.text(Localizer.get('SummaryAllTime')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
    expect(find.text(Localizer.get('SummaryNone')), findsOneWidget, reason: 'no counts on this account yet');
  });

  testWidgets("an account made this year has its whole counts as this year's, its plays before the log too", (
    tester,
  ) async {
    var asked = 0;
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        tracks: [TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps')],
        respond: (request) {
          final made = UserInfo('user-1', 'owner', true, DateTime.now().toUtc(), null);
          if (request.url.path == '/api/auth/login') {
            return http.Response(jsonEncode(AuthResponse('t', made, DateTime.utc(2099)).toJson()), 200);
          }
          if (request.url.path == '/api/me/plays') asked++;
          return null;
        },
      ),
    ))!;
    library.recordPlay('s1');
    library.recordPlay('s1');
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await openSummary(tester);

    expect(find.text(Localizer.get('SummaryThisYear')), findsOneWidget);
    expect(
      find.text(Localizer.format('SummaryPlays', [2])),
      findsWidgets,
      reason: "the counts: all of them this year's",
    );
    expect(asked, 0, reason: 'no log to ask');
  });
}
