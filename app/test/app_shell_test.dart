// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/app.dart';
import 'package:wiretune/src/layouts/phone_layout.dart';
import 'package:wiretune/src/layouts/wide_layout.dart';
import 'package:wiretune/src/pages/library_pages.dart';
import 'package:wiretune/src/pages/now_playing_page.dart';
import 'package:wiretune/src/pages/queue_panel.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/library_view_models.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/ambient.dart';
import 'package:wiretune/src/widgets/badges.dart';
import 'package:wiretune/src/widgets/buttons.dart';
import 'package:wiretune/src/widgets/cards.dart';
import 'package:wiretune/src/widgets/cover_image.dart';
import 'package:wiretune/src/widgets/devices.dart';
import 'package:wiretune/src/widgets/page_parts.dart';
import 'package:wiretune/src/widgets/track_list.dart';
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
    library.initialize();
    return createMainViewModel(library);
  }

  // A local album beside a server's, as a player signed in to a server has them: only the server's can be downloaded.
  Future<MainViewModel> createWithServer() async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
      TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps'),
      TestSupport.makeServerTrack('s2', 'Naima', artist: 'John Coltrane', album: 'Giant Steps', trackNumber: 2),
    ]);
    library.initialize();
    return createMainViewModel(library);
  }

  Future<MainViewModel> pumpApp(WidgetTester tester, Size size, [Future<MainViewModel> Function()? build]) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final vm = await tester.runAsync(build ?? create);
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

  // Covers are read from disk and decoded for real, in steps that each need the real event loop: until [shown] finds
  // the result. Then the transitions run out.
  Future<void> loadCovers(WidgetTester tester, Finder shown) async {
    for (var i = 0; i < 40 && shown.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(); // what the ends of the transitions set off
  }

  // The colours of the playing cover in the backdrop of [page].
  Finder washOf(Finder page) => find.descendant(
    of: find.descendant(of: page, matching: find.byType(AmbientBackdrop)),
    matching: find.byType(RawImage),
  );

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

  testWidgets('favoriting a track dynamically updates the count next to Favorites in the sidebar', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final navFavorites = Localizer.get('NavFavorites');
    expect(find.text(navFavorites), findsOneWidget);
    expect(vm.favorites.favoriteTracks, isEmpty);

    final favoritesItem = find.ancestor(of: find.text(navFavorites), matching: find.byType(InkWell));
    expect(find.descendant(of: favoritesItem, matching: find.text('0')), findsOneWidget);

    vm.library.toggleFavorite('1');
    await tester.pump();
    await settle(tester);

    expect(vm.favorites.favoriteTracks, hasLength(1));
    expect(find.descendant(of: favoritesItem, matching: find.text('1')), findsOneWidget);

    vm.library.toggleFavorite('1');
    await tester.pump();
    await settle(tester);

    expect(vm.favorites.favoriteTracks, isEmpty);
    expect(find.descendant(of: favoritesItem, matching: find.text('0')), findsOneWidget);
  });

  testWidgets("a desktop's keys play, skip, seek and set the volume, but leave a text field's typing alone", (
    tester,
  ) async {
    final driver = FakeAudioDriver();
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        TestSupport.makeTrack('1', 'So What'),
        TestSupport.makeTrack('2', 'Blue in Green'),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(driver));
    });
    final player = vm.player;
    final tracks = vm.library.tracks.toList();
    player.playQueue(tracks, tracks.first);
    await settle(tester);
    Future<void> press(LogicalKeyboardKey key, {LogicalKeyboardKey? modifier}) async {
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(key);
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      await tester.pump();
    }

    await press(LogicalKeyboardKey.space);
    expect(player.isPlaying, isFalse);
    await press(LogicalKeyboardKey.space);
    expect(player.isPlaying, isTrue);
    await press(LogicalKeyboardKey.arrowRight, modifier: LogicalKeyboardKey.shiftLeft);
    expect(player.position.value, const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300)); // the seek goes out
    final volume = player.volume;
    await press(LogicalKeyboardKey.arrowDown, modifier: LogicalKeyboardKey.controlLeft);
    expect(player.volume, volume - 5);
    await press(LogicalKeyboardKey.arrowRight, modifier: LogicalKeyboardKey.controlLeft);
    expect(player.currentTrack, tracks[1]);

    await press(LogicalKeyboardKey.keyF, modifier: LogicalKeyboardKey.controlLeft);
    final field = find.byType(EditableText).first;
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    await press(LogicalKeyboardKey.space);
    await press(LogicalKeyboardKey.arrowLeft, modifier: LogicalKeyboardKey.controlLeft);
    expect(player.isPlaying, isTrue, reason: 'the keys belong to the field');
    expect(player.currentTrack, tracks[1]);
  });

  testWidgets("an album of two discs shows each disc's heading over its tracks, in its own order only", (tester) async {
    for (final size in [const Size(1400, 900), const Size(400, 860)]) {
      final vm = await pumpApp(tester, size, () async {
        final library = createLibrary([
          TestSupport.makeTrack('1', 'Intro', album: 'Double', trackNumber: 1),
          TestSupport.makeTrack('2', 'Closer', album: 'Double', trackNumber: 2),
          TestSupport.makeTrack('3', 'Second Start', album: 'Double', trackNumber: 1, discNumber: 2),
        ]);
        library.initialize();
        return createMainViewModel(library);
      });
      vm.openAlbum(vm.library.albums.single);
      await settle(tester);
      expect(find.text('DISC 1'), findsOneWidget);
      expect(find.text('DISC 2'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('DISC 2')).dy,
        allOf(
          greaterThan(tester.getTopLeft(find.text('Closer')).dy),
          lessThan(tester.getTopLeft(find.text('Second Start')).dy),
        ),
      );

      if (size.width > 1000) {
        await tester.tap(find.text(Localizer.get('ColTitle')));
        await settle(tester);
        expect(find.text('DISC 1'), findsNothing, reason: 'sorted by title the discs mix');
      }
    }
  });

  testWidgets('Escape closes a dialog first, and only then steps back', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.albums);
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    await tester.tap(find.text(Localizer.get('PlaylistNew')).first);
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistNamePlaceholder')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistNamePlaceholder')), findsNothing);
    expect(vm.selectedSection, AppSection.playlists, reason: 'the page under the dialog stays');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(vm.selectedSection, AppSection.albums);
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

  testWidgets('the search fields follow the query: the clear button comes with the typing, back empties them', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final clear = find.byTooltip(Localizer.get('TipClearSearch'));
    Finder field() => find.byType(TextField).first;
    expect(clear, findsNothing);

    await tester.enterText(field(), 'daft');
    await settle(tester);
    expect(clear, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(clear, findsNothing);
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);

    tester.view.physicalSize = const Size(400, 860);
    vm.openSearch();
    await settle(tester);
    await tester.enterText(field(), 'miles');
    await settle(tester);
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await settle(tester);
    expect(clear, findsNothing);
    expect(vm.searchQuery, isEmpty);
  });

  testWidgets('a narrow window gets the phone layout with the bottom navigation', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    expect(find.byType(PhoneLayout), findsOneWidget);
    expect(find.text(Localizer.get('NavTracks')), findsOneWidget); // the bottom navigation's label

    await tester.tap(find.text(Localizer.get('NavTracks')));
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
    expect(vm.nowPlayingTab, NowPlayingTab.queue);

    // The system back button (Android) arrives as a pop of the route: from the queue it returns to the player, then
    // closes it.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.isNowPlayingOpen, isTrue);
    expect(vm.nowPlayingTab, NowPlayingTab.player);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.isNowPlayingOpen, isFalse);
  });

  testWidgets('a skip in the full-screen player shows the next track\'s title and cover', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    final tracks = vm.library.tracks.take(2).toList();
    for (final track in tracks) {
      track.coverArtPath = '/covers/${track.id}.jpg';
    }
    final page = find.byType(NowPlayingPage);
    Finder onPage(Finder finder) => find.descendant(of: page, matching: finder);
    String? coverOnPage() => tester.widget<CoverImage>(onPage(find.byType(CoverImage))).path;

    vm.player.playQueue(tracks, tracks.first);
    vm.openNowPlaying();
    await settle(tester);
    expect(onPage(find.text(tracks.first.title)), findsOneWidget);
    expect(coverOnPage(), tracks.first.coverArtPath);

    vm.player.nextTrack();
    await settle(tester);

    expect(onPage(find.text(tracks.last.title)), findsOneWidget);
    expect(onPage(find.text(tracks.first.title)), findsNothing);
    expect(coverOnPage(), tracks.last.coverArtPath);
  });

  testWidgets('the search box is centred on the window, and stays put when a mode lights up', (tester) async {
    // The test font draws every letter as a full square, so the header needs a wider window than real text does.
    final vm = await pumpApp(tester, const Size(1920, 1000));
    final search = find.byType(TextField).first;
    expect(tester.getCenter(search).dx, closeTo(960, 0.5));
    final before = tester.getRect(search);

    await tester.runAsync(vm.player.toggleExclusiveMode);
    await settle(tester);

    expect(vm.player.isExclusiveMode, isTrue);
    expect(tester.getRect(search), before);
  });

  testWidgets('on a phone the lyric being sung, drawn larger, still fits the width', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final driver = FakeAudioDriver();
    final vm = (await tester.runAsync(() async {
      final library = createLibrary([TestSupport.makeTrack('1', 'Song')]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(driver));
    }))!;
    const line = "(La, la, la) I'm caught up in the rapture of love, nothing else can compare";
    vm.lyrics.own = (_) async => '[00:00.50]$line\n[00:30.00]When I feel the magic of you';
    await tester.pumpWidget(WiretuneApp(vm: vm));

    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    vm.nowPlayingTab = NowPlayingTab.lyrics;
    await tester.runAsync(() async {
      await waitUntil(() => vm.lyrics.isSynced);
      await driver.seek(const Duration(seconds: 1));
    });
    await settle(tester);

    expect(vm.lyrics.currentLine.value, 0);
    final list = tester.getRect(find.descendant(of: find.byType(NowPlayingPage), matching: find.byType(ListView)));
    final sung = tester.getRect(find.text(line));
    expect(sung.left, greaterThanOrEqualTo(list.left));
    expect(sung.right, lessThanOrEqualTo(list.right));
  });

  testWidgets("a table row shows the heart and a menu with the rest, which a right click opens with the heart's", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final favorite = vm.library.tracks.first;
    vm.library.toggleFavorite(favorite.id);
    vm.navigateTo(AppSection.favorites);
    await settle(tester);

    Finder inList(IconData icon) => find.descendant(of: find.byType(TrackSliver), matching: find.byIcon(icon));
    expect(inList(Icons.playlist_add_rounded), findsNothing);
    expect(inList(Icons.visibility_off_outlined), findsNothing);
    expect(
      tester.getCenter(inList(Icons.favorite_rounded)).dx,
      lessThan(tester.getCenter(inList(Icons.more_vert_rounded)).dx),
    );

    await tester.tap(inList(Icons.more_vert_rounded));
    await settle(tester);
    expect(find.text(Localizer.get('TipAddToPlaylist')), findsOneWidget);
    expect(find.text(Localizer.get('TipRemoveFromFavorites')), findsNothing, reason: 'the heart beside it has it');
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    await tester.tap(find.text(favorite.title), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text(Localizer.get('TipRemoveFromFavorites')).last);
    await settle(tester);
    expect(vm.library.isFavorite(favorite.id), isFalse);
  });

  testWidgets('a phone lists albums and artists as rows, and a row opens its page', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    // Rows: one under the other, not tiles side by side.
    void expectRows(String first, String second) {
      final (a, b) = (tester.getTopLeft(find.text(first)), tester.getTopLeft(find.text(second)));
      expect(a.dx, b.dx);
      expect(a.dy, isNot(b.dy));
    }

    vm.navigateTo(AppSection.albums);
    await settle(tester);
    expectRows('Kind of Blue', 'Random Access Memories');
    expect(find.text('2 albums'), findsOneWidget); // under the title
    await tester.tap(find.text('Kind of Blue'));
    await settle(tester);
    expect(vm.albums.selectedAlbum?.title, 'Kind of Blue');

    vm.navigateTo(AppSection.artists);
    await settle(tester);
    expectRows('Daft Punk', 'Miles Davis');
    expect(find.text('2 artists'), findsOneWidget);
    expect(find.text('1 album  •  2 tracks'), findsOneWidget);
    await tester.tap(find.text('Miles Davis'));
    await settle(tester);
    expect(vm.artists.selectedArtist?.name, 'Miles Davis');
  });

  testWidgets('the quality tag sits on the cover: the full-screen player, an album, a playlist', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    void expectOnCover(Finder page, Finder cover) {
      final tag = find.descendant(of: page, matching: find.byType(QualityTag));
      expect(tag, findsOneWidget); // and nowhere else on the page
      final (on, under) = (tester.getRect(tag), tester.getRect(cover));
      expect(under.intersect(on), on, reason: '$on lies inside $under');
    }

    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    await settle(tester);
    final player = find.byType(NowPlayingPage);
    expectOnCover(player, find.descendant(of: player, matching: find.byType(CoverImage)));
    vm.closeNowPlaying();

    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);
    final header = find.byType(DetailHeader);
    expectOnCover(header, find.descendant(of: header, matching: find.byType(CoverImage)));

    final playlist = (await tester.runAsync(() async {
      final created = vm.library.createPlaylist('Mix');
      vm.library.addTracksToPlaylist(created.id, [vm.library.tracks.first.id]);
      return vm.library.getPlaylist(created.id);
    }))!;
    vm.navigateTo(AppSection.playlists);
    vm.playlists.openPlaylist(playlist);
    await settle(tester);
    expectOnCover(header, find.descendant(of: header, matching: find.byType(CoverImage)));
  });

  testWidgets('a phone shows quality tags in its album rows and leaves them out of its queue', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    expect(find.text('Kind of Blue'), findsOneWidget);
    expect(find.byType(QualityTag), findsWidgets);

    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    vm.nowPlayingTab = NowPlayingTab.queue;
    await settle(tester);
    expect(find.byType(QueueList), findsOneWidget);
    expect(find.descendant(of: find.byType(QueueList), matching: find.byType(QualityTag)), findsNothing);
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
      // A server's album too: its download button stands beside Play and Shuffle.
      final vm = await pumpApp(tester, size, createWithServer);
      vm.library.setFavorite('s1', true); // not signed in: as the server told it
      vm.player.currentTrack = vm.library.tracks.first;
      for (final section in AppSection.values) {
        vm.navigateTo(section);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: '$section at $size');
      }
      for (final album in vm.library.albums) {
        vm.openAlbum(album);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: '${album.title} at $size');
      }
      vm.openArtist(vm.library.artists.first);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'artist detail at $size');
      if (!tv) {
        vm.openNowPlaying();
        for (final tab in NowPlayingTab.values) {
          vm.nowPlayingTab = tab;
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'now playing tab $tab at $size');
        }
        vm.closeNowPlaying();
      }
    }
  });

  group('on a phone, while music plays', () {
    // Each frame costs battery there: nothing may keep drawing frames on its own for as long as the music lasts.
    Future<(MainViewModel, FakeAudioDriver)> playWithCover(WidgetTester tester) async {
      AppPlatform.forTesting(system: 'android');
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final driver = FakeAudioDriver();
      final vm = (await tester.runAsync(() async {
        final library = createLibrary([
          TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue'),
          TestSupport.makeTrack('2', 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 2),
        ]);
        library.initialize();
        return createMainViewModel(library, TestSupport.createEngine(driver));
      }))!;
      // The backdrop only has something to move once a cover is there.
      final cover = writeCover(Directory.systemTemp.createTempSync('wiretune_cover_'));
      for (final track in vm.library.tracks) {
        track.coverArtPath = cover;
      }
      await tester.pumpWidget(WiretuneApp(vm: vm));
      vm.player.playQueue(vm.library.tracks);
      await loadCovers(tester, washOf(find.byType(PhoneLayout)));
      expect(vm.player.isPlaying, isTrue);
      expect(washOf(find.byType(PhoneLayout)), findsWidgets); // so there is something that could move
      return (vm, driver);
    }

    testWidgets('nothing animates on its own, in the library or the full-screen player', (tester) async {
      final (vm, _) = await playWithCover(tester);
      expect(tester.binding.transientCallbackCount, 0);

      vm.openNowPlaying();
      await loadCovers(tester, washOf(find.byType(NowPlayingPage)));
      expect(washOf(find.byType(NowPlayingPage)), findsWidgets);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('the progress is drawn once a second, not at every position update', (tester) async {
      final (vm, driver) = await playWithCover(tester);
      vm.openNowPlaying();
      await loadCovers(tester, washOf(find.byType(NowPlayingPage)));
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'full-screen player, before',
      ); // everything has come to rest
      final second = vm.player.position.value.inSeconds + 1;
      driver.positionChanged.emit(Duration(seconds: second, milliseconds: 100)); // a new second: drawn
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'full-screen player');
      await tester.pump();
      for (final ms in [250, 400, 550, 700, 850]) {
        driver.positionChanged.emit(Duration(seconds: second, milliseconds: ms)); // the rest of it: not
        expect(tester.binding.hasScheduledFrame, isFalse, reason: 'full-screen player, $ms ms');
      }
    });
  });

  testWidgets('a server album, a server track and the favourites download; a local album has nothing to', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900), createWithServer);
    final downloads = vm.downloads;
    final header = find.byType(DetailHeader);
    Finder inHeader(String tooltip) => find.descendant(of: header, matching: find.byTooltip(tooltip));
    Finder inRows(String tooltip) => find.descendant(of: find.byType(TrackSliver), matching: find.byTooltip(tooltip));

    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);
    expect(inHeader('Download to this device'), findsNothing);
    expect(tester.widget<PlayShuffleButtons>(find.byType(PlayShuffleButtons)).trailing, isNull, reason: 'no button');
    expect(inRows('Download to this device'), findsNothing);

    final album = vm.library.albums.firstWhere((a) => a.title == 'Giant Steps');
    vm.openAlbum(album);
    await settle(tester);
    await tester.tap(inHeader('Download to this device'));
    await settle(tester);
    expect(downloads.isAlbumDownloaded(album), isTrue);
    // On its way: the arrow in progress inside a ring that fills as the tracks arrive (none yet, out of two).
    expect(find.descendant(of: header, matching: find.byIcon(Icons.downloading_rounded)), findsOneWidget);
    final ring = tester.widget<CircularProgressIndicator>(
      find.descendant(of: header, matching: find.byType(CircularProgressIndicator)),
    );
    expect(ring.value, 0);
    // The album keeps its tracks: their own menus cannot let them go, and their rows show them coming.
    Future<void> openRowMenu(String title) async {
      final row = find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
      await settle(tester);
    }

    await openRowMenu('Giant Steps');
    final keptByAlbum = find.ancestor(
      of: find.text(Localizer.get('TipDownloadedWithList')),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    );
    expect(tester.widget<PopupMenuItem<Object?>>(keptByAlbum).enabled, isFalse);
    await tester.tapAt(const Offset(5, 5)); // closes the menu
    await settle(tester);
    expect(album.tracks.map(downloads.isTrackDownloaded), [false, false]);
    expect(album.tracks.map(downloads.stateOf), everyElement(DownloadState.queued));
    expect(
      find.descendant(of: find.byType(TrackSliver), matching: find.byIcon(Icons.downloading_rounded)),
      findsNWidgets(2),
    );
    await tester.tap(inHeader('0 of 2 downloaded – click to remove'));
    await settle(tester);
    expect(downloads.isAlbumDownloaded(album), isFalse);

    // One track, from its row's menu.
    await openRowMenu('Giant Steps');
    await tester.tap(find.text('Download to this device'));
    await settle(tester);
    expect(downloads.isTrackDownloaded(vm.library.getTrack('s1')!), isTrue);

    // The favourites, from their page.
    vm.library.setFavorite('s2', true); // not signed in: as the server told it
    vm.navigateTo(AppSection.favorites);
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(PlayShuffleButtons), matching: find.byTooltip(Localizer.get('TipDownload'))),
    );
    await settle(tester);
    expect(downloads.areFavoritesDownloaded, isTrue);

    // An artist's albums, from the artist's page.
    final coltrane = vm.library.getArtistByName('John Coltrane')!;
    vm.openArtist(coltrane);
    await settle(tester);
    await tester.tap(inHeader('Download to this device'));
    await settle(tester);
    expect(downloads.isArtistDownloaded(coltrane), isTrue);
  });

  testWidgets('on a phone a swipe up opens the full-screen player, whose menu adds the track to a playlist', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.player.playQueue(vm.library.tracks);
    await settle(tester);
    await tester.drag(find.text(vm.player.nowPlayingTitle), const Offset(0, -120)); // on the mini player
    await settle(tester);
    expect(vm.isNowPlayingOpen, isTrue);

    final player = find.byType(NowPlayingPage);
    await tester.tap(find.descendant(of: player, matching: find.byTooltip(Localizer.get('TipMore'))));
    await settle(tester);
    expect(find.text('Go to artist'), findsOneWidget);
    await tester.tap(find.text('Add to playlist'));
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistNew')), findsOneWidget); // the dialog's way to a new playlist
    // The dialog lies over the player: its button takes the tap, and the player stays open.
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistNew')), findsNothing);
    expect(vm.isNowPlayingOpen, isTrue);

    // A swipe down over the cover closes the player.
    await tester.drag(find.descendant(of: player, matching: find.byType(CoverImage)), const Offset(0, 200));
    await settle(tester);
    expect(vm.isNowPlayingOpen, isFalse);
  });

  testWidgets("a track's menu puts it next in the queue, and says so", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    vm.player.playQueue(vm.library.tracks.where((t) => t.title != 'Opening'));
    await settle(tester);
    final menu = find.descendant(
      of: find.ancestor(of: find.text('Opening'), matching: find.byType(InkWell)).first,
      matching: find.byIcon(Icons.more_vert_rounded),
    );

    await tester.tap(menu);
    await settle(tester);
    expect(find.text(Localizer.get('AddToQueue')), findsOneWidget);
    await tester.tap(find.text(Localizer.get('PlayNext')));
    await settle(tester);
    expect(vm.player.queueTracks[vm.player.currentQueueIndex + 1].title, 'Opening');
    expect(find.text(Localizer.format('QueuedNext', ['Opening'])), findsOneWidget);
  });

  testWidgets("on a phone a track's menu downloads it, and the row shows that it is kept", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860), createWithServer);
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    Finder menuOf(String title) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first,
      matching: find.byIcon(Icons.more_vert_rounded),
    );

    // A local file has nothing to download.
    await tester.tap(menuOf('So What'));
    await settle(tester);
    expect(find.text('Go to album'), findsOneWidget);
    expect(find.text('Download to this device'), findsNothing);
    await tester.tapAt(const Offset(10, 10)); // closes the menu
    await settle(tester);

    expect(
      find.descendant(of: find.byType(TrackSliver), matching: find.byIcon(Icons.downloading_rounded)),
      findsNothing,
    );
    await tester.tap(menuOf('Giant Steps'));
    await settle(tester);
    expect(find.text('Add to playlist'), findsOneWidget);
    await tester.tap(find.text('Download to this device'));
    await settle(tester);
    expect(vm.downloads.isTrackDownloaded(vm.library.getTrack('s1')!), isTrue);
    // Waiting for its turn (the downloads have not started in this test): the arrow in progress beside the artist.
    expect(
      find.descendant(of: find.byType(TrackSliver), matching: find.byIcon(Icons.downloading_rounded)),
      findsOneWidget,
    );
  });

  testWidgets('another device of the account can be chosen from the phone, which then shows what plays there', (
    tester,
  ) async {
    AppPlatform.forTesting(system: 'android');
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final hub = FakeRemoteHub();
    final vm = (await tester.runAsync(() async {
      final vm = await createWithServer();
      final session = await signedInSession(vm.library);
      final remote = RemoteClient(session, connector: hub.connect);
      final withRemote = createMainViewModel(vm.library, null, session, remote);
      remote.configure(id: 'phone', name: '', kind: DeviceKind.phone, enabled: true);
      await waitUntil(() => remote.isConnected);
      return withRemote;
    }))!;
    await tester.pumpWidget(WiretuneApp(vm: vm));
    await settle(tester);
    // Online, but nobody else is: the button is there, and its menu says what to do.
    await tester.tap(find.byTooltip(Localizer.get('TipDevices')));
    await settle(tester);
    expect(find.textContaining('No other devices online'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    await tester.runAsync(() async {
      hub.devices([('desk', 'Desk', DeviceKind.desktop)]);
      hub.state('desk', RemotePlayback(track: vm.library.tracks.first, playing: true, queue: ['1'], queueIndex: 0));
      await pumpEventQueue();
    });
    await settle(tester);
    await tester.tap(find.byTooltip(Localizer.get('TipDevices')));
    await settle(tester);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('So What • Miles Davis'), findsOneWidget);
    await tester.tap(find.ancestor(of: find.text('Desk'), matching: find.byType(CheckedPopupMenuItem<String>)));
    await settle(tester);

    expect(vm.player.isRemote, isTrue);
    expect(find.text('Playing on Desk'), findsOneWidget); // in the mini player, in place of the artist
    expect(find.byType(DevicesButton), findsOneWidget); // the page header's: the mini player has none
    expect(find.text('So What'), findsWidgets);
    await tester.tap(find.byTooltip(Localizer.get('TipPause')));
    await settle(tester);
    expect(hub.commandsTo('desk'), [
      {'action': 'toggle'},
    ]);
    vm.dispose();
  });

  testWidgets('signed in, the settings show the downloads and remote control', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    expect(find.text('Remote control'), findsNothing); // signed out: nothing to control

    // An app keeps its view model for life: a signed-in one is another app.
    await tester.pumpWidget(const SizedBox());
    final session = (await tester.runAsync(() => signedInSession(vm.library)))!;
    final signedIn = createMainViewModel(vm.library, null, session)..navigateTo(AppSection.settings);
    await tester.pumpWidget(WiretuneApp(vm: signedIn));
    await settle(tester);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.textContaining('No downloads yet'), findsOneWidget);
    expect(find.text('Remote control'), findsOneWidget);
    final toggle = find.descendant(
      of: find.ancestor(of: find.text('Remote control'), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isFalse, reason: 'the start-up turns it on; this test never started');
    await tester.ensureVisible(toggle);
    await settle(tester);
    await tester.tap(toggle);
    await settle(tester);
    expect(signedIn.isRemoteEnabled, isTrue);
    signedIn.dispose();
  });

  testWidgets('a back link and a sortable column take a click anywhere they light up, not just on the letters', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));

    // The gap between the back arrow and its text.
    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);
    expect(vm.albums.isAlbumDetailOpen, isTrue);
    final arrow = tester.getRect(
      find.descendant(of: find.byType(BackLink), matching: find.byIcon(Icons.arrow_back_rounded)),
    );
    await tester.tapAt(Offset(arrow.right + 4, arrow.center.dy));
    await settle(tester);
    expect(vm.albums.isAlbumDetailOpen, isFalse);

    // The padding beside a column's name.
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final arrows = find.byWidgetPredicate(
      (w) => w is Icon && (w.icon == Icons.north_rounded || w.icon == Icons.south_rounded),
    );
    final artist = tester.getRect(find.text(Localizer.get('ColArtist')).first);
    final before = tester.widgetList<Icon>(arrows).map((i) => i.icon).toList();
    await tester.tapAt(Offset(artist.left - 6, artist.center.dy));
    await settle(tester);
    final artistArrow = find.descendant(
      of: find.ancestor(of: find.text(Localizer.get('ColArtist')).first, matching: find.byType(Row)).first,
      matching: arrows,
    );
    expect(artistArrow, findsOneWidget, reason: 'sorted by artist now (before: $before)');
  });

  testWidgets('a column header and the sort buttons are one setting, kept from the wide layout to the phone', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);

    await tester.tap(find.text(Localizer.get('ColArtist')).first);
    await settle(tester);
    expect(vm.tracks.sortField, TrackSortField.artist);
    expect(find.text(Localizer.get('SortBy')), findsNothing); // the headers are the wide table's sort buttons

    tester.view.physicalSize = const Size(400, 860);
    await settle(tester);
    expect(find.byType(PhoneLayout), findsOneWidget);
    expect(find.text('${Localizer.get('SortArtist')} ↑'), findsOneWidget); // the phone's button, with the direction
    expect([for (final t in vm.tracks.displayedTracks) t.artist], ['Daft Punk', 'Miles Davis', 'Miles Davis']);
  });

  testWidgets('the keyboard and a remote reach what the mouse clicks: the queue cover, a column header', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    Future<void> press(Finder target) async {
      final pressable = find.ancestor(of: target, matching: find.byType(Pressable)).first;
      Focus.of(
        tester.element(find.descendant(of: pressable, matching: find.byType(GestureDetector)).first),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
    }

    await press(find.text(Localizer.get('ColAlbum')).first);
    expect(vm.tracks.sortField, TrackSortField.album);

    vm.player.playQueue(vm.library.tracks);
    await settle(tester);
    final cover = find.descendant(
      of: find.byTooltip(Localizer.get('TipQueueToggle')),
      matching: find.byType(CoverImage),
    );
    await press(cover);
    expect(vm.player.isQueueOpen, isTrue);
  });

  testWidgets("an artist's albums and tracks are counted alike on its tile, its phone row and its page", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final albums = Localizer.format('AlbumCount', [1]);
    final tracks = Localizer.format('TrackCount', [2]);
    vm.navigateTo(AppSection.artists);
    await settle(tester);
    expect(find.text('$albums  •  $tracks'), findsOneWidget); // Miles Davis's tile

    vm.openArtist(vm.library.artists.firstWhere((a) => a.name == 'Miles Davis'));
    await settle(tester);
    final header = find.byType(DetailHeader);
    expect(find.descendant(of: header, matching: find.text(albums)), findsOneWidget);
    expect(find.descendant(of: header, matching: find.text(tracks)), findsOneWidget);

    vm.artists.closeArtistDetail();
    tester.view.physicalSize = const Size(400, 860);
    await settle(tester);
    expect(find.text('$albums  •  $tracks'), findsOneWidget);
  });

  testWidgets("a playlist sorts by its headers on a wide screen and not on a phone; delete is in its header's menu", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final mix = (await tester.runAsync(() async {
      final created = vm.library.createPlaylist('Mix');
      for (final id in ['3', '1']) {
        vm.library.addTracksToPlaylist(created.id, [id]);
      }
      return created;
    }))!;
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    expect(find.text(Localizer.get('SortBy')), findsOneWidget); // the playlists page's sort buttons
    vm.playlists.openPlaylist(vm.library.getPlaylist(mix.id));
    await settle(tester);

    final more = find.descendant(of: find.byType(DetailHeader), matching: find.byTooltip(Localizer.get('TipMore')));
    await tester.tap(more);
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistDeleteAction')), findsOneWidget);
    expect(find.text(Localizer.get('Play')), findsOneWidget, reason: "the header's own button, not the menu's");
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.text(Localizer.get('SortBy')), findsNothing);
    await tester.tap(find.text(Localizer.get('ColTitle')).first);
    await settle(tester);
    expect([for (final t in vm.playlists.selectedPlaylistTracks) t.title], ['Opening', 'So What']);

    tester.view.physicalSize = const Size(400, 860);
    await settle(tester);
    expect(find.text(Localizer.get('SortBy')), findsNothing);
    expect(find.text('ABC ↑'), findsNothing);

    // The phone's play and shuffle are icons alone, on one line with the download and the menu.
    expect(find.text(Localizer.get('Play')), findsNothing);
    expect(find.text(Localizer.get('Shuffle')), findsNothing);
    final play = tester.getCenter(find.byTooltip(Localizer.get('Play')).first);
    expect(tester.getCenter(more).dy, moreOrLessEquals(play.dy, epsilon: 1));
  });

  testWidgets("a playlist's tracks move by their handle or the menu, while it shows its own order", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final mix = (await tester.runAsync(() async {
      final created = vm.library.createPlaylist('Mix');
      vm.library.addTracksToPlaylist(created.id, ['1', '2', '3']);
      return created;
    }))!;
    vm.navigateTo(AppSection.playlists);
    vm.playlists.openPlaylist(vm.library.getPlaylist(mix.id));
    await settle(tester);
    List<String> order() => [for (final t in vm.library.getPlaylistTracks(vm.library.getPlaylist(mix.id)!)) t.id];

    final handles = find.byIcon(Icons.drag_indicator_rounded);
    expect(handles, findsNWidgets(3));
    final drag = await tester.startGesture(tester.getCenter(handles.at(2)));
    for (var i = 0; i < 12; i++) {
      await drag.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await drag.up();
    await settle(tester);
    expect(order(), ['3', '1', '2']);

    final row = find.ancestor(of: find.text('So What'), matching: find.byType(InkWell)).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('TipMoveUp')));
    await settle(tester);
    expect(order(), ['1', '3', '2']);

    // Sorted by a column, the playlist's order isn't what shows: nothing moves.
    await tester.tap(find.text(Localizer.get('ColTitle')).first);
    await settle(tester);
    expect(handles, findsNothing);
  });

  testWidgets("a phone's play and shuffle are round buttons without words, on one line with the sort", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final play = find.ancestor(of: find.byIcon(Icons.play_arrow_rounded), matching: find.byType(FilledButton));
    final shuffle = find.ancestor(of: find.byIcon(Icons.shuffle_rounded), matching: find.byType(OutlinedButton));
    expect(play, findsOneWidget);
    expect(shuffle, findsOneWidget);
    for (final button in [play, shuffle]) {
      expect(tester.getSize(button), const Size.square(PhoneChrome.controlHeight));
      expect(tester.widget<ButtonStyleButton>(button).style?.shape?.resolve({}), isA<CircleBorder>());
    }
    expect(find.descendant(of: play, matching: find.byType(Text)), findsNothing);
    expect(find.byTooltip(Localizer.get('Play')), findsWidgets);
    final sort = tester.getCenter(find.text('ABC ↑'));
    expect(sort.dy, moreOrLessEquals(tester.getCenter(play).dy, epsilon: 1));
  });

  testWidgets("a phone held sideways shows a detail page's header beside its artwork, clear of the status bar", (
    tester,
  ) async {
    AppPlatform.forTesting(system: 'android');
    tester.view.padding = const FakeViewPadding(top: 24);
    final vm = await pumpApp(tester, const Size(850, 390));
    expect(find.byType(PhoneLayout), findsOneWidget);
    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);
    final artwork = tester.getRect(find.descendant(of: find.byType(DetailHeader), matching: find.byType(CoverImage)));
    expect(artwork.right, lessThan(tester.getRect(find.text('Kind of Blue').first).left), reason: 'side by side');
    expect(tester.getTopLeft(find.byType(BackLink)).dy, greaterThanOrEqualTo(24));
  });

  testWidgets("a phone's genre filter cuts a long genre short instead of overflowing the header", (tester) async {
    const genre = 'Progressive Electronic Dance Music';
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue')..genre = genre,
      ]);
      library.initialize();
      return createMainViewModel(library);
    });
    vm.navigateTo(AppSection.albums);
    vm.albums.setGenre(genre);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(genre), findsOneWidget);
  });

  testWidgets("a phone's header buttons are one height, the sort first, and it carries no sort icon", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.library.createPlaylist('Mix');
    final sortLabel = {AppSection.playlists: '${Localizer.get('SortAdded')} ↓', AppSection.tracks: 'ABC ↑'};
    for (final MapEntry(key: section, value: label) in sortLabel.entries) {
      vm.navigateTo(section);
      await settle(tester);
      final sort = find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton)).first;
      final other = switch (section) {
        AppSection.playlists => find.ancestor(
          of: find.text(Localizer.get('PlaylistNew')),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        _ => find.ancestor(of: find.byIcon(Icons.play_arrow_rounded), matching: find.byType(FilledButton)),
      }.first;
      expect(tester.getSize(sort).height, PhoneChrome.controlHeight, reason: section.name);
      expect(tester.getSize(other).height, PhoneChrome.controlHeight, reason: section.name);
      expect(tester.getRect(sort).right, lessThan(tester.getRect(other).left), reason: '${section.name}: sort first');
      expect(find.byIcon(Icons.swap_vert_rounded), findsNothing);
    }
  });

  testWidgets("the phone's navigation has no ripple or bounce, and the desktop's cover holds still", (tester) async {
    await pumpApp(tester, const Size(400, 860));
    final nav = find.ancestor(of: find.text(Localizer.get('NavAlbums')).last, matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(nav).splashFactory, NoSplash.splashFactory);
    expect(find.descendant(of: nav, matching: find.byType(AnimatedScale)), findsNothing);

    tester.view.physicalSize = const Size(1400, 900);
    await settle(tester);
    expect(
      find.descendant(of: find.byTooltip(Localizer.get('TipQueueToggle')), matching: find.byType(ScaleTransition)),
      findsNothing,
    );
  });

  testWidgets('the settings hold the server and the account on one card, the music folders on another', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    final account = find.ancestor(
      of: find.text(Localizer.get('AccountAndConnection')),
      matching: find.byType(GlassCard),
    );
    expect(account, findsOneWidget);
    expect(find.descendant(of: account, matching: find.text(Localizer.get('ServerUrlPlaceholder'))), findsOneWidget);
    expect(find.descendant(of: account, matching: find.text(Localizer.get('NotSignedIn'))), findsOneWidget);
    // Neither the server's folder (not signed in) nor one of this device (it can't scan one): no card for them.
    expect(find.text(Localizer.get('SettingsLibrarySection')), findsNothing);
  });

  testWidgets('tooltips say what a press does next, and a button that says it already has none', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    expect(find.byTooltip(Localizer.get('TipShuffleOn')), findsOneWidget);
    expect(find.byTooltip(Localizer.get('TipRepeatAll')), findsOneWidget);
    vm.player.toggleShuffle();
    vm.player.toggleRepeat();
    await settle(tester);
    expect(find.byTooltip(Localizer.get('TipShuffleOff')), findsOneWidget);
    expect(find.byTooltip(Localizer.get('TipRepeatOne')), findsOneWidget);
    vm.player.toggleRepeat();
    await settle(tester);
    expect(find.byTooltip(Localizer.get('TipRepeatOff')), findsOneWidget);

    vm.navigateTo(AppSection.settings);
    await settle(tester);
    for (final label in [Localizer.get('ConnectShort'), 'Magyar', 'Deutsch']) {
      for (final element in find.text(label).evaluate()) {
        expect(find.ancestor(of: find.byWidget(element.widget), matching: find.byType(Tooltip)), findsNothing);
      }
    }
  });

  testWidgets("the player bar's cover follows the track that plays, without the mouse over it", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final tracks = vm.library.tracks;
    for (final (i, t) in tracks.indexed) {
      t.coverArtPath = '/covers/$i.jpg';
    }
    String? shown() => tester
        .widget<CoverImage>(
          find.descendant(of: find.byTooltip(Localizer.get('TipQueueToggle')), matching: find.byType(CoverImage)),
        )
        .path;
    vm.player.playQueue(tracks, tracks[0]);
    await settle(tester);
    expect(shown(), tracks[0].coverArtPath);
    vm.player.nextTrack();
    await settle(tester);
    expect(shown(), tracks[1].coverArtPath);
  });

  testWidgets('an empty library says so alike on every page of it, with the way to fill it', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary(const []);
      library.initialize();
      return createMainViewModel(library);
    });
    vm.continueOffline();
    for (final section in [AppSection.tracks, AppSection.albums, AppSection.artists]) {
      vm.navigateTo(section);
      await settle(tester);
      expect(find.text(Localizer.get('EmptyLibraryTitle')), findsOneWidget, reason: section.name);
      expect(find.text(Localizer.get('ConnectToServer')), findsOneWidget, reason: section.name);
    }
  });

  testWidgets("an album's tile (its ⋮ and a right click) and its phone row offer one menu, in the same order", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900), createWithServer);
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final expected = [
      Localizer.get('Play'),
      Localizer.get('Shuffle'),
      Localizer.get('PlayNext'),
      Localizer.get('AddToQueue'),
      Localizer.get('TipAddToPlaylist'),
      Localizer.get('TipDownload'),
      Localizer.get('HideAlbum'),
    ];
    List<String> entries() => [
      for (final item in tester.widgetList<PopupMenuItem<Object?>>(find.byWidgetPredicate((w) => w is PopupMenuItem)))
        tester
            .widgetList<Text>(find.descendant(of: find.byWidget(item), matching: find.byType(Text)))
            .map((t) => t.data)
            .join(),
    ];

    await tester.tap(find.text('Giant Steps').first, buttons: kSecondaryButton);
    await settle(tester);
    expect(entries(), expected);
    await tester.tapAt(const Offset(5, 5)); // closes the menu
    await settle(tester);

    final tile = find.ancestor(of: find.text('Giant Steps').first, matching: find.byType(AlbumCard));
    await tester.tap(find.descendant(of: tile, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    expect(entries(), expected);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    tester.view.physicalSize = const Size(400, 860);
    await settle(tester);
    final row = find.ancestor(of: find.text('Giant Steps'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    expect(entries(), expected);
  });

  testWidgets("the table's dates stay on one line, written the language's way", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    for (final t in vm.library.tracks) {
      t.addedAt = DateTime(2026, 10, 11);
    }
    for (final (language, date) in [('en', '2026-10-11'), ('hu', '2026.10.11'), ('de', '11.10.2026')]) {
      vm.changeLanguage(language);
      vm.navigateTo(AppSection.albums);
      await settle(tester);
      vm.navigateTo(AppSection.tracks);
      await settle(tester);
      final dates = find.descendant(of: find.byType(TrackSliver), matching: find.text(date));
      expect(dates, findsNWidgets(3), reason: language);
      // (The test font's square glyphs are wider than any real font's, so how much of it shows proves nothing.)
      for (final element in dates.evaluate()) {
        expect(tester.getSize(find.byWidget(element.widget)).height, lessThan(13 * 1.5), reason: '$language: $date');
      }
    }
  });

  testWidgets('a track played from a list sorted by its header queues the list in the order shown', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);

    await tester.tap(find.text(Localizer.get('ColTitle')).first);
    await settle(tester);
    await tester.tap(find.text('So What').last);
    await settle(tester);
    expect([for (final t in vm.player.queueTracks) t.title], ['Blue in Green', 'So What']);
  });

  testWidgets('the sign-in page covers the app while it is active', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    expect(find.text(Localizer.get('Connect')), findsNothing);
    vm.showLoginScreen();
    await settle(tester);
    expect(find.text(Localizer.get('Connect')), findsWidgets);
  });
}
