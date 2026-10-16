// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The navigation state behind the layouts: which layers back closes and in what order, how the search page and the
/// full-screen player open and close, and how their tabs follow the player.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  Future<MainViewModel> create() async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'So What', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 1),
      TestSupport.makeTrack('2', 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue', trackNumber: 2),
      TestSupport.makeTrack('3', 'Opening', artist: 'Daft Punk', album: 'Random Access Memories', trackNumber: 1),
    ]);
    library.initialize();
    return createMainViewModel(library);
  }

  void showTrack(MainViewModel vm) => vm.player.currentTrack = vm.library.tracks.first;

  test('back closes the innermost layer first, and says when there is nothing left', () async {
    final vm = await create();
    vm.navigateTo(AppSection.playlists);
    showTrack(vm);
    vm.openNowPlaying();

    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.isNowPlayingOpen, isFalse);

    vm.openSearch();
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.isSearchOpen, isFalse);

    // No layer is left: back walks the tabs the user came from, newest first...
    vm.navigateTo(AppSection.tracks);
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.selectedSection, AppSection.playlists);
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.selectedSection, AppSection.artists);

    // ...and when that history is used up the app may leave.
    expect(vm.tryNavigateBack(), isFalse);
    expect(vm.selectedSection, AppSection.artists);
  });

  test('back leaves a detail page, then the tab', () async {
    final vm = await create();
    vm.navigateTo(AppSection.albums);
    vm.openAlbum(vm.library.albums.first);
    expect(vm.albums.isAlbumDetailOpen, isTrue);
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.albums.isAlbumDetailOpen, isFalse);
    expect(vm.selectedSection, AppSection.albums); // closing the page stays on the tab

    vm.navigateTo(AppSection.favorites);
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.selectedSection, AppSection.albums);
  });

  test('back from the settings returns to the tab the user came from', () async {
    final vm = await create();
    vm.navigateTo(AppSection.favorites);
    vm.navigateTo(AppSection.settings);
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.selectedSection, AppSection.favorites);
  });

  test('back closes the queue panel of the wide layout', () async {
    final vm = await create();
    showTrack(vm);
    vm.player.isQueueOpen = true;
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.player.isQueueOpen, isFalse);
  });

  test('typing keeps the search open, and closing it clears the query', () async {
    final vm = await create();
    vm.openSearch();
    expect(vm.isSearchOpen, isTrue);
    expect(vm.isSearchActive, isFalse); // open, but nothing typed yet

    vm.searchQuery = 'blue';
    expect(vm.isSearchActive, isTrue);
    expect(vm.isSearchOpen, isTrue);
    expect(vm.search.matchingTracks.map((t) => t.title), ['So What', 'Blue in Green']); // the album is "Kind of Blue"

    vm.closeSearch();
    expect(vm.isSearchOpen, isFalse);
    expect(vm.searchQuery, '');
  });

  test('opening a result shows it, and back returns to the results', () async {
    final vm = await create();
    vm.openSearch();
    vm.searchQuery = 'kind';

    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    expect(vm.albums.isAlbumDetailOpen, isTrue);
    expect(vm.isSearchOpen, isFalse); // the album replaces the search page...
    expect(vm.searchQuery, 'kind'); // ...but the query is kept
    expect(vm.albums.backText, 'Search');

    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.albums.isAlbumDetailOpen, isFalse);
    expect(vm.isSearchOpen, isTrue);
    expect(vm.searchQuery, 'kind');
  });

  test('an album opened from an artist leads back to that artist', () async {
    final vm = await create();
    final artist = vm.library.artists.firstWhere((a) => a.name == 'Miles Davis');
    vm.openArtist(artist);
    expect(vm.selectedSection, AppSection.artists);
    expect(vm.artists.selectedArtist?.tracks, hasLength(2));

    vm.openAlbum(artist.albums.first);
    expect(vm.selectedSection, AppSection.albums);
    expect(vm.albums.backText, 'Miles Davis');

    vm.albums.closeAlbumDetail();
    expect(vm.selectedSection, AppSection.artists);
    expect(vm.artists.isArtistDetailOpen, isTrue);
    expect(vm.artists.selectedArtist?.name, 'Miles Davis');
  });

  test('navigating closes the search page', () async {
    final vm = await create();
    vm.openSearch();
    vm.searchQuery = 'opening';
    vm.navigateTo(AppSection.artists);
    expect(vm.isSearchOpen, isFalse);
    expect(vm.searchQuery, '');
  });

  test('the full-screen player needs a track, and closes when nothing is loaded any more', () async {
    final vm = await create();
    vm.openNowPlaying();
    expect(vm.isNowPlayingOpen, isFalse); // nothing is playing

    showTrack(vm);
    vm.openNowPlaying();
    expect(vm.isNowPlayingOpen, isTrue);

    vm.player.currentTrack = null;
    expect(vm.isNowPlayingOpen, isFalse);
  });

  test("the full-screen player's tabs follow the player's queue flag, and reset on close", () async {
    final vm = await create();
    showTrack(vm);
    vm.openNowPlaying();
    expect(vm.nowPlayingTab, NowPlayingTab.player);
    expect(vm.player.isQueueOpen, isFalse);

    vm.nowPlayingTab = NowPlayingTab.queue;
    expect(vm.player.isQueueOpen, isTrue);
    vm.nowPlayingTab = NowPlayingTab.lyrics;
    expect(vm.player.isQueueOpen, isTrue);

    vm.closeNowPlaying();
    expect(vm.nowPlayingTab, NowPlayingTab.player);
    expect(vm.player.isQueueOpen, isFalse);
  });

  test('navigating to a section switches it and runs the wave', () async {
    final vm = await create();
    expect(vm.selectedSection, AppSection.artists);
    final wave = vm.waveTrigger;
    vm.navigateTo(AppSection.settings);
    expect(vm.selectedSection, AppSection.settings);
    expect(vm.waveTrigger, wave + 1);
    expect(vm.lastWaveDirection, NavWaveDirection.leftToRight); // downwards in the sidebar
    vm.navigateTo(AppSection.albums);
    expect(vm.lastWaveDirection, NavWaveDirection.rightToLeft);
  });

  test('the status lines name the device and the library', () async {
    final vm = await create();
    await vm.start();
    await vm.audioEngine.ready;
    expect(vm.statusText, contains('Test USB DAC'));
    expect(vm.rightFooterStatusText, contains('3 tracks'));
    expect(vm.rightFooterStatusText, isNot(contains('Wiretune')));
    expect(vm.isLoginViewActive, isFalse); // a library is there, so the app opens on it
  });

  test('an empty first start shows the sign-in screen', () async {
    final library = createLibrary();
    final vm = createMainViewModel(library);
    await vm.start();
    expect(vm.isLoginViewActive, isTrue);
    expect(vm.tryNavigateBack(), isFalse); // leaving it would be a dead end
  });

  test('preferences are applied at start and remembered', () async {
    final repo = testRepository()
      ..setSetting('preference.language', 'de')
      ..setSetting('preference.theme', 'light')
      ..setSetting('preference.online_lyrics', '0');
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final vm = MainViewModel(TestSupport.createEngine(), library, ServerSession(library, repo));
    await vm.start();
    expect(Localizer.instance.language, 'de');
    expect(vm.isLight, isTrue);
    expect(vm.useOnlineLyrics, isFalse);
    expect(vm.lyrics.isOnlineEnabled, isFalse);
    expect(vm.showPerformanceStats, isFalse);

    vm.changeLanguage('hu');
    vm.toggleTheme();
    vm.showPerformanceStats = true;
    await Future<void>.delayed(Duration.zero);
    expect(repo.getSetting('preference.language'), 'hu');
    expect(repo.getSetting('preference.theme'), 'dark');
    expect(repo.getSetting('preference.show_performance_stats'), '1');
    Localizer.instance.setLanguage('en');
  });
}
