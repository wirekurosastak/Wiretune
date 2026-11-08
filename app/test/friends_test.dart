// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/widgets/page_parts.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Friends, the server's other accounts, through the widgets: the bell with what they recommended, and recommending
/// to them from a menu.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
  });

  testWidgets('the bell shows what friends recommended; a menu recommends to them, with an Undo', (tester) async {
    final requests = <String>[];
    final sent = <Object?>[];
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
          if (path != '/api/accounts' && !path.startsWith('/api/me/recommendations')) return null;
          requests.add('${request.method} $path');
          return switch ((request.method, path)) {
            ('GET', '/api/accounts') => answer([
              const AccountInfo('user-1', 'owner').toJson(),
              const AccountInfo('user-2', 'anna').toJson(),
            ]),
            ('GET', _) => answer([
              Recommendation(
                'r1',
                const AccountInfo('user-2', 'anna'),
                RecommendationKind.track,
                's1',
                'listen to this',
                DateTime.utc(2026, 11, 3),
              ).toJson(),
            ]),
            ('POST', '/api/me/recommendations') => () {
              sent.add(jsonDecode(request.body));
              return answer({
                'ids': ['new-1'],
              });
            }(),
            _ => answer({'ok': true}),
          };
        },
      ),
    ))!;
    final hub = FakeRemoteHub();
    final vm = createMainViewModel(library, null, session, RemoteClient(session, connector: hub.connect));
    addTearDown(vm.dispose);
    Future<void> serverAnswers() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await serverAnswers();
    await showApp(tester, vm, const Size(400, 860));

    final bell = find.byTooltip(Localizer.get('FromFriends'));
    expect(
      find.descendant(of: bell, matching: find.text('1')),
      findsOneWidget,
      reason: 'one came',
    );
    await tester.tap(bell);
    await settle(tester);
    await serverAnswers();
    expect(find.text('Giant Steps • John Coltrane'), findsOneWidget);
    expect(find.text('anna: listen to this'), findsOneWidget);
    expect(requests, contains('POST /api/me/recommendations/seen'));
    expect(vm.friends.unseenCount, 0);

    // A tap plays it.
    await tester.tap(find.text('Giant Steps • John Coltrane'));
    await settle(tester);
    expect(vm.player.currentTrack?.id, 's1');

    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final row = find.ancestor(of: find.text('Naima'), matching: find.byType(InkWell)).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('Recommend')));
    await settle(tester);
    await serverAnswers();
    await settle(tester);
    expect(find.text('owner'), findsNothing, reason: 'not to oneself');
    await tester.tap(find.text('anna'));
    await tester.enterText(find.byType(TextField), 'so calm');
    await tester.tap(find.text(Localizer.get('Send')));
    await settle(tester);
    await serverAnswers();
    await settle(tester);
    expect(sent, [
      {
        'kind': 'track',
        'itemId': 's2',
        'to': ['user-2'],
        'note': 'so calm',
      },
    ]);
    expect(find.text(Localizer.format('RecommendedTo', ['anna'])), findsOneWidget);

    await tester.tap(find.text(Localizer.get('Undo')));
    await settle(tester);
    await serverAnswers();
    expect(requests.last, 'DELETE /api/me/recommendations/new-1');
    await tester.pump(const Duration(seconds: 5)); // the notices go
  });

  testWidgets('the devices menu starts listening together with the friends picked, and ends it', (tester) async {
    http.Response answer(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        tracks: [TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps')],
        respond: (request) => switch (request.url.path) {
          '/api/accounts' => answer([
            const AccountInfo('user-1', 'owner').toJson(),
            const AccountInfo('user-2', 'anna').toJson(),
          ]),
          '/api/me/recommendations' => answer(const <Object>[]),
          _ => null,
        },
      ),
    ))!;
    final hub = FakeRemoteHub();
    final remote = RemoteClient(session, connector: hub.connect);
    final vm = createMainViewModel(library, null, session, remote);
    addTearDown(vm.dispose);
    remote.configure(id: 'phone-id', name: 'Phone', kind: DeviceKind.phone, enabled: true);
    await tester.runAsync(() => until(() => remote.isConnected));
    hub.devices(const []);
    await tester.runAsync(pumpEventQueue);
    await showApp(tester, vm, const Size(400, 860));

    await tester.tap(find.byTooltip(Localizer.get('TipDevices')).first);
    await settle(tester);
    await tester.tap(find.text(Localizer.get('ListenTogether')));
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
    await tester.tap(find.text('anna'));
    await tester.pump();
    await tester.tap(find.text(Localizer.get('ListenInvite')));
    await settle(tester);
    expect(hub.ofType('listenStart').single['invite'], ['user-2']);

    hub.deliver({
      'type': 'listen',
      'group': {
        'id': 'g1',
        'host': {'accountId': 'user-1', 'username': 'owner', 'deviceId': 'phone-id', 'deviceName': 'Phone'},
        'members': [
          {'accountId': 'user-2', 'username': 'anna', 'deviceId': 'anna-phone', 'deviceName': ''},
        ],
      },
    });
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    final lit = find.byTooltip(Localizer.format('ListeningWith', ['anna']));
    expect(lit, findsWidgets, reason: 'the button says who listens');
    expect(find.text(Localizer.format('ListenJoined', ['anna'])), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the notice, over the top bar, goes
    await settle(tester);
    await tester.tap(lit.first);
    await settle(tester);
    await tester.tap(find.text(Localizer.get('ListenEnd')));
    await settle(tester);
    expect(hub.ofType('listenLeave'), hasLength(1));
    expect(vm.player.listeningGroup, isNull);
    await tester.pump(const Duration(seconds: 5)); // the notices go
  });

  testWidgets("Settings → Friends blocks someone, who is left out of the picker, and unblocks them", (tester) async {
    final requests = <String>[];
    var blocked = <String>{};
    http.Response answer(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    const anna = AccountInfo('user-2', 'anna');
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        respond: (request) {
          final path = request.url.path;
          if (path != '/api/accounts' && !path.startsWith('/api/me/blocked') && path != '/api/me/recommendations') {
            return null;
          }
          requests.add('${request.method} $path');
          return switch ((request.method, path)) {
            ('GET', '/api/accounts') => answer([const AccountInfo('user-1', 'owner').toJson(), anna.toJson()]),
            ('GET', '/api/me/blocked') => answer([if (blocked.contains(anna.id)) anna.toJson()]),
            ('PUT', '/api/me/blocked/user-2') => () {
              blocked = {anna.id};
              return answer({'userId': anna.id, 'blocked': true});
            }(),
            ('DELETE', '/api/me/blocked/user-2') => () {
              blocked = {};
              return answer({'userId': anna.id, 'blocked': false});
            }(),
            _ => answer(<Object?>[]),
          };
        },
      ),
    ))!;
    final hub = FakeRemoteHub();
    final vm = createMainViewModel(library, null, session, RemoteClient(session, connector: hub.connect));
    addTearDown(vm.dispose);
    Future<void> serverAnswers() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    await serverAnswers();
    await settle(tester);

    final card = find.ancestor(of: find.text(Localizer.get('FriendsSection')), matching: find.byType(GlassCard));
    expect(find.descendant(of: card, matching: find.text('anna')), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('owner')),
      findsNothing,
      reason: 'only the others',
    );
    final block = find.descendant(of: card, matching: find.text(Localizer.get('Block')));
    await tester.ensureVisible(block);
    await settle(tester);
    await tester.tap(block);
    await serverAnswers();
    await settle(tester);
    expect(requests, contains('PUT /api/me/blocked/user-2'));
    expect(find.descendant(of: card, matching: find.text(Localizer.get('Blocked'))), findsOneWidget);
    expect(await tester.runAsync(vm.friends.otherAccounts), isEmpty, reason: "the picker leaves anna out");

    await tester.tap(find.descendant(of: card, matching: find.text(Localizer.get('Unblock'))));
    await serverAnswers();
    await settle(tester);
    expect(requests, contains('DELETE /api/me/blocked/user-2'));
    expect(find.descendant(of: card, matching: find.text(Localizer.get('Block'))), findsOneWidget);
    expect((await tester.runAsync(vm.friends.otherAccounts))!.map((a) => a.username), ['anna']);
  });

  testWidgets("an account changes its name in Settings; an administrator renames another and lets members", (
    tester,
  ) async {
    final requests = <Object?>[];
    var members = false;
    http.Response answer(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    UserInfo user(String id, String name, {bool admin = false}) =>
        UserInfo(id, name, admin, DateTime.utc(2026), null, canRename: admin);
    var anna = user('user-2', 'anna');
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        respond: (request) {
          final path = request.url.path;
          final config = ServerConfigInfo('/music', membersCanRename: members);
          return switch ((request.method, path)) {
            ('POST', '/api/auth/change-username') => () {
              requests.add(jsonDecode(request.body));
              return answer(user('user-1', (jsonDecode(request.body) as Map)['username'] as String, admin: true));
            }(),
            ('POST', '/api/users/user-2/username') => () {
              requests.add(jsonDecode(request.body));
              anna = user('user-2', (jsonDecode(request.body) as Map)['username'] as String);
              return answer(anna);
            }(),
            ('GET', '/api/users') => answer([user('user-1', 'owner', admin: true), anna]),
            ('GET', '/api/config') => answer(config),
            ('POST', '/api/config/members-can-rename') => () {
              members = (jsonDecode(request.body) as Map)['enabled'] as bool;
              return answer(ServerConfigInfo('/music', membersCanRename: members));
            }(),
            _ => null,
          };
        },
      ),
    ))!;
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    Future<void> serverAnswers() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await showApp(tester, vm, const Size(400, 860));
    // Into the middle of the screen, clear of the phone's floating bar.
    Future<void> toMiddle(Finder finder) => Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    await serverAnswers();
    await settle(tester);

    // Its own name.
    final change = find.text(Localizer.get('ChangeUsername'));
    await toMiddle(change);
    await settle(tester);
    await tester.tap(change);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Boss');
    await tester.tap(find.text(Localizer.get('Save')));
    await serverAnswers();
    await settle(tester);
    expect(requests.last, {'username': 'Boss'});
    expect(vm.serverSettings.currentUserName, 'Boss');
    expect(find.text(Localizer.format('UsernameChanged', ['Boss'])), findsOneWidget);

    // Another account's.
    final rename = find.byTooltip(Localizer.get('Rename'));
    await toMiddle(rename);
    await settle(tester);
    await tester.tap(rename);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Anna');
    await tester.tap(find.text(Localizer.get('Save')));
    await serverAnswers();
    await settle(tester);
    expect(requests.last, {'username': 'Anna'});
    expect(vm.serverSettings.serverUsers.map((u) => u.username), contains('Anna'));

    // Members may rename themselves: off, then on.
    expect(vm.serverSettings.membersCanRename, isFalse);
    final allow = find.ancestor(of: find.text(Localizer.get('MembersCanRename')), matching: find.byType(Row)).first;
    await toMiddle(allow);
    await settle(tester);
    await tester.tap(find.descendant(of: allow, matching: find.byType(Switch)));
    await serverAnswers();
    await settle(tester);
    expect(members, isTrue);
    expect(vm.serverSettings.membersCanRename, isTrue);
  });
}
