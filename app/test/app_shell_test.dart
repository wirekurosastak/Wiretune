import 'dart:io';

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
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/ambient.dart';
import 'package:wiretune/src/widgets/common.dart';
import 'package:wiretune/src/widgets/cover_image.dart';
import 'package:wiretune/src/widgets/quality_tag.dart';
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
    await library.initialize();
    return createMainViewModel(library);
  }

  // A local album beside a server's, as a player signed in to a server has them: only the server's can be downloaded.
  Future<MainViewModel> createWithServer() async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
      TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps'),
      TestSupport.makeServerTrack('s2', 'Naima', artist: 'John Coltrane', album: 'Giant Steps')..trackNumber = 2,
    ]);
    await library.initialize();
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

  testWidgets('a skip in the full-screen player shows the next track\'s title and cover', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    final tracks = vm.library.tracks.take(2).toList();
    for (final track in tracks) {
      track.coverArtPath = '/covers/${track.id}.jpg';
    }
    final page = find.byType(NowPlayingPage);
    Finder onPage(Finder finder) => find.descendant(of: page, matching: finder);
    String? coverOnPage() => tester
        .widget<CoverImage>(onPage(find.descendant(of: find.byType(Hero), matching: find.byType(CoverImage))))
        .path;

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
      await library.initialize();
      return createMainViewModel(library, TestSupport.createEngine(driver));
    }))!;
    const line = "(La, la, la) I'm caught up in the rapture of love, nothing else can compare";
    vm.player.lyricsProvider = (_) async => '[00:00.50]$line\n[00:30.00]When I feel the magic of you';
    await tester.pumpWidget(WiretuneApp(vm: vm));

    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    vm.nowPlayingTab = 2;
    await tester.runAsync(() async {
      await waitUntil(() => vm.player.hasSyncedLyrics);
      await driver.seek(const Duration(seconds: 1));
    });
    await settle(tester);

    expect(vm.player.currentLyricIndex.value, 0);
    final list = tester.getRect(find.descendant(of: find.byType(NowPlayingPage), matching: find.byType(ListView)));
    final sung = tester.getRect(find.text(line));
    expect(sung.left, greaterThanOrEqualTo(list.left));
    expect(sung.right, lessThanOrEqualTo(list.right));
  });

  testWidgets('in the favourites the heart comes before "add to playlist", as in every other list', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    await tester.runAsync(() => vm.library.toggleFavorite(vm.library.tracks.first.id));
    vm.navigateTo(AppSection.favorites);
    await settle(tester);

    Finder inList(IconData icon) => find.descendant(of: find.byType(TrackSliver), matching: find.byIcon(icon));
    expect(
      tester.getCenter(inList(Icons.favorite_rounded)).dx,
      lessThan(tester.getCenter(inList(Icons.playlist_add_rounded)).dx),
    );
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
    // The resolution leads the album's second line (the test tracks are FLAC 16bit/44.1kHz).
    final tag = tester.getRect(find.text('16bit/44.1kHz').first);
    final artist = tester.getRect(find.text('Miles Davis').first);
    expect((tag.center.dy - artist.center.dy).abs(), lessThan(2));
    expect(tag.right, lessThan(artist.left));
    await tester.tap(find.text('Kind of Blue'));
    await settle(tester);
    expect(vm.albums.selectedAlbum?.title, 'Kind of Blue');

    vm.navigateTo(AppSection.artists);
    await settle(tester);
    expectRows('Daft Punk', 'Miles Davis');
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
      final created = await vm.library.createPlaylist('Mix');
      await vm.library.addTrackToPlaylist(created.id, vm.library.tracks.first.id);
      return vm.library.getPlaylist(created.id);
    }))!;
    vm.navigateTo(AppSection.playlists);
    vm.playlists.openPlaylist(playlist);
    await settle(tester);
    expectOnCover(header, find.descendant(of: header, matching: find.byType(CoverImage)));
  });

  testWidgets('a phone shows the resolution on its album rows, and a queue without quality tags', (tester) async {
    final vm = await pumpApp(tester, const Size(400, 860));
    vm.navigateTo(AppSection.albums);
    await settle(tester);
    expect(find.text('16bit/44.1kHz'), findsWidgets); // the test tracks are FLAC 16bit/44.1kHz

    vm.player.playQueue(vm.library.tracks);
    vm.openNowPlaying();
    vm.nowPlayingTab = 1;
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
      await tester.runAsync(() => vm.library.setFavorite('s1', true)); // not signed in: as the server told it
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
        for (final tab in [0, 1, 2]) {
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
        await library.initialize();
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
      for (final page in ['library', 'full-screen player']) {
        if (page != 'library') {
          vm.openNowPlaying();
          await loadCovers(tester, washOf(find.byType(NowPlayingPage)));
        }
        expect(tester.binding.hasScheduledFrame, isFalse, reason: '$page, before'); // everything has come to rest
        final second = vm.player.position.value.inSeconds + 1;
        driver.positionChanged.emit(Duration(seconds: second, milliseconds: 100)); // a new second: drawn
        expect(tester.binding.hasScheduledFrame, isTrue, reason: page);
        await tester.pump();
        for (final ms in [250, 400, 550, 700, 850]) {
          driver.positionChanged.emit(Duration(seconds: second, milliseconds: ms)); // the rest of it: not
          expect(tester.binding.hasScheduledFrame, isFalse, reason: '$page, $ms ms');
        }
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
    expect(downloads.isAlbumPinned(album), isTrue);
    // On its way: the arrow in progress inside a ring that fills as the tracks arrive (none yet, out of two).
    expect(find.descendant(of: header, matching: find.byIcon(Icons.downloading_rounded)), findsOneWidget);
    final ring = tester.widget<CircularProgressIndicator>(
      find.descendant(of: header, matching: find.byType(CircularProgressIndicator)),
    );
    expect(ring.value, 0);
    // The album keeps its tracks: their own buttons cannot let them go.
    final keptByAlbum = inRows('Downloaded with an album, a playlist or the favourites');
    expect(keptByAlbum, findsNWidgets(2));
    await tester.tap(keptByAlbum.first, warnIfMissed: false);
    await settle(tester);
    expect(album.tracks.map(downloads.isTrackPinned), [false, false]);
    expect(album.tracks.map(downloads.stateOf), everyElement(DownloadState.queued));
    await tester.tap(inHeader('0 of 2 downloaded – click to remove'));
    await settle(tester);
    expect(downloads.isAlbumPinned(album), isFalse);

    // One track, from its row.
    await tester.tap(inRows('Download to this device').first);
    await settle(tester);
    expect(downloads.isTrackPinned(vm.library.getTrack('s1')!), isTrue);
    expect(inRows('Remove the download'), findsOneWidget);

    // The favourites, from their page.
    await tester.runAsync(() => vm.library.setFavorite('s2', true)); // not signed in: as the server told it
    vm.navigateTo(AppSection.favorites);
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(PlayShuffleButtons), matching: find.byTooltip('Download to this device')),
    );
    await settle(tester);
    expect(downloads.areFavoritesPinned, isTrue);
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
    expect(vm.downloads.isTrackPinned(vm.library.getTrack('s1')!), isTrue);
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
    await tester.tap(find.byTooltip('Play on another device'));
    await settle(tester);
    expect(find.textContaining('No other device is online'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    await tester.runAsync(() async {
      hub.devices([('desk', 'Desk', DeviceKind.desktop)]);
      hub.state('desk', RemotePlayback(track: vm.library.tracks.first, playing: true, queue: ['1'], queueIndex: 0));
      await pumpEventQueue();
    });
    await settle(tester);
    await tester.tap(find.byTooltip('Play on another device'));
    await settle(tester);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('So What • Miles Davis'), findsOneWidget);
    await tester.tap(find.ancestor(of: find.text('Desk'), matching: find.byType(CheckedPopupMenuItem<String>)));
    await settle(tester);

    expect(vm.player.isRemote, isTrue);
    expect(find.text('Playing on Desk'), findsOneWidget); // in the mini player, in place of the artist
    expect(find.text('So What'), findsWidgets);
    await tester.tap(find.byTooltip('Pause'));
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
    expect(find.textContaining('Nothing is downloaded yet'), findsOneWidget);
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

  testWidgets('the sign-in page covers the app while it is active', (tester) async {
    final vm = await pumpApp(tester, const Size(1400, 900));
    expect(find.text(Localizer.get('Connect')), findsNothing);
    vm.showLoginScreen();
    await settle(tester);
    expect(find.text(Localizer.get('Connect')), findsWidgets);
  });
}
