// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// A phone's streaming quality on mobile data: asked the first time, then switched with the network by itself.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting(system: 'android');
  });

  /// A phone signed in to a server, whose network [mobileData] tells.
  Future<MainViewModel> phone(LibraryService library, Stream<bool> mobileData) async {
    // Music from the server, as a phone signed in to one has.
    final session = await signedInSession(library, tracks: [TestSupport.makeServerTrack('s1', 'Naima')]);
    final vm = MainViewModel(
      TestSupport.createEngine(),
      library,
      session,
      capabilities: DeviceCapabilities(kind: DeviceKind.phone, mobileData: mobileData),
    );
    await vm.start();
    return vm;
  }

  test('the first time on mobile data asks; then the quality follows the network, and is kept', () async {
    final library = createLibrary();
    final network = StreamController<bool>();
    final vm = await phone(library, network.stream);
    vm.streamingQuality = StreamingQuality.high;

    network.add(false);
    await pumpEventQueue();
    expect(vm.asksMobileQuality, isFalse, reason: 'on Wi-Fi');
    expect(vm.audioEngine.streamingQuality, StreamingQuality.high);

    network.add(true);
    await pumpEventQueue();
    expect(vm.asksMobileQuality, isTrue);
    expect(vm.audioEngine.streamingQuality, StreamingQuality.high, reason: "the Wi-Fi one until it's answered");

    vm.mobileStreamingQuality = StreamingQuality.dataSaver;
    expect(vm.asksMobileQuality, isFalse);
    expect(vm.audioEngine.streamingQuality, StreamingQuality.dataSaver);

    network.add(false);
    await pumpEventQueue();
    expect(vm.audioEngine.streamingQuality, StreamingQuality.high, reason: 'back on Wi-Fi');
    network.add(true);
    await pumpEventQueue();
    expect(vm.audioEngine.streamingQuality, StreamingQuality.dataSaver);
    expect(vm.asksMobileQuality, isFalse, reason: 'asked once');
    vm.dispose();

    // Started again on mobile data: the answer is remembered.
    final again = await phone(library, Stream.value(true));
    await pumpEventQueue();
    expect(again.asksMobileQuality, isFalse);
    expect(again.mobileStreamingQuality, StreamingQuality.dataSaver);
    expect(again.audioEngine.streamingQuality, StreamingQuality.dataSaver);
    again.dispose();
  });

  test(
    '"Keep original" streams the original on mobile data, whatever Wi-Fi has; a closed question asks again',
    () async {
      final library = createLibrary();
      final vm = await phone(library, Stream.value(true));
      await pumpEventQueue();
      expect(vm.asksMobileQuality, isTrue);
      vm.streamingQuality = StreamingQuality.normal;
      expect(vm.mobileStreamingQuality, StreamingQuality.normal, reason: "the Wi-Fi one until it's chosen");
      vm.skipMobileQuality();
      expect(vm.asksMobileQuality, isFalse);
      vm.dispose();

      final again = await phone(library, Stream.value(true));
      await pumpEventQueue();
      expect(again.asksMobileQuality, isTrue, reason: 'not answered yet');
      again.mobileStreamingQuality = StreamingQuality.original;
      expect(again.audioEngine.streamingQuality, StreamingQuality.original, reason: 'not the Wi-Fi Normal');
      again.dispose();

      final third = await phone(library, Stream.value(true));
      await pumpEventQueue();
      expect(third.asksMobileQuality, isFalse);
      expect(third.mobileStreamingQuality, StreamingQuality.original);
      third.dispose();
    },
  );

  testWidgets('the question is a dialog over the app, and its answer is the quality on mobile data', (tester) async {
    final library = createLibrary();
    library.initialize();
    final network = StreamController<bool>();
    final vm = (await tester.runAsync(() => phone(library, network.stream)))!;
    addTearDown(vm.dispose);
    await showApp(tester, vm, const Size(400, 860));
    expect(find.text(Localizer.get('MobileDataQualityTitle')), findsNothing);

    network.add(true);
    await tester.pump();
    await settle(tester);
    expect(find.text(Localizer.get('MobileDataQualityTitle')), findsOneWidget);
    await tester.tap(find.text(Localizer.get('StreamingNormal')));
    await settle(tester);
    expect(find.text(Localizer.get('MobileDataQualityTitle')), findsNothing);
    expect(vm.mobileStreamingQuality, StreamingQuality.normal);
    expect(vm.audioEngine.streamingQuality, StreamingQuality.normal);
  });
}
