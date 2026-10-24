// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'package:wiretune/src/theme/app_theme.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/library_view_models.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/ambient.dart';
import 'package:wiretune/src/widgets/badges.dart';
import 'package:wiretune/src/widgets/buttons.dart';
import 'package:wiretune/src/widgets/cards.dart';
import 'package:wiretune/src/widgets/cover_flight.dart';
import 'package:wiretune/src/widgets/cover_image.dart';
import 'package:wiretune/src/widgets/devices.dart';
import 'package:wiretune/src/widgets/page_parts.dart';
import 'package:wiretune/src/widgets/player_controls.dart';
import 'package:wiretune/src/widgets/player_sheet.dart';
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
    expect(vm.nowPlayingTab, NowPlayingTab.track);

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

  testWidgets("a phone's track row ends with its menu alone, the favourite in it, so the title has the room", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final row = find.ancestor(of: find.text('So What'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: row, matching: find.byType(HeartIcon)), findsNothing);
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('TipFavorite')));
    await settle(tester);
    expect(vm.library.isFavorite('1'), isTrue);
  });

  testWidgets("the mini player's cover and Play stand over the nav's Artists and Playlists icons", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([TestSupport.makeTrack('1', 'So What', album: 'Kind of Blue')]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.player.playQueue(vm.library.tracks);
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    double centre(Finder finder) => tester.getCenter(finder).dx;
    final cover = find.byWidgetPredicate((w) => w is CoverImage && w.size == 44);
    expect(centre(cover), moreOrLessEquals(centre(find.byIcon(Icons.person_rounded).last), epsilon: 0.5));
    expect(
      centre(find.byWidgetPredicate((w) => w is PlayButton && w.size == 38)),
      moreOrLessEquals(centre(find.byIcon(Icons.queue_music_rounded).last), epsilon: 0.5),
    );
  });

  testWidgets("renaming a playlist on a phone fits the field and its buttons on the screen", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    final playlist = vm.library.createPlaylist('My summer playlist');
    vm.navigateTo(AppSection.playlists);
    vm.playlists.openPlaylist(vm.library.getPlaylist(playlist.id));
    await settle(tester);
    vm.playlists.startRename();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byTooltip(Localizer.get('Cancel'))).right, lessThanOrEqualTo(400));
    expect(tester.getSize(find.byType(TextField)).height, lessThan(56));
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
      // The format's tag; the player's bitrate below the cover is a tag too.
      final tag = find.descendant(
        of: page,
        matching: find.byWidgetPredicate((w) => w is QualityTag && !(w.spec ?? '').endsWith('kbps')),
      );
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
    expect(tester.widget<PlayShuffleButtons>(find.byType(PlayShuffleButtons)).download, isNull, reason: 'no button');
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
    await tester.fling(find.text(vm.player.nowPlayingTitle), const Offset(0, -120), 1000); // on the mini player
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
    await tester.fling(find.descendant(of: player, matching: find.byType(CoverImage)), const Offset(0, 200), 1000);
    await settle(tester);
    expect(vm.isNowPlayingOpen, isFalse);
  });

  testWidgets('on a phone the full-screen player follows the finger, then goes on or back where it is let go', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.player.playQueue(vm.library.tracks);
    await settle(tester);
    final page = find.byType(NowPlayingPage);
    // Its top as drawn: it pours out of the mini player's cover, so from there (closed) to the screen's top (open).
    final sheet = tester.widget<PlayerSheetScope>(find.byType(PlayerSheetScope)).sheet;
    final lamp = tester.getCenter(find.byKey(sheet.lamp)).dy;
    double top() => lamp * (1 - sheet.position.value);
    // A test gesture's moves carry no time: let go, it is still, not flung.
    Future<void> drag(Finder from, double dy, {required double whileHeld}) async {
      final finger = await tester.startGesture(tester.getCenter(from));
      await finger.moveBy(Offset(0, dy.sign * 20)); // past the slop: the drag starts here
      await finger.moveBy(Offset(0, dy));
      await tester.pump();
      expect(top(), moreOrLessEquals(whileHeld, epsilon: 1), reason: 'under the finger');
      await finger.up();
      await settle(tester);
    }

    // Up from the mini player, short of half the screen: it comes up with the finger, and sinks back.
    final mini = find.text(vm.player.nowPlayingTitle);
    await drag(mini, -300, whileHeld: lamp - 300);
    expect((vm.isNowPlayingOpen, page.evaluate().isEmpty), (false, true));

    // Past half: it goes on up, and is open.
    await drag(mini, -500, whileHeld: lamp - 500);
    expect((vm.isNowPlayingOpen, top()), (true, 0));

    // Down from the open player, a little: it goes back up, still open.
    await drag(find.descendant(of: page, matching: find.byType(CoverImage)), 200, whileHeld: 200);
    expect((vm.isNowPlayingOpen, top()), (true, 0));
  });

  testWidgets('a phone stays upright; a tablet turns', (tester) async {
    AppPlatform.forTesting(system: 'android');
    final orientations = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') orientations.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpApp(tester, const Size(400, 860));
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    tester.view.physicalSize = const Size(1280, 800);
    await settle(tester);
    expect(orientations.last, isEmpty, reason: 'every way the system allows');
  });

  testWidgets('the system is told the app wants back exactly while it has somewhere to go back to', (tester) async {
    // Android 16 sends a back gesture to the app only if told so beforehand; else it closes the app.
    final handlesBack = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') handlesBack.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    vm.albums.openAlbum(vm.albums.displayedAlbums.first);
    await settle(tester);
    expect(handlesBack.last, isTrue, reason: 'an album is open');

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.albums.isAlbumDetailOpen, isFalse);
    expect(handlesBack.last, isTrue, reason: 'back returns to the tab before');

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(vm.selectedSection, isNot(AppSection.albums));
    expect(handlesBack.last, isFalse, reason: 'nothing is left: the system leaves the app');
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

  testWidgets('a sortable column takes a click anywhere it lights up, not just on the letters', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));

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
    expect(
      find.byWidgetPredicate((w) => w is SortLabel && w.label == '${Localizer.get('SortArtist')} ↑'),
      findsOneWidget,
    ); // the phone's button, with the direction
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
    expect(find.byType(SortLabel), findsNothing);

    // The phone's play and shuffle are icons alone; the menu is the top bar's, with delete in it.
    expect(find.text(Localizer.get('Play')), findsNothing);
    expect(find.text(Localizer.get('Shuffle')), findsNothing);
    expect(more, findsNothing);
    await tester.tap(find.byTooltip(Localizer.get('TipMore')).last);
    await settle(tester);
    expect(find.text(Localizer.get('PlaylistDeleteAction')), findsOneWidget);
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

  testWidgets("a phone's play and shuffle are round buttons without words, on one line with the sort, Play last", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final header = find.byType(PageHeader);
    final play = find.descendant(of: header, matching: find.byType(FilledButton));
    final shuffle = find.descendant(of: header, matching: find.byType(ShuffleSwitch));
    expect(play, findsOneWidget);
    expect(shuffle, findsOneWidget);
    expect(tester.getRect(shuffle).right, lessThan(tester.getRect(play).left));
    expect(tester.getRect(play).right, moreOrLessEquals(400 - 16, epsilon: 1), reason: 'the edges are 16 px');
    expect(tester.getSize(play), const Size.square(PhoneChrome.playSize));
    expect(tester.widget<ButtonStyleButton>(play).style?.shape?.resolve({}), isA<CircleBorder>());
    expect(tester.getSize(shuffle), const Size.square(PhoneChrome.controlHeight));
    expect(find.descendant(of: play, matching: find.byType(Text)), findsNothing);
    expect(find.byTooltip(Localizer.get('Play')), findsWidgets);
    final sort = tester.getCenter(find.byWidgetPredicate((w) => w is SortLabel && w.label == 'ABC ↑'));
    expect(sort.dy, moreOrLessEquals(tester.getCenter(play).dy, epsilon: 1));
  });

  testWidgets(
    "a list's Play pauses and resumes it while the queue is that list, and plays it once the queue is another",
    (tester) async {
      final vm = await pumpApp(tester, const Size(400, 860), () async {
        final library = createLibrary([
          TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
          TestSupport.makeTrack('2', 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 2),
          TestSupport.makeTrack('3', 'Opening', artist: 'Daft Punk', album: 'Random Access Memories'),
        ]);
        library.initialize();
        return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
      });
      final player = vm.player;
      vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
      await settle(tester);
      final header = find.byType(DetailHeader);
      final play = find.descendant(of: header, matching: find.byType(FilledButton));
      Finder says(String key) => find.descendant(of: header, matching: find.byTooltip(Localizer.get(key)));
      expect(says('Play'), findsOneWidget);
      // Shuffle and Play at the right, Play over the ⋮ of the rows; the menu is the top bar's.
      expect(find.descendant(of: header, matching: find.byTooltip(Localizer.get('TipMore'))), findsNothing);
      final rowMenu = find.descendant(of: find.byType(TrackSliver), matching: find.byTooltip(Localizer.get('TipMore')));
      expect(tester.getCenter(play).dx, moreOrLessEquals(tester.getCenter(rowMenu.first).dx, epsilon: 0.5));
      expect(tester.getSize(play), const Size.square(PhoneChrome.playSize));

      await tester.tap(play);
      await settle(tester);
      expect((player.isPlaying, player.currentTrack?.title), (true, 'So What'));
      expect(says('Pause'), findsOneWidget);
      await tester.tap(play);
      await settle(tester);
      expect((player.isPlaying, player.currentTrack?.title), (false, 'So What'));
      expect(says('Play'), findsOneWidget);
      await tester.tap(play);
      await settle(tester);
      expect((player.isPlaying, player.currentTrack?.title), (true, 'So What'));
      player.nextTrack(); // the album's next track: the queue is still the album
      await settle(tester);
      expect(says('Pause'), findsOneWidget);
      await tester.tap(play);
      await settle(tester);
      expect((player.isPlaying, player.currentTrack?.title), (false, 'Blue in Green'), reason: 'paused, not restarted');

      player.playQueue(vm.library.tracks.where((t) => t.album == 'Random Access Memories'));
      await settle(tester);
      expect(says('Play'), findsOneWidget);
      await tester.tap(play);
      await settle(tester);
      expect((player.isPlaying, player.currentTrack?.title), (true, 'So What'));
    },
  );

  testWidgets("a phone's track lists sort by bitrate too, from their sort menu", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    Finder sortLabel(String label) => find.byWidgetPredicate((w) => w is SortLabel && w.label == label);
    await tester.tap(sortLabel('ABC ↑'));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('SortBitrate')));
    await settle(tester);
    expect(vm.tracks.sortField, TrackSortField.bitrate);
    expect(sortLabel('${Localizer.get('SortBitrate')} ↓'), findsOneWidget);
    // The arrow turns round with the order, as the same arrow.
    final arrow = find.descendant(
      of: sortLabel('${Localizer.get('SortBitrate')} ↓'),
      matching: find.byType(AnimatedRotation),
    );
    expect(tester.widget<AnimatedRotation>(arrow).turns, 0.5);
  });

  testWidgets("a list's shuffle is the player's switch: Play starts at the first track while it is off", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        for (var i = 1; i <= 12; i++) TestSupport.makeTrack('$i', 'Take $i', album: 'Kind of Blue', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    final player = vm.player;
    vm.openAlbum(vm.library.albums.single);
    await settle(tester);
    final header = find.byType(DetailHeader);
    final shuffle = find.descendant(of: header, matching: find.byType(ShuffleSwitch));
    final play = find.descendant(of: header, matching: find.byType(FilledButton));
    // An icon alone, without a button's frame; a dot under it while on.
    expect(find.descendant(of: shuffle, matching: find.byType(OutlinedButton)), findsNothing);
    Finder dot() => find.descendant(
      of: shuffle,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    expect(dot(), findsNothing);

    await tester.tap(play);
    await settle(tester);
    expect((player.isShuffle, player.currentTrack?.title), (false, 'Take 1'));
    expect(player.queueTracks.map((t) => t.title), [for (var i = 1; i <= 12; i++) 'Take $i']);

    await tester.tap(shuffle);
    await settle(tester);
    expect(player.isShuffle, isTrue);
    expect(dot(), findsOneWidget);
    expect(
      tester.widget<Icon>(find.descendant(of: shuffle, matching: find.byType(Icon))).color,
      tester.element(shuffle).colors.accent,
    );
    expect(find.descendant(of: header, matching: find.byTooltip(Localizer.get('TipShuffleOff'))), findsOneWidget);

    await tester.tap(shuffle);
    await settle(tester);
    expect((player.isShuffle, dot().evaluate().isEmpty), (false, true));

    // The desktop's is the same switch, beside its Play.
    tester.view.physicalSize = const Size(1400, 900);
    await settle(tester);
    expect(find.descendant(of: shuffle, matching: find.byType(OutlinedButton)), findsNothing);
    expect(find.descendant(of: header, matching: find.text(Localizer.get('Shuffle'))), findsNothing);
    await tester.tap(shuffle);
    await settle(tester);
    expect((player.isShuffle, dot().evaluate().length), (true, 1));
    expect(tester.getRect(shuffle).left, greaterThan(tester.getRect(play).right), reason: 'Play first');
  });

  testWidgets("the best match's Play pauses and resumes what it played, as a tile's does", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
        TestSupport.makeTrack('2', 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 2),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.searchQuery = 'Kind of Blue';
    await settle(tester);
    final best = find.byWidgetPredicate((w) => w is TilePlayButton && w.size == 48);
    Finder says(String key) => find.descendant(of: best, matching: find.byTooltip(Localizer.get(key)));
    expect(says('Play'), findsOneWidget);
    await tester.tap(best);
    await settle(tester);
    expect(vm.player.isPlaying, isTrue);
    expect(says('Pause'), findsOneWidget);
    await tester.tap(best);
    await settle(tester);
    expect((vm.player.isPlaying, vm.player.currentTrack?.title), (false, 'So What'));
    expect(says('Play'), findsOneWidget);
  });

  testWidgets("a phone page's top bar keeps its buttons at hand, and takes the page's name over with the scroll", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        for (var i = 1; i <= 60; i++)
          TestSupport.makeTrack('$i', 'Take $i', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    ScrollPosition scroll() => tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    double shown(Finder text) =>
        tester.widget<Opacity>(find.ancestor(of: text, matching: find.byType(Opacity)).first).opacity;

    vm.openAlbum(vm.library.albums.single);
    await settle(tester);
    final bar = find.byType(PinnedTitleBar);
    Finder inBar(Finder finder) => find.descendant(of: bar, matching: finder);
    final headerName = find.descendant(of: find.byType(DetailHeader), matching: find.text('Kind of Blue'));
    final barName = find.descendant(of: find.byType(OverflowBox), matching: find.text('Kind of Blue'));
    // The way back, the search and the album's ⋮ are there from the start, once each; the header leaves them to it.
    expect(shown(headerName), 1);
    expect(barName, findsNothing);
    expect(find.byTooltip(Localizer.get('Back')), findsOneWidget);
    expect(find.byTooltip(Localizer.get('Search')), findsOneWidget);
    final more = find.descendant(of: find.byType(DetailHeader), matching: find.byTooltip(Localizer.get('TipMore')));
    expect(more, findsNothing, reason: "the header's ⋮ is the bar's");
    expect(find.byType(ListPlayButton), findsOneWidget, reason: "the header's alone");

    // The bar takes the name over as it reaches the shade (which would darken it in the page), right where it is; it
    // goes on up with the page to the bar's middle, and shrinks there into the bar's title beside the way back.
    final nameRect = tester.getRect(headerName);
    final shadeBottom = PinnedTitleBar.height + 40;
    final entered = nameRect.top - shadeBottom;
    scroll().jumpTo(entered - 4);
    await settle(tester);
    expect((shown(headerName), barName.evaluate().isEmpty), (1, true));
    scroll().jumpTo(entered + 10);
    await settle(tester);
    expect(shown(headerName), 0);
    expect(tester.getRect(barName), nameRect.shift(Offset(0, -(entered + 10))), reason: 'where it was, unshrunk');
    final reached = nameRect.center.dy - PinnedTitleBar.height / 2;
    scroll().jumpTo(reached);
    await settle(tester);
    expect(tester.getRect(barName).center.dy, moreOrLessEquals(PinnedTitleBar.height / 2, epsilon: 0.5));
    expect(tester.getRect(barName).height, moreOrLessEquals(nameRect.height, epsilon: 0.5));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await settle(tester);
    expect(tester.getRect(barName).height, moreOrLessEquals(nameRect.height * 17 / 24, epsilon: 0.5));
    expect(tester.getRect(barName).left, moreOrLessEquals(4 + PinnedTitleBar.buttonSize, epsilon: 0.5));
    expect(tester.getCenter(barName).dy, moreOrLessEquals(PinnedTitleBar.height / 2, epsilon: 0.5));
    // Scrolled far down, the album's menu is still at hand (the bar's ⋮ is over the rows', the last).
    await tester.tap(find.byTooltip(Localizer.get('TipMore')).last);
    await settle(tester);
    expect(find.text(Localizer.get('AddToQueue')), findsOneWidget);
    await tester.tap(find.text(Localizer.get('AddToQueue')));
    await settle(tester);
    expect(vm.player.queueTracks, hasLength(60));
    await tester.tap(inBar(find.byTooltip(Localizer.get('Back'))));
    await settle(tester);
    expect(vm.albums.isAlbumDetailOpen, isFalse);

    // A list page's big title is the bar's from the start, where the header had it, and shrinks into it with the
    // scroll; no way back, and the header's devices, search and account buttons are the bar's.
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final tracks = Localizer.get('NavTracks');
    final shrinking = find.descendant(of: find.byType(OverflowBox), matching: find.text(tracks));
    final headerTitle = find.descendant(of: find.byType(PageHeader), matching: find.text(tracks));
    double size() => tester.getRect(shrinking).height; // as drawn, scaled
    expect(tester.getRect(shrinking), tester.getRect(headerTitle), reason: 'in the place of the header’s');
    expect(shown(headerTitle), 0);
    final full = size();
    expect(find.byTooltip(Localizer.get('Search')), findsOneWidget);
    expect(find.byTooltip(Localizer.get('NavSettings')), findsOneWidget);
    scroll().jumpTo(28);
    await settle(tester);
    expect(size(), inExclusiveRange(full * 17 / 30, full));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await settle(tester);
    expect(size(), moreOrLessEquals(full * 17 / 30, epsilon: 0.5));
    expect(tester.getCenter(shrinking).dy, moreOrLessEquals(PinnedTitleBar.height / 2, epsilon: 0.5));
    expect(inBar(find.byTooltip(Localizer.get('Back'))), findsNothing);
    await tester.tap(find.byTooltip(Localizer.get('Search')));
    await settle(tester);
    expect(vm.isSearchOpen, isTrue, reason: 'search, however far the page is scrolled');
    vm.closeSearch();
    await settle(tester);

    // Far down, where the header is no longer built, and back to the page, which keeps its place: the bar too.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await settle(tester);
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    expect(find.text('Take 2'), findsNothing, reason: 'still scrolled');
    expect(size(), moreOrLessEquals(full * 17 / 30, epsilon: 0.5));
    expect(tester.getCenter(shrinking).dy, moreOrLessEquals(PinnedTitleBar.height / 2, epsilon: 0.5));

    // A playlist's name, which renames it, doesn't shrink: it fades as it reaches the bar, whose own comes up after.
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    vm.playlists.createPlaylist('Mix', vm.library.tracks.take(30).toList());
    await settle(tester);
    final risen = find.byWidgetPredicate((w) => w is Text && w.data == 'Mix' && w.style?.fontSize == 17);
    expect(shown(risen), 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await settle(tester);
    expect(shown(risen), 1);
  });

  testWidgets("a phone page keeps its place across the tabs, and its tab chosen again takes it to the top", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        for (var i = 1; i <= 40; i++)
          TestSupport.makeTrack('$i', 'Song $i', artist: 'Artist ${'$i'.padLeft(2, '0')}', album: 'Album $i'),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.artists);
    await settle(tester);
    double offset() => tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await settle(tester);
    final scrolled = offset();
    expect(scrolled, greaterThan(500));

    final artistsTab = find.text(Localizer.get('NavArtists')).last;
    await tester.tap(find.text(Localizer.get('NavAlbums')).last);
    await settle(tester);
    await tester.tap(artistsTab);
    await settle(tester);
    expect(offset(), scrolled, reason: 'where it was');

    await tester.tap(artistsTab);
    await settle(tester);
    expect(offset(), 0);

    // From an artist's page the tab leads back to the list, where it was.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await settle(tester);
    final again = offset();
    vm.openArtist(vm.library.artists.last);
    await settle(tester);
    await tester.tap(artistsTab);
    await settle(tester);
    expect((vm.artists.isArtistDetailOpen, offset()), (false, again));
  });

  testWidgets("the player's BPM and bitrate sit midway between the cover, at its size while playing, and the title", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        Track(
          id: '1',
          title: 'So What',
          album: 'Kind of Blue',
          filePath: '/music/1.flac',
          format: const AudioFormat(
            codec: 'FLAC',
            sampleRate: 44100,
            bitsPerSample: 16,
            bitrateKbps: 912,
            isLossless: true,
          ),
        )..bpm = 136,
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    await settle(tester);
    final page = find.byType(NowPlayingPage);
    for (final playing in [true, false]) {
      if (!playing) await vm.player.pause();
      await tester.pump(const Duration(seconds: 1));
      expect(vm.player.isPlaying, playing);
      final cover = tester.getRect(
        find
            .ancestor(
              of: find.descendant(of: page, matching: find.byType(CoverImage)),
              matching: find.byType(AnimatedScale),
            )
            .first,
      ); // unscaled
      final bpm = tester.getCenter(find.text('136 BPM'));
      final bitrate = tester.getCenter(find.text(Localizer.format('BitrateKbps', [912])));
      final title = tester.getRect(find.descendant(of: page, matching: find.text('So What')));
      expect(bpm.dy, moreOrLessEquals((cover.bottom + title.top) / 2, epsilon: 0.5), reason: 'playing: $playing');
      expect(bitrate.dy, moreOrLessEquals(bpm.dy, epsilon: 0.5), reason: 'beside it');
      expect(bitrate.dx, greaterThan(bpm.dx));
    }
  });

  testWidgets("the full-screen player's artist is in the artists' red, whatever the section's colour", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis')]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.albums); // the albums' purple is the accent
    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    await settle(tester);
    final artist = find.descendant(of: find.byType(NowPlayingPage), matching: find.text('Miles Davis'));
    expect(tester.widget<Text>(artist).style?.color, tester.element(artist).colors.palette.coral);
  });

  testWidgets("dragging the player's seek bar seeks, and is no swipe", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        TestSupport.makeTrack('1', 'So What', album: 'Kind of Blue', trackNumber: 1),
        TestSupport.makeTrack('2', 'Blue in Green', album: 'Kind of Blue', trackNumber: 2),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.playerSwipe = PlayerSwipe.tracks;
    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    await settle(tester);
    final seek = find.descendant(of: find.byType(SeekBar), matching: find.byType(Slider)).first;
    await tester.drag(seek, const Offset(-150, 0));
    await settle(tester);
    expect(vm.player.currentTrack?.title, 'So What');
    await tester.drag(seek, const Offset(150, 0));
    await settle(tester);
    expect(vm.player.currentTrack?.title, 'So What');
    expect(vm.player.position.value, greaterThan(Duration.zero), reason: 'it seeked');
  });

  testWidgets("a swipe in the player asks once what it does, then does it; the settings change it", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860), () async {
      final library = createLibrary([
        TestSupport.makeTrack('1', 'So What', album: 'Kind of Blue', trackNumber: 1),
        TestSupport.makeTrack('2', 'Blue in Green', album: 'Kind of Blue', trackNumber: 2),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    final player = vm.player;
    player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    await settle(tester);
    Future<void> swipeLeft() async {
      await tester.fling(find.byType(NowPlayingPage), const Offset(-200, 0), 1000, warnIfMissed: false);
      await settle(tester);
    }

    await swipeLeft();
    expect(find.text(Localizer.get('PlayerSwipeQuestion')), findsOneWidget);
    expect(player.currentTrack?.title, 'So What', reason: 'nothing happens before the answer');
    await tester.tap(find.text(Localizer.get('PlayerSwipeTracks')));
    await settle(tester);
    expect(vm.playerSwipe, PlayerSwipe.tracks);
    expect(player.currentTrack?.title, 'Blue in Green');

    await tester.fling(find.byType(NowPlayingPage), const Offset(200, 0), 1000, warnIfMissed: false);
    await settle(tester);
    expect(find.text(Localizer.get('PlayerSwipeQuestion')), findsNothing, reason: 'asked once');
    expect(player.currentTrack?.title, 'So What');

    vm.closeNowPlaying();
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    // Mid-screen: clear of the title bar above and the floating bars below.
    unawaited(Scrollable.ensureVisible(tester.element(find.text(Localizer.get('PlayerSwipeTabs'))), alignment: 0.5));
    await settle(tester);
    await tester.tap(find.text(Localizer.get('PlayerSwipeTabs')));
    await settle(tester);
    expect(vm.playerSwipe, PlayerSwipe.tabs);
    expect(vm.library.getPreference('player_swipe'), 'tabs');

    vm.openNowPlaying();
    await settle(tester);
    await swipeLeft();
    expect((vm.nowPlayingTab, player.currentTrack?.title), (NowPlayingTab.queue, 'So What'));
    await swipeLeft();
    await swipeLeft();
    expect(vm.nowPlayingTab, NowPlayingTab.lyrics, reason: 'the last tab stays');
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
      final sort = find
          .ancestor(
            of: find.byWidgetPredicate((w) => w is SortLabel && w.label == label),
            matching: find.byType(OutlinedButton),
          )
          .first;
      final other = switch (section) {
        AppSection.playlists => find.ancestor(
          of: find.text(Localizer.get('PlaylistNew')),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
        _ => find.byType(ShuffleSwitch),
      }.first;
      expect(tester.getSize(sort).height, PhoneChrome.controlHeight, reason: section.name);
      expect(tester.getSize(other).height, PhoneChrome.controlHeight, reason: section.name);
      expect(tester.getRect(sort).right, lessThan(tester.getRect(other).left), reason: '${section.name}: sort first');
      expect(find.byIcon(Icons.swap_vert_rounded), findsNothing);
    }
  });

  testWidgets("a TV remote moves between the sidebar, the page, the player bar and the search box, and never sticks", (
    tester,
  ) async {
    AppPlatform.forTesting(system: 'linux', tizen: true, tv: true);
    final vm = await pumpApp(tester, const Size(1920, 1080), () async {
      final library = createLibrary([
        for (var a = 1; a <= 24; a++)
          for (var t = 1; t <= 3; t++)
            TestSupport.makeTrack('$a-$t', 'Song $a.$t', artist: 'Artist ${a % 12 + 1}', album: 'Album $a'),
      ]);
      library.initialize();
      return createMainViewModel(library);
    });
    Future<void> press(LogicalKeyboardKey key, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        await tester.sendKeyEvent(key);
        await settle(tester);
      }
    }

    FocusNode focus() => FocusManager.instance.primaryFocus!;
    bool within(Finder area) => tester.getRect(area).contains(tester.getCenter(find.byWidget(focus().context!.widget)));
    final sidebar = find.ancestor(of: find.text(Localizer.get('NavArtists')), matching: find.byType(ListView)).first;
    final searchBox = find.byType(TextField);
    final grid = find.byType(TabPageList); // the page: its header and its tiles
    expect(within(sidebar), isTrue, reason: 'the sidebar has the focus at start');

    // Up into the search box, and Down out of it again: its cursor doesn't keep the arrows.
    await press(LogicalKeyboardKey.arrowUp);
    expect(focus().context!.findAncestorWidgetOfExactType<TextField>(), isNotNull);
    await press(LogicalKeyboardKey.arrowDown);
    expect(within(grid), isTrue, reason: 'into the page');
    expect(within(searchBox), isFalse);

    // Left from the page's edge to the sidebar, Right back into the page.
    await press(LogicalKeyboardKey.arrowDown);
    await press(LogicalKeyboardKey.arrowLeft, 10);
    expect(within(sidebar), isTrue);
    await press(LogicalKeyboardKey.arrowRight);
    expect(within(grid), isTrue);

    // OK opens the artist with something lit on its page; Back closes it with something lit again.
    await press(LogicalKeyboardKey.select);
    expect(vm.artists.isArtistDetailOpen, isTrue);
    expect(focus(), isNot(isA<FocusScopeNode>()));
    await press(LogicalKeyboardKey.escape);
    expect(vm.artists.isArtistDetailOpen, isFalse);
    expect(focus(), isNot(isA<FocusScopeNode>()));

    // Down past the page's end to the player bar, and Up back to the same tile; a tile is one step (its buttons are
    // passed by).
    FocusNode? last;
    for (var i = 0; i < 8 && within(grid); i++) {
      expect(focus().context!.findAncestorWidgetOfExactType<TilePlayButton>(), isNull);
      last = focus();
      await press(LogicalKeyboardKey.arrowDown);
    }
    expect(within(grid), isFalse, reason: 'in the player bar');
    expect(within(sidebar), isFalse);
    await press(LogicalKeyboardKey.arrowUp);
    expect(focus(), last, reason: 'the page keeps its place');
  });

  testWidgets("on a TV the sign-in page has the remote's focus, and the arrows move through its fields and buttons", (
    tester,
  ) async {
    AppPlatform.forTesting(system: 'linux', tizen: true, tv: true);
    final vm = await pumpApp(tester, const Size(1920, 1080), () async {
      final library = createLibrary(const []);
      library.initialize();
      return createMainViewModel(library);
    });
    vm.isLoginViewActive = true;
    await settle(tester);
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await settle(tester);
    }

    FocusNode focus() => FocusManager.instance.primaryFocus!;
    String? hint() => focus().context!.findAncestorWidgetOfExactType<TextField>()?.decoration?.hintText;
    bool on(String label) =>
        find.ancestor(of: find.text(label), matching: find.byWidget(focus().context!.widget)).evaluate().isNotEmpty;
    expect(hint(), 'http://192.168.1.10:5200', reason: 'the address first, not the layout behind the page');
    await press(LogicalKeyboardKey.arrowRight); // the cursor is at the end: on to the button beside
    expect(on(Localizer.get('Connect')), isTrue);
    await press(LogicalKeyboardKey.arrowLeft);
    expect(hint(), 'http://192.168.1.10:5200');
    await press(LogicalKeyboardKey.arrowDown);
    expect(hint(), Localizer.get('UsernamePlaceholder'));
    await press(LogicalKeyboardKey.arrowDown);
    expect(hint(), Localizer.get('PasswordPlaceholder'));
    await press(LogicalKeyboardKey.arrowDown);
    await press(LogicalKeyboardKey.arrowDown);
    expect(on(Localizer.get('SignIn')), isTrue);
    await press(LogicalKeyboardKey.arrowUp);
    await press(LogicalKeyboardKey.arrowUp);
    expect(hint(), Localizer.get('PasswordPlaceholder'));
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
    for (final label in [
      Localizer.get('ConnectShort'),
      'Magyar',
      'Deutsch',
      Localizer.get('ThemeDark'),
      Localizer.get('ThemeLight'),
    ]) {
      for (final element in find.text(label).evaluate()) {
        expect(find.ancestor(of: find.byWidget(element.widget), matching: find.byType(Tooltip)), findsNothing);
      }
    }
    final light = find.text(Localizer.get('ThemeLight'));
    await tester.ensureVisible(light);
    await settle(tester);
    await tester.tap(light);
    await settle(tester);
    expect(vm.isLight, isTrue);
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
      Localizer.get('GoToArtist'),
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

  testWidgets("an album's menu leads to its artist, but not on that artist's page or in the album's header", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    Future<void> openTileMenu() async {
      final tile = find.ancestor(of: find.text('Kind of Blue').first, matching: find.byType(AlbumCard));
      await tester.tap(find.descendant(of: tile, matching: find.byIcon(Icons.more_vert_rounded)));
      await settle(tester);
      expect(find.text(Localizer.get('PlayNext')), findsOneWidget, reason: 'the menu is open');
    }

    vm.navigateTo(AppSection.albums);
    await settle(tester);
    await openTileMenu();
    await tester.tap(find.text(Localizer.get('GoToArtist')));
    await settle(tester);
    expect((vm.selectedSection, vm.artists.selectedArtist?.name), (AppSection.artists, 'Miles Davis'));

    await openTileMenu(); // the album's tile on its artist's page
    expect(find.text(Localizer.get('GoToArtist')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(DetailHeader), matching: find.byTooltip(Localizer.get('TipMore'))),
    );
    await settle(tester);
    expect(find.text(Localizer.get('PlayNext')), findsOneWidget);
    expect(find.text(Localizer.get('GoToArtist')), findsNothing, reason: "the artist's name above is the link");
  });

  testWidgets('the playlists page and the sidebar count the automatic playlists too', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    await tester.runAsync(() async {
      vm.library.recordPlay('1');
      vm.library.createPlaylist('Mix');
    });
    vm.navigateTo(AppSection.playlists);
    await settle(tester);
    final count = vm.playlists.allPlaylists.length;
    expect(count, greaterThan(vm.playlists.playlists.length), reason: 'the most and the recently played');
    expect(find.text(Localizer.format('PlaylistCount', [count])), findsOneWidget);
    final sidebar = find.ancestor(of: find.text(Localizer.get('NavPlaylists')).first, matching: find.byType(InkWell));
    expect(find.descendant(of: sidebar.first, matching: find.text('$count')), findsOneWidget);
  });

  testWidgets("a phone's Settings page has neither the search nor the account button, which leads there", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    expect(find.byTooltip(Localizer.get('NavSettings')), findsOneWidget);
    vm.navigateTo(AppSection.settings);
    await settle(tester);
    expect(find.byTooltip(Localizer.get('NavSettings')), findsNothing);
    expect(find.byTooltip(Localizer.get('Search')), findsNothing);
  });

  testWidgets("both players show shuffle and repeat alike, and the phone's queue says how many tracks it holds", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.player.playQueue(vm.library.tracks);
    vm.player.toggleShuffle();
    await settle(tester);
    List<bool> modes(Finder within) => [
      for (final b in tester.widgetList<PlayerModeButton>(
        find.descendant(of: within, matching: find.byType(PlayerModeButton)),
      ))
        b.on,
    ];
    expect(modes(find.byType(WideLayout)), [true, false]);

    tester.view.physicalSize = const Size(400, 860);
    vm.openNowPlaying();
    await settle(tester);
    final player = find.byType(NowPlayingPage);
    expect(modes(player), [true, false]);

    vm.nowPlayingTab = NowPlayingTab.queue;
    await settle(tester);
    expect(find.descendant(of: player, matching: find.text(Localizer.format('TrackCount', [3]))), findsOneWidget);
    expect(find.descendant(of: player, matching: find.byIcon(Icons.playlist_remove_rounded)), findsOneWidget);
    // A phone's queue rows are its track rows' size, their red × a finger's target.
    final remove = find.descendant(of: player, matching: find.byTooltip(Localizer.get('TipRemoveFromQueue')));
    expect(remove, findsNWidgets(3));
    expect(tester.getSize(remove.first), const Size(44, 44));
  });

  testWidgets("an album's header puts it into a playlist beside the download; its menu then leaves that out", (
    tester,
  ) async {
    for (final size in const [Size(400, 860), Size(1400, 900)]) {
      final vm = await pumpApp(tester, size);
      vm.openAlbum(vm.library.albums.first);
      await settle(tester);
      final add = find.descendant(
        of: find.byType(DetailHeader),
        matching: find.byTooltip(Localizer.get('TipAddToPlaylist')),
      );
      expect(add, findsOneWidget, reason: '$size');
      // The page's ⋮: the phone's top bar's (over the rows', the last), else the header's.
      final more = find.byTooltip(Localizer.get('TipMore'));
      await tester.tap(size.width < 720 ? more.last : find.descendant(of: find.byType(DetailHeader), matching: more));
      await settle(tester);
      expect(find.text(Localizer.get('AddToQueue')), findsOneWidget, reason: '$size');
      expect(find.text(Localizer.get('TipAddToPlaylist')), findsNothing, reason: '$size');
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      await tester.tap(add);
      await settle(tester);
      expect(find.text(Localizer.get('PlaylistNew')), findsOneWidget, reason: '$size: the playlist dialog');
      await tester.tap(find.text(Localizer.get('Cancel')));
      await settle(tester);
    }
  });

  testWidgets(
    "a swipe over the mini player's track skips it, the next coming in from the right, the one before from the left",
    (tester) async {
      final vm = await pumpApp(tester, const Size(400, 860));
      final player = vm.player;
      player.playQueue(vm.library.tracks);
      await settle(tester);
      final queue = player.queueTracks;
      Finder inPill(Track track) => find.descendant(of: find.byType(PlayerSheetDrag), matching: find.text(track.title));
      double left(Track track) => tester.getTopLeft(inPill(track)).dx;

      // Dragged left, the next track comes in after it; let go short and slowly, they go back.
      final finger = await tester.startGesture(tester.getCenter(inPill(queue[0])));
      await finger.moveBy(const Offset(-20, 0));
      await finger.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(inPill(queue[1]), findsOneWidget, reason: 'the next beside it');
      expect(left(queue[1]), greaterThan(left(queue[0])));
      await finger.up();
      await settle(tester);
      expect(player.currentTrack, queue[0]);
      expect(inPill(queue[1]), findsNothing);

      await tester.fling(inPill(queue[0]), const Offset(-200, 0), 1000);
      await settle(tester);
      expect(player.currentTrack, queue[1]);
      await tester.fling(inPill(queue[1]), const Offset(200, 0), 1000);
      await settle(tester);
      expect(player.currentTrack, queue[0], reason: 'right: the one before');
      // At the start of a queue that doesn't go round there is none before: it stays.
      await tester.fling(inPill(queue[0]), const Offset(200, 0), 1000);
      await settle(tester);
      expect(player.currentTrack, queue[0]);

      // Changed elsewhere (Next in the full-screen player, a headset), the new one comes in from the right too.
      player.nextTrack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(left(queue[1]), greaterThan(left(queue[0])), reason: 'the next coming in from the right');
      await settle(tester);
      expect(inPill(queue[0]), findsNothing);
    },
  );

  testWidgets("a detail page's name goes up with the page, step for step, however unevenly it is scrolled", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    final album = vm.library.albums.first;
    vm.openAlbum(album);
    await settle(tester);
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final barTitle = find.descendant(of: find.byType(OverflowBox), matching: find.text(album.title));
    final finger = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView)));
    // Up to just short of where the bar takes the name over (as it reaches the shade).
    while (barTitle.evaluate().isEmpty && position.pixels < 400) {
      await finger.moveBy(const Offset(0, -10));
      await tester.pump();
    }
    await finger.moveBy(const Offset(0, 20));
    await tester.pump();
    double? inPage, left;
    var checked = 0;
    for (final step in <double>[1, 3, 0.5, 4, 1, 2, 6, 1, 3, 0.5, 5, 2, 1, 4, 3, 1, 2, 7, 1, 3, 2, 5, 1, 2]) {
      await finger.moveBy(Offset(0, -step));
      await tester.pump();
      if (barTitle.evaluate().isEmpty) continue;
      final rect = tester.getRect(barTitle);
      left ??= rect.left;
      if (rect.left != left) break; // shrinking into the bar from here on
      inPage ??= rect.center.dy + position.pixels;
      expect(rect.center.dy + position.pixels, moreOrLessEquals(inPage, epsilon: 0.01), reason: 'step $step');
      checked++;
    }
    await finger.up();
    await settle(tester);
    expect(checked, greaterThan(3), reason: 'the bar took the name over before it shrank');
  });

  testWidgets('a tab page pulled down past its top opens the search; a detail page stretches its artwork', (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final list = find.byType(CustomScrollView);
    final finger = await tester.startGesture(tester.getCenter(list));
    for (var i = 0; i < 10; i++) {
      await finger.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    expect(vm.isSearchOpen, isFalse, reason: 'not while held');
    await finger.up();
    await settle(tester);
    expect(vm.isSearchOpen, isTrue);
    vm.closeSearch();
    await settle(tester);

    // A short pull only gives.
    await tester.drag(list, const Offset(0, 60));
    await settle(tester);
    expect(vm.isSearchOpen, isFalse);

    vm.openAlbum(vm.library.albums.first);
    await settle(tester);
    final stretch = find.byType(PhoneArtworkStretch);
    final before = tester.getRect(stretch).height;
    final pull = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView)));
    for (var i = 0; i < 5; i++) {
      await pull.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    expect(tester.getRect(find.descendant(of: stretch, matching: find.byType(CoverImage))).height, greaterThan(before));
    for (var i = 0; i < 20; i++) {
      await pull.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    expect(
      tester.getRect(find.descendant(of: stretch, matching: find.byType(CoverImage))).height,
      lessThanOrEqualTo(before * 1.3),
      reason: 'it grows so far and no further',
    );
    await pull.up();
    await tester.pump(const Duration(milliseconds: 50));
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, lessThan(position.minScrollExtent), reason: 'still springing back');
    await settle(tester);
    await settle(tester);
    expect(vm.isSearchOpen, isFalse, reason: 'a detail page has no search to pull');
    expect(position.pixels, position.minScrollExtent, reason: 'back in place');
    expect(tester.getRect(find.descendant(of: stretch, matching: find.byType(CoverImage))).height, before);

    // Pulled again and let go, the page still answers while it springs back.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 200));
    await tester.pump(const Duration(milliseconds: 30));
    final track = vm.library.albums.first.tracks.first;
    await tester.tap(find.text(track.title).last);
    await settle(tester);
    expect(vm.player.currentTrack, track, reason: 'a row answers');
    await tester.tap(find.byTooltip(Localizer.get('Back')));
    await settle(tester);
    expect(vm.albums.selectedAlbum, isNull, reason: 'the page lets go');
  });

  testWidgets("a long press on an album's row floats its preview with the whole menu over the page", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final album = vm.library.albums.first;
    await tester.longPress(find.text(album.title).first);
    await settle(tester);
    for (final key in ['Play', 'Shuffle', 'PlayNext', 'AddToQueue', 'TipAddToPlaylist', 'GoToArtist']) {
      expect(find.text(Localizer.get(key)), findsOneWidget, reason: key);
    }
    await tester.tap(find.text(Localizer.get('PlayNext')));
    await settle(tester);
    expect(find.text(Localizer.get('Shuffle')), findsNothing, reason: 'closed by the choice');
    expect(vm.player.queueTracks.map((t) => t.album), contains(album.title));
  });

  testWidgets("a tap in a preview's gaps closes it; one on its cover opens the album", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final album = vm.library.albums.first;
    Finder cover() => find.byWidgetPredicate((w) => w is CoverImage && w.decodeWidth == 640);

    await tester.longPress(find.text(album.title).first);
    await settle(tester);
    await tester.tapAt(tester.getRect(cover()).bottomCenter + const Offset(0, 8));
    await settle(tester);
    expect(find.text(Localizer.get('Shuffle')), findsNothing, reason: 'closed');
    expect(vm.albums.selectedAlbum, isNull);

    await tester.longPress(find.text(album.title).first);
    await settle(tester);
    await tester.tap(cover());
    await settle(tester);
    expect(find.text(Localizer.get('PlayNext')), findsNothing, reason: 'closed');
    expect(vm.albums.selectedAlbum, album);
  });

  testWidgets("a long press's finger slid onto a preview's entry and let go there chooses it", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final album = vm.library.albums.first;
    final finger = await tester.startGesture(tester.getCenter(find.text(album.title).first));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await settle(tester);
    final entry = find.text(Localizer.get('AddToQueue'));
    expect(entry, findsOneWidget, reason: 'the preview is open under the finger');
    await finger.moveTo(tester.getCenter(entry) + const Offset(0, -30));
    await tester.pump();
    await finger.moveTo(tester.getCenter(entry));
    await tester.pump();
    await finger.up();
    await settle(tester);
    expect(entry, findsNothing, reason: 'closed by the choice');
    expect(vm.player.queueTracks.map((t) => t.album), contains(album.title));
  });

  testWidgets("a computer's detail page keeps its way back over the list, and shrinks its name in beside it", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var i = 1; i <= 40; i++) TestSupport.makeTrack('$i', 'Song $i', album: 'Long Album', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    vm.openAlbum(vm.library.albums.single);
    await settle(tester);
    final back = find.byIcon(Icons.arrow_back_rounded);
    final list = find.byType(CustomScrollView);
    expect(
      find.descendant(of: list, matching: back),
      findsNothing,
      reason: 'over the list, not in it',
    );
    // The artwork's glow reaches up past it: the list is there to draw it, under the row, not cut at the row's edge.
    final artwork = find.descendant(of: find.byType(DetailHeader), matching: find.byType(CoverImage));
    expect(tester.getTopLeft(artwork).dy - tester.getTopLeft(list).dy, greaterThanOrEqualTo(PinnedTitleBar.height));
    expect(
      tester.widget<Tooltip>(find.ancestor(of: back, matching: find.byType(Tooltip)).first).message,
      Localizer.get('NavAlbums'),
      reason: 'where it leads',
    );
    // At first only the header's; scrolled, the row's, shrunk beside the way back and level with it.
    final name = find.text('Long Album');
    expect(name, findsOneWidget);
    final big = tester.getRect(name).height;
    final arrowAt = tester.getRect(back);
    await tester.drag(list, const Offset(0, -500));
    await settle(tester);
    expect(tester.getRect(back), arrowAt, reason: 'the way back stays');
    final small = tester.getRect(name.last);
    expect(small.height, lessThan(big * 0.6));
    expect(small.left, closeTo(arrowAt.right + 18, 4), reason: 'beside its button (the icon sits 10 in from its edge)');
    expect(small.center.dy, closeTo(arrowAt.center.dy, 2));
    await tester.tap(back);
    await settle(tester);
    expect(vm.albums.isAlbumDetailOpen, isFalse);
  });

  testWidgets("a detail page's column headers stay at the top of its list while the rows scroll on", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var i = 1; i <= 40; i++) TestSupport.makeTrack('$i', 'Song $i', album: 'Long Album', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    vm.openAlbum(vm.library.albums.single);
    await settle(tester);
    final list = find.byType(CustomScrollView);
    final column = find.text(Localizer.get('ColTitle'));
    final at = tester.getTopLeft(column).dy;
    await tester.drag(list, const Offset(0, -900));
    await settle(tester);
    // The list reaches under the row of the way back; they stop under it.
    final top = tester.getTopLeft(list).dy + PinnedTitleBar.height;
    expect(tester.getTopLeft(column).dy, lessThan(at), reason: 'up with the page at first');
    expect(tester.getTopLeft(column).dy, closeTo(top + 12, 12), reason: 'then under the row');
    await tester.drag(list, const Offset(0, -300));
    await settle(tester);
    expect(tester.getTopLeft(column).dy, closeTo(top + 12, 12), reason: 'and there it stays');
    await tester.tap(column);
    await settle(tester);
    expect(tester.getTopLeft(column).dy, closeTo(top + 12, 12));
    expect(
      find.descendant(of: find.byType(TrackSliver), matching: find.byType(SortArrow)),
      findsOneWidget,
      reason: 'they still sort',
    );
  });

  testWidgets("a row brought into view from below the page's top stops under the pinned column headers", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var i = 1; i <= 40; i++) TestSupport.makeTrack('$i', 'Song $i', album: 'Long Album', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    vm.openAlbum(vm.library.albums.single);
    await settle(tester);
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, -2000));
    await settle(tester);
    // A row the headers cover, brought into view as the keyboard's or a remote's focus moving up does.
    final headers = find.text(Localizer.get('ColTitle'));
    final under = tester.getBottomLeft(headers).dy;
    final row = [
      for (var i = 1; i <= 40; i++) find.text('Song $i'),
    ].firstWhere((row) => row.evaluate().isNotEmpty && tester.getCenter(row).dy < under);
    await tester.runAsync(
      () => Scrollable.ensureVisible(
        tester.element(row),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ),
    );
    await settle(tester);
    expect(
      tester.getTopLeft(row).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(headers).dy - 1),
      reason: 'not hidden under the headers',
    );
  });

  testWidgets("a computer's section chosen again in the sidebar brings its page back to the top", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var i = 1; i <= 60; i++) TestSupport.makeTrack('$i', 'Song $i', album: 'Album ${i % 6}', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    for (final (section, name) in [(AppSection.tracks, 'NavTracks'), (AppSection.settings, 'NavSettings')]) {
      vm.navigateTo(section);
      await settle(tester);
      final page = find.byType(section == AppSection.tracks ? CustomScrollView : ListView).last;
      double scrolled() => tester
          .state<ScrollableState>(find.descendant(of: page, matching: find.byType(Scrollable)).first)
          .position
          .pixels;
      await tester.drag(page, const Offset(0, -600));
      await settle(tester);
      expect(scrolled(), greaterThan(0), reason: '$section scrolled');
      // The sidebar's, before the page's.
      await tester.tap(find.text(Localizer.get(name)).first);
      await settle(tester);
      expect(scrolled(), 0, reason: '$section back at its top');
    }
  });

  testWidgets("the rows and tiles follow what plays, not the rest of the player (its volume)", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    final built = <String, int>{};
    vm.player.playQueue(vm.library.tracks);
    await tester.runAsync(vm.player.pause);
    for (final (section, item) in [(AppSection.tracks, '_TableRow'), (AppSection.albums, 'CoverFlightSource')]) {
      vm.navigateTo(section);
      await settle(tester);
      debugOnRebuildDirtyWidget = (element, _) =>
          built.update(element.widget.runtimeType.toString(), (n) => n + 1, ifAbsent: () => 1);
      built.clear();
      vm.player.setVolume(vm.player.volume - 5);
      await tester.pump();
      debugOnRebuildDirtyWidget = null;
      expect(built[item] ?? 0, 0, reason: '$section: a volume change');
    }
  });

  testWidgets("a scrolled table or grid builds only the rows and tiles that come into view", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var a = 1; a <= 40; a++)
          for (var t = 1; t <= 3; t++) TestSupport.makeTrack('$a-$t', 'Song $a.$t', album: 'Album $a', trackNumber: t),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    final built = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) =>
        built.update(element.widget.runtimeType.toString(), (n) => n + 1, ifAbsent: () => 1);
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    // A table's rows come in one by one; a grid's six tiles at once (before the fix: 96 rows and 195 tiles).
    for (final (section, item, per, most) in [
      (AppSection.tracks, '_TableRow', 52.0, 20),
      (AppSection.albums, 'CoverFlightSource', 250.0, 40),
    ]) {
      vm.navigateTo(section);
      await settle(tester);
      built.clear();
      // Ten small steps, a row's or a tile row's worth in all.
      final finger = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView).first));
      for (var i = 0; i < 10; i++) {
        await finger.moveBy(Offset(0, -per / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await finger.up();
      expect(built[item] ?? 0, lessThan(most), reason: '$section: not every one at every step');
    }
  });

  testWidgets("an artist opened again starts at the top; one come back to from its album keeps its place", (
    tester,
  ) async {
    for (final size in const [Size(1400, 900), Size(400, 860)]) {
      final vm = await pumpApp(tester, size, () async {
        final library = createLibrary([
          for (var a = 1; a <= 6; a++)
            for (var t = 1; t <= 8; t++)
              TestSupport.makeTrack('$a-$t', 'Song $a.$t', artist: 'Miles Davis', album: 'Album $a', trackNumber: t),
        ]);
        library.initialize();
        return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
      });
      double scrolled() => tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first,
          )
          .position
          .pixels;
      final artist = vm.library.artists.single;
      vm.navigateTo(AppSection.artists);
      await settle(tester);
      vm.openArtist(artist);
      await settle(tester);
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -400));
      await settle(tester);
      final place = scrolled();
      expect(place, greaterThan(0));

      // To one of its albums and Back: where it was.
      vm.openAlbum(vm.library.albums.first);
      await settle(tester);
      vm.albums.closeAlbumDetail();
      await settle(tester);
      expect(vm.artists.isArtistDetailOpen, isTrue);
      expect(scrolled(), closeTo(place, 1), reason: '$size: come back to');

      // Closed, and opened again: at its top.
      vm.artists.closeArtistDetail();
      await settle(tester);
      vm.openArtist(artist);
      await settle(tester);
      expect(scrolled(), 0, reason: '$size: opened anew');
    }
  });

  testWidgets("a computer's window with nothing playing comes to rest: nothing animates on its own", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.player.playQueue(vm.library.tracks);
    await settle(tester);
    await tester.runAsync(vm.player.pause);
    // Fails with a timeout while anything still asks for frames.
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets("a cover flying across the screen is blurred along its way, and sharp as it slows to land", (
    tester,
  ) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var a = 1; a <= 40; a++) TestSupport.makeTrack('$a', 'Song $a', album: 'Album $a'),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final blur = find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_MotionBlur');
    int copies() {
      var layers = 0;
      expect(
        blur,
        paints..everything((method, arguments) {
          if (method == #saveLayer) layers++;
          return true;
        }),
      );
      return layers == 0 ? 1 : layers - 1; // the copies' own layers, in the one that holds them
    }

    // The tile furthest from the page's artwork, at the top left.
    final tiles = find.byType(CoverFlightSource).evaluate().toList()
      ..sort(
        (a, b) => (b.renderObject as RenderBox)
            .localToGlobal(Offset.zero)
            .distance
            .compareTo((a.renderObject as RenderBox).localToGlobal(Offset.zero).distance),
      );
    await tester.tap(find.byElementPredicate((element) => element == tiles.first));
    // Frame by frame at 60 fps, from its first (the frame after the page's), while it flies.
    final frames = <int>[];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 17));
    while (blur.evaluate().isNotEmpty && frames.length < 60) {
      frames.add(copies());
      await tester.pump(const Duration(milliseconds: 17));
    }
    expect(frames.reduce(math.max), greaterThan(4), reason: 'at full speed: copies along the way ($frames)');
    expect(frames.first, 1, reason: 'setting off: one sharp cover');
    expect(frames.last, 1, reason: 'all but landed: one sharp cover');
    await settle(tester);
    expect(blur, findsNothing);
  });

  testWidgets("a page opened by a link sends its artwork back to its tile when it closes", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.artists);
    await settle(tester);
    // As from an album's artist link: no cover was pressed, so none flew in.
    vm.openArtist(vm.library.artists.first);
    await settle(tester);
    vm.artists.closeArtistDetail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final listed = find.byType(CoverImage).evaluate().length;
    await settle(tester);
    expect(listed, find.byType(CoverImage).evaluate().length + 1, reason: 'one in flight over the list');
  });

  testWidgets("queued music's cover arcs into the mini player's, which bumps as it lands", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.player.playQueue(vm.library.tracks.take(1).toList());
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final landing = find.byType(CoverFlightLanding);
    double scale() => tester
        .widget<Transform>(find.descendant(of: landing, matching: find.byType(Transform)).first)
        .transform
        .getMaxScaleOnAxis();
    final row = find.ancestor(of: find.text(vm.library.albums.last.title), matching: find.byType(InkWell)).first;
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    final covers = find.byType(CoverImage).evaluate().length;
    await tester.tap(find.text(Localizer.get('PlayNext')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CoverImage).evaluate().length, greaterThan(covers), reason: 'one in flight');
    expect(scale(), 1, reason: 'not landed yet');
    // It lands after its 560 ms (from its first frame), and bumps for 360 from the frame after.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 150));
    expect(scale(), greaterThan(1.05), reason: 'the bump');
    await settle(tester);
    expect(scale(), 1);
  });

  testWidgets("the tab bar's glow stands behind the active tab's icon, and goes over to the next", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    final nav = find.ancestor(of: find.byIcon(Icons.album).last, matching: find.byType(Stack)).first;
    final glow = find.descendant(
      of: nav,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient is RadialGradient,
      ),
    );
    for (final (section, icon) in [
      (AppSection.albums, Icons.album),
      (AppSection.playlists, Icons.queue_music_rounded),
    ]) {
      vm.navigateTo(section);
      await settle(tester);
      final centre = tester.getCenter(find.byIcon(icon).last);
      expect(tester.getCenter(glow).dx, moreOrLessEquals(centre.dx, epsilon: 0.5), reason: section.name);
      expect(tester.getCenter(glow).dy, moreOrLessEquals(centre.dy, epsilon: 1.5), reason: section.name);
    }
  });

  testWidgets('a tab further right slides its page in from the right, one further left from the left', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.artists);
    await settle(tester);
    vm.navigateTo(AppSection.tracks);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getTopLeft(find.byType(TracksPage)).dx, greaterThan(0));
    await settle(tester);
    expect(tester.getTopLeft(find.byType(TracksPage)).dx, 0);
    vm.navigateTo(AppSection.albums);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getTopLeft(find.byType(AlbumsPage)).dx, lessThan(0));
    await settle(tester);
  });

  testWidgets('the search field grows out of the button that opened it, and keeps its focus once open', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    final button = tester.getRect(find.byTooltip(Localizer.get('Search')));
    await tester.tap(find.byTooltip(Localizer.get('Search')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final clip = tester.widget<ClipPath>(
      find.ancestor(of: find.byType(TextField), matching: find.byType(ClipPath)).first,
    );
    final shown = clip.clipper!.getClip(const Size(400, 120)).getBounds();
    expect(shown.width, lessThan(300), reason: 'still growing');
    expect(shown.right, moreOrLessEquals(button.right, epsilon: 60), reason: 'out of the button');
    await tester.enterText(find.byType(TextField), 'So');
    await settle(tester);
    expect(vm.searchQuery, 'So');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'So', reason: 'kept through the end');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(), isNotNull);
    vm.closeSearch();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(TextField), findsOneWidget, reason: 'going back into the button');
    await settle(tester);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets("the seek bar's time floats over the knob while it is held", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.player.playQueue(vm.library.tracks.take(1).toList());
    vm.openNowPlaying();
    await settle(tester);
    final bar = find.byType(SeekBar);
    double bubble() =>
        tester.widget<AnimatedOpacity>(find.descendant(of: bar, matching: find.byType(AnimatedOpacity))).opacity;
    expect(bubble(), 0);
    final slider = find.descendant(of: bar, matching: find.byType(Slider));
    final finger = await tester.startGesture(tester.getCenter(slider));
    await finger.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(bubble(), 1);
    await finger.up();
    await settle(tester);
    expect(bubble(), 0);
  });

  testWidgets("a computer's tab page keeps its header and the column headers while the list scrolls", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary([
        for (var i = 1; i <= 60; i++) TestSupport.makeTrack('$i', 'Song $i', album: 'Album ${i % 6}', trackNumber: i),
      ]);
      library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
    });
    vm.navigateTo(AppSection.tracks);
    await settle(tester);
    // The sidebar's, then the header's.
    final name = find.text(Localizer.get('NavTracks')).last;
    final column = find.text(Localizer.get('ColTitle'));
    final row = find.text('Song 1');
    final nameAt = tester.getTopLeft(name);
    final columnAt = tester.getTopLeft(column);
    final rowAt = tester.getTopLeft(row);
    final list = find.byType(CustomScrollView);
    expect(tester.getTopLeft(list).dy, greaterThan(columnAt.dy), reason: 'the list starts under them');
    await tester.drag(list, const Offset(0, -40));
    await settle(tester);
    expect(tester.getTopLeft(name), nameAt);
    expect(tester.getTopLeft(column), columnAt);
    expect(tester.getTopLeft(row).dy, lessThan(rowAt.dy), reason: 'the rows move');
    await tester.tap(column);
    await settle(tester);
    expect(vm.tracks.sortField, TrackSortField.title, reason: 'they still sort');
    expect(vm.tracks.isSortDescending, isTrue);
  });

  testWidgets("two fingers spread over a wide screen's tiles make them larger, fewer to a row", (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    final start = vm.tileSize.value;
    final center = tester.getCenter(find.byType(CustomScrollView));
    final a = await tester.createGesture(kind: PointerDeviceKind.touch);
    final b = await tester.createGesture(kind: PointerDeviceKind.touch);
    await a.down(center - const Offset(40, 0));
    await b.down(center + const Offset(40, 0));
    await a.moveTo(center - const Offset(80, 0));
    await b.moveTo(center + const Offset(80, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await settle(tester);
    expect(vm.tileSize.value, greaterThan(start));
    expect(vm.tileSize.value, lessThanOrEqualTo(MainViewModel.tileSizeMax));
  });

  testWidgets("a menu opened from the search results leaves the keyboard down when it closes", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    await tester.tap(find.byIcon(Icons.search_rounded));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'kind');
    await settle(tester);
    bool typing() => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
    expect(typing(), isTrue);
    final card = find.ancestor(of: find.text(Localizer.get('BestMatch').toUpperCase()), matching: find.byType(Column));
    for (final close in ['outside', 'entry']) {
      await tester.tap(find.descendant(of: card.first, matching: find.byIcon(Icons.more_vert_rounded)));
      await settle(tester);
      if (close == 'outside') {
        await tester.tapAt(const Offset(200, 20));
      } else {
        await tester.tap(find.text(Localizer.get('AddToQueue')));
      }
      await settle(tester);
      expect(typing(), isFalse, reason: close);
      expect(vm.isSearchOpen, isTrue);
    }
  });

  testWidgets("the best match has its ⋮, the menu its row or tile has", (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.openSearch();
    for (final (query, entry) in [('kind', 'GoToArtist'), ('miles', 'HideArtist'), ('so what', 'GoToAlbum')]) {
      vm.searchQuery = query;
      await settle(tester);
      final card = find.ancestor(
        of: find.text(Localizer.get('BestMatch').toUpperCase()),
        matching: find.byType(Column),
      );
      final menu = find.descendant(of: card.first, matching: find.byIcon(Icons.more_vert_rounded));
      expect(menu, findsOneWidget, reason: query);
      await tester.tap(menu);
      await settle(tester);
      expect(find.text(Localizer.get(entry)), findsOneWidget, reason: query);
      await tester.tapAt(const Offset(200, 20));
      await settle(tester);
    }
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

  testWidgets('the page opened while signed in, without the address field, closes cleanly', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900), () async {
      final library = createLibrary();
      return createMainViewModel(library, null, await signedInSession(library));
    });
    vm.showLoginScreen();
    await settle(tester);
    expect(find.text(Localizer.get('Connect')), findsNothing);
    vm.isLoginViewActive = false;
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
