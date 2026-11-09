// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wiretune/src/pages/library_pages.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Blends through the widgets: an invitation in the bell, accepted; the mix on the Playlists page, left; and inviting
/// a friend from Playlists.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
    // The desktop window's buttons ask the window manager plugin, which tests don't have.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
  });

  const anna = AccountInfo('user-2', 'anna');

  /// A signed-in app whose server keeps [blends] (a POST invites or accepts, a DELETE leaves); [requests] are the
  /// Blend requests it got.
  Future<(MainViewModel, List<String>)> start(WidgetTester tester, List<Blend> blends) async {
    final requests = <String>[];
    http.Response answer(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
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
          final path = request.url.path;
          if (path == '/api/me/recommendations') return answer([]);
          if (path == '/api/accounts') return answer([const AccountInfo('user-1', 'owner').toJson(), anna.toJson()]);
          if (!path.startsWith('/api/me/blends')) return null;
          requests.add('${request.method} $path');
          switch (request.method) {
            case 'POST':
              final other = (jsonDecode(request.body) as Map)['with'];
              final at = blends.indexWhere((b) => b.other.id == other);
              final blend = at < 0
                  ? Blend('b-new', anna, BlendState.inviting)
                  : Blend(blends[at].id, anna, BlendState.active, ['s2', 's1']);
              if (at < 0) {
                blends.add(blend);
              } else {
                blends[at] = blend;
              }
              return answer(blend.toJson());
            case 'DELETE':
              blends.removeWhere((b) => path.endsWith('/${b.id}'));
              return answer({'deleted': true});
          }
          return answer([for (final b in blends) b.toJson()]);
        },
      ),
    ))!;
    final vm = createMainViewModel(library, null, session, RemoteClient(session, connector: FakeRemoteHub().connect));
    addTearDown(vm.dispose);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await showApp(tester, vm, const Size(1400, 900));
    return (vm, requests);
  }

  Future<void> serverAnswers(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
  }

  testWidgets('an invitation in the bell is accepted; the mix is on Playlists until it is left', (tester) async {
    final (vm, requests) = await start(tester, [const Blend('b1', anna, BlendState.invited)]);
    final bell = find.byTooltip(Localizer.get('FromFriends'));
    expect(
      find.descendant(of: bell, matching: find.text('1')),
      findsOneWidget,
      reason: 'the invitation counts',
    );

    await tester.tap(bell);
    await settle(tester);
    expect(find.text(Localizer.format('BlendInvitedYou', ['anna'])), findsOneWidget);
    await tester.tap(find.text(Localizer.get('BlendAccept')));
    await serverAnswers(tester);
    expect(requests, contains('POST /api/me/blends'));
    expect(find.text(Localizer.format('BlendAccepted', ['anna'])), findsOneWidget);
    await tester.tapAt(const Offset(20, 20)); // the bell's dialog closes
    await settle(tester);

    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    final name = Localizer.format('BlendName', ['anna']);
    await tester.tap(find.text(name).first);
    await settle(tester);
    expect(find.text(Localizer.get('LabelBlend')), findsOneWidget);
    expect([for (final t in vm.playlists.selectedPlaylistTracks) t.id], ['s2', 's1'], reason: "the server's mix");

    await tester.tap(
      find.descendant(of: find.byType(DetailHeader), matching: find.byTooltip(Localizer.get('BlendLeave'))),
    );
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, Localizer.get('BlendLeave')));
    await serverAnswers(tester);
    expect(requests.last, 'DELETE /api/me/blends/b1');
    expect(vm.playlists.allPlaylists.any((p) => p.name == name), isFalse);
    await tester.pump(const Duration(seconds: 5)); // the notices go
  });

  testWidgets('Blend on Playlists invites a friend; the Blend waits for them', (tester) async {
    final (vm, requests) = await start(tester, []);
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await tester.tap(find.text(Localizer.get('BlendNew')));
    await serverAnswers(tester);
    expect(find.text('owner'), findsNothing, reason: 'not oneself');
    await tester.tap(find.text('anna'));
    await tester.pump();
    await tester.tap(find.text(Localizer.get('BlendInvite')));
    await serverAnswers(tester);
    expect(requests, ['GET /api/me/blends', 'POST /api/me/blends']);
    expect(find.text(Localizer.format('BlendInvited', ['anna'])), findsOneWidget);

    await tester.tap(find.text(Localizer.format('BlendName', ['anna'])).first);
    await settle(tester);
    expect(find.text(Localizer.format('BlendWaiting', ['anna'])), findsOneWidget);

    await tester.tap(find.text(Localizer.get('Undo')));
    await serverAnswers(tester);
    expect(requests.last, 'DELETE /api/me/blends/b-new', reason: 'the invitation taken back');
    await tester.pump(const Duration(seconds: 5)); // the notices go
  });
}
