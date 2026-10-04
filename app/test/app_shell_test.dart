import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/app.dart';
import 'package:wiretune/src/layouts/phone_layout.dart';
import 'package:wiretune/src/layouts/wide_layout.dart';
import 'package:wiretune/src/pages/now_playing_page.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The whole interface rendered: which layout a screen gets, and that the navigation, the search, the full-screen
/// player and the back button work through the widgets (not just the view model).
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
  });

  Future<MainViewModel> create() async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
      TestSupport.makeTrack('2', 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 2),
      TestSupport.makeTrack('3', 'Opening', artist: 'Daft Punk', album: 'Random Access Memories', trackNumber: 1),
    ]);
    await library.initialize();
    return createMainViewModel(library);
  }

  Future<MainViewModel> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final vm = await tester.runAsync(create);
    await tester.pumpWidget(WiretuneApp(vm: vm!));
    await tester.pump(const Duration(milliseconds: 400));
    return vm;
  }

  // Animations that run while something plays never settle; a few frames are enough to see the result.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('a desktop window gets the wide layout, and the sidebar navigates', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    expect(find.byType(WideLayout), findsOneWidget);
    expect(find.text('WIRETUNE'), findsOneWidget);

    await tester.tap(find.text(Localizer.get('NavAlbums')).first);
    await settle(tester);
    expect(vm.selectedSection, AppSection.albums);
    expect(find.text('Kind of Blue'), findsWidgets);

    await tester.tap(find.text(Localizer.get('NavTracks')).first);
    await settle(tester);
    expect(vm.selectedSection, AppSection.tracks);
    expect(find.text('Blue in Green'), findsOneWidget);
  });

  testWidgets('typing in the search field shows the results, Escape steps back out', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    await tester.enterText(find.byType(TextField).first, 'daft');
    await settle(tester);
    expect(vm.isSearchActive, isTrue);
    expect(find.text('Random Access Memories'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(vm.isSearchActive, isFalse);
  });

  testWidgets('a narrow window gets the phone layout with the bottom navigation', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    expect(find.byType(PhoneLayout), findsOneWidget);
    expect(find.text(Localizer.get('NavSongs')), findsOneWidget); // the bottom navigation's label

    await tester.tap(find.text(Localizer.get('NavSongs')));
    await settle(tester);
    expect(vm.selectedSection, AppSection.tracks);
    expect(find.text('So What'), findsOneWidget);
  });

  testWidgets('the mini player opens the full-screen player, and back closes it', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    expect(find.byType(NowPlayingPage), findsNothing);

    vm.player.currentTrack = vm.library.tracks.first;
    await settle(tester);
    final miniTitle = find.descendant(of: find.byType(Scaffold), matching: find.text(vm.library.tracks.first.title));
    expect(miniTitle, findsOneWidget);

    await tester.tap(miniTitle);
    await settle(tester);
    expect(vm.isNowPlayingOpen, isTrue);
    expect(find.byType(NowPlayingPage), findsOneWidget);

    await tester.tap(find.text(Localizer.get('Queue')));
    await settle(tester);
    expect(vm.nowPlayingTab, 1);

    // The system back button (Android) arrives as a pop of the route: from the queue it returns to the player, then
    // closes it.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.isNowPlayingOpen, isTrue);
    expect(vm.nowPlayingTab, 0);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.isNowPlayingOpen, isFalse);
  });

  testWidgets('the phone search page opens from the page header and back closes it', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    await tester.tap(find.byIcon(Icons.search_rounded));
    await settle(tester);
    expect(vm.isSearchOpen, isTrue);

    await tester.enterText(find.byType(TextField), 'miles');
    await settle(tester);
    expect(find.text('Miles Davis'), findsWidgets);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.isSearchOpen, isFalse);
  });

  testWidgets('a TV always gets the wide layout, whatever the reported size', (tester) async {
    AppPlatform.forTesting(tv: true);
    await pumpApp(tester, const Size(640, 360));
    expect(find.byType(WideLayout), findsOneWidget);
  });

  testWidgets('every section renders in both layouts, in both themes', (tester) async {
    for (final size in const [Size(1400, 900), Size(1000, 700), Size(400, 860)]) {
      final vm = await pumpApp(tester, size);
      vm.player.currentTrack = vm.library.tracks.first;
      for (final light in [false, true]) {
        vm.setTheme(light: light, persist: false);
        for (final section in AppSection.values) {
          vm.navigateTo(section);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$section at $size, light: $light');
        }
      }
      expect(Theme.of(tester.element(find.byType(Material).first)).brightness, Brightness.light);
    }
  });

  testWidgets('a small phone with a large font, and a 1080p TV, render every section without overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final (size, tv) in const [(Size(360, 640), false), (Size(960, 540), true)]) {
      AppPlatform.forTesting(tv: tv);
      final vm = await pumpApp(tester, size);
      vm.player.currentTrack = vm.library.tracks.first;
      for (final section in AppSection.values) {
        vm.navigateTo(section);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: '$section at $size');
      }
      vm.openAlbum(vm.library.albums.first);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'album detail at $size');
      vm.openArtist(vm.library.artists.first);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'artist detail at $size');
      if (!tv) {
        vm.openNowPlaying();
        for (final tab in [0, 1, 2]) {
          vm.nowPlayingTab = tab;
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'now playing tab $tab at $size');
        }
        vm.closeNowPlaying();
      }
    }
  });

  testWidgets('the sign-in page covers the app while it is active', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.showLoginScreen();
    await settle(tester);
    expect(find.text(Localizer.get('Connect')), findsWidgets);
  });
}
