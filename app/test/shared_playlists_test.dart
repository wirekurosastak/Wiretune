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
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Shared playlists through the widgets: an invitation joined from the bell; another's playlist, by its owner, left;
/// and sharing one's own.
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

  testWidgets("a friend's playlist is joined from the bell and left; one's own is shared", (tester) async {
    final requests = <String>[];
    var joined = false;
    var sharedWithAnna = false;
    http.Response answer(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    PlaylistData playlist(String id, String name, List<String> tracks, [PlaylistSharing? sharing]) =>
        PlaylistData(id, name, null, tracks, DateTime.utc(2026), DateTime.utc(2026), sharing ?? PlaylistSharing.none);
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
          if (path == '/api/me/recommendations' || path == '/api/me/blends') return answer([]);
          if (path == '/api/accounts') return answer([const AccountInfo('user-1', 'owner').toJson(), anna.toJson()]);
          if (path == '/api/me/data') {
            return answer(
              UserDataSnapshot([], [], [
                playlist('mine', 'Mine', ['s1'], sharedWithAnna ? const PlaylistSharing(invited: [anna]) : null),
                if (joined) playlist('jazz', 'Jazz nights', ['s2'], const PlaylistSharing(owner: anna)),
              ]).toJson(),
            );
          }
          if (!path.startsWith('/api/me/playlist')) return null;
          requests.add('${request.method} $path');
          if (path == '/api/me/playlist-invites') {
            return answer([if (!joined) const PlaylistInvite('jazz', 'Jazz nights', anna, 1).toJson()]);
          }
          if (request.method == 'POST' && path == '/api/me/playlist-invites/jazz') joined = true;
          if (path == '/api/me/playlists/mine/members/user-2') sharedWithAnna = request.method == 'PUT';
          return answer({'ok': true});
        },
      ),
    ))!;
    final vm = createMainViewModel(library, null, session, RemoteClient(session, connector: FakeRemoteHub().connect));
    addTearDown(vm.dispose);
    Future<void> serverAnswers() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
    }

    await serverAnswers();
    await showApp(tester, vm, const Size(1400, 900));

    // The bell: anna's invitation, joined.
    final bell = find.byTooltip(Localizer.get('FromFriends'));
    expect(find.descendant(of: bell, matching: find.text('1')), findsOneWidget);
    await tester.tap(bell);
    await settle(tester);
    expect(find.text(Localizer.format('PlaylistInvitedYou', ['anna', 'Jazz nights'])), findsOneWidget);
    await tester.tap(find.text(Localizer.get('PlaylistJoin')));
    await serverAnswers();
    expect(requests, contains('POST /api/me/playlist-invites/jazz'));
    await tester.tapAt(const Offset(20, 20)); // the bell's dialog closes
    await settle(tester);

    // Anna's playlist: by her, not to be renamed, left.
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await tester.tap(find.text('Jazz nights').first);
    await settle(tester);
    expect(find.text(Localizer.format('PlaylistBy', ['anna'])), findsOneWidget);
    expect(find.byTooltip(Localizer.get('Rename')), findsNothing);
    final header = find.byType(DetailHeader);
    expect(find.descendant(of: header, matching: find.byTooltip(Localizer.get('PlaylistShare'))), findsNothing);
    await tester.tap(find.descendant(of: header, matching: find.byTooltip(Localizer.get('PlaylistLeave'))));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, Localizer.get('PlaylistLeave')));
    await serverAnswers();
    expect(requests, contains('DELETE /api/me/playlists/jazz'));

    // One's own, shared with anna.
    await tester.tap(find.text('Mine').first);
    await settle(tester);
    await tester.tap(find.descendant(of: header, matching: find.byTooltip(Localizer.get('PlaylistShare'))));
    await serverAnswers();
    await tester.tap(find.text('anna'));
    await tester.pump();
    await tester.tap(find.text(Localizer.get('Save')));
    await serverAnswers();
    expect(requests, contains('PUT /api/me/playlists/mine/members/user-2'));
    expect(find.text(Localizer.format('PlaylistSharedTo', ['anna'])), findsOneWidget);
    expect(vm.library.getPlaylist('mine')!.sharing.invited.single.username, 'anna');

    await tester.tap(find.text(Localizer.get('Undo')));
    await serverAnswers();
    expect(requests.last, 'DELETE /api/me/playlists/mine/members/user-2');
    expect(vm.library.getPlaylist('mine')!.sharing.isEmpty, isTrue);
    await tester.pump(const Duration(seconds: 5)); // the notices go
  });
}
