// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wiretune/src/connect_link.dart';
import 'package:wiretune/src/pages/login_page.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Connecting a phone with a QR code: the link it carries, the two codes in Settings, and the phone opened by one.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
  });

  http.Response answer(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  // The account a sign-in code signs in to (not an administrator: no user list to load).
  final member = UserInfo('user-2', 'family', false, DateTime.utc(2026), null);

  test('the link carries the server and the code, and only a well-formed one is taken', () {
    final link = ConnectLink.build('http://192.168.1.10:5200', code: 'ABCD2345');
    expect(ConnectLink.parse(link), (server: 'http://192.168.1.10:5200', code: 'ABCD2345'));
    expect(ConnectLink.parse(ConnectLink.build('https://music.example.com')), (
      server: 'https://music.example.com',
      code: null,
    ));
    for (final other in [
      null,
      '/',
      'https://wiretune.example.com/connect?server=http://a:5200',
      'wiretune://other?server=http://a:5200',
      'wiretune://connect',
      'wiretune://connect?server=ftp://a',
      'wiretune://connect?server=http://a:5200&code=no%20spaces',
    ]) {
      expect(ConnectLink.parse(other), isNull, reason: other);
    }
  });

  test('an address other than localhost is left as it is', () async {
    expect(await ConnectLink.reachable('http://192.168.1.10:5200'), 'http://192.168.1.10:5200');
    expect(await ConnectLink.reachable('https://music.example.com'), 'https://music.example.com');
  });

  testWidgets('Settings shows the server alone and the server with a one-time sign-in for this account', (
    tester,
  ) async {
    final library = createLibrary();
    library.initialize();
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        serverUrl: 'http://192.168.1.10:5200',
        respond: (request) => request.url.path == '/api/auth/sign-in-code'
            ? answer(SignInCode('CODE2345', DateTime.now().toUtc().add(const Duration(minutes: 5))).toJson())
            : null,
      ),
    ))!;
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    vm.navigateTo(AppSection.settings);
    await settle(tester);

    // A phone's settings cards start folded: the account's opened, then its button.
    final button = find.text(Localizer.get('ConnectPhone'), skipOffstage: false);
    if (button.evaluate().isEmpty) {
      final card = find.text(Localizer.get('AccountAndConnection'));
      await tester.ensureVisible(card);
      await settle(tester);
      await tester.tap(card);
      await settle(tester);
    }
    await tester.ensureVisible(button);
    await settle(tester);
    await tester.tap(button);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    final codes = [for (final qr in tester.widgetList<QrImageView>(find.byType(QrImageView))) qr];
    expect(codes, hasLength(2));
    expect(find.text(Localizer.format('ConnectPhoneSignIn', ['owner'])), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Dialog), matching: find.text('http://192.168.1.10:5200')),
      findsOneWidget,
      reason: 'the address under the first',
    );
    await tester.tap(find.text(Localizer.get('Close')));
    await settle(tester);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets("a phone opened by the sign-in code's link is signed in to that account; by the address's, asks", (
    tester,
  ) async {
    final library = createLibrary();
    library.initialize();
    final codes = <String>[];
    final session = (await tester.runAsync(
      () => signedInSession(
        library,
        respond: (request) {
          if (request.url.path != '/api/auth/login-with-code') return null;
          codes.add((jsonDecode(request.body) as Map)['code'] as String);
          return answer(AuthResponse('code-token', member, DateTime.utc(2099)).toJson());
        },
      ),
    ))!;
    final vm = createMainViewModel(library, null, session);
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    await tester.runAsync(session.logout);
    expect(session.isLoggedIn, isFalse);

    // The server's address alone: the sign-in screen, with that address in it.
    await tester.runAsync(() => vm.openConnectLink((server: 'http://192.168.1.20:5200', code: null)));
    await settle(tester);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.widgetWithText(TextField, 'http://192.168.1.20:5200'), findsOneWidget);

    // With a code: signed in, and the sign-in screen gone.
    await tester.runAsync(() => vm.openConnectLink((server: 'http://server:5200', code: 'CODE2345')));
    await settle(tester);
    expect(codes, ['CODE2345']);
    expect(session.isLoggedIn, isTrue);
    expect(vm.session.serverUrl, 'http://server:5200');
    expect(find.byType(LoginPage), findsNothing);
  });
}
