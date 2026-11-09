// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/view_models/search_view_model.dart';
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

  test('back while renaming a playlist ends the renaming, and the playlist stays open', () async {
    final vm = await create();
    vm.openPlaylist(vm.library.createPlaylist('Mix'));
    vm.playlists.startRename();
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.playlists.isEditingName, isFalse);
    expect(vm.playlists.isPlaylistDetailOpen, isTrue);

    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.playlists.isPlaylistDetailOpen, isFalse);
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

  test('search finds names whether or not they are typed with their accents', () async {
    final vm = await create();
    vm.openSearch();

    vm.searchQuery = 'MÎLES';
    expect(vm.search.matchingArtists.map((a) => a.name), ['Miles Davis']);
    expect(vm.search.bestMatch?.title, 'Miles Davis');

    vm.searchQuery = 'kínd of blüe';
    expect(vm.search.matchingAlbums.map((a) => a.title), ['Kind of Blue']);
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

  test('a search that led to a result is remembered, the latest first; one is forgotten on asking', () async {
    final vm = await create();
    vm.openSearch();
    vm.searchQuery = 'kind';
    expect(vm.search.recent, isEmpty, reason: 'typed alone, nothing is kept');
    vm.openAlbum(vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue'));
    vm.closeSearch();
    vm.openSearch();
    vm.searchQuery = 'opening';
    vm.search.bestMatch!.play();
    expect(vm.search.recent, ['opening', 'kind']);

    vm.searchQuery = 'kind';
    vm.search.rememberQuery();
    expect(vm.search.recent, ['kind', 'opening'], reason: 'once each, the latest first');
    vm.search.forget('opening');
    expect(vm.search.recent, ['kind']);
  });

  test('the results narrow to one kind, with no best match, until another search', () async {
    final vm = await create();
    vm.openSearch();
    vm.searchQuery = 'blue';
    expect(vm.search.hasAlbums && vm.search.hasTracks, isTrue);
    vm.search.setFilter(SearchFilter.tracks);
    expect((vm.search.hasAlbums, vm.search.hasTracks, vm.search.bestMatch), (false, true, null));
    vm.searchQuery = 'blues';
    expect(vm.search.filter, isNull);
  });

  test('a playlist is found by its name, and back from it returns to the results', () async {
    final vm = await create();
    final mix = vm.library.createPlaylist('Blue Monday');
    vm.openSearch();
    vm.searchQuery = 'blue';
    expect(vm.search.matchingPlaylists.map((p) => p.name), ['Blue Monday']);

    vm.openPlaylist(vm.search.matchingPlaylists.single);
    expect(vm.selectedSection, AppSection.playlists);
    expect(vm.playlists.selectedPlaylist?.name, 'Blue Monday');
    expect(vm.playlists.backText, 'Search');

    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.playlists.isPlaylistDetailOpen, isFalse);
    expect(vm.isSearchOpen, isTrue);
    expect(vm.searchQuery, 'blue');

    vm.library.renamePlaylist(mix.id, 'Monday');
    expect(vm.search.matchingPlaylists, isEmpty, reason: 'the results follow a rename');
  });

  test("an album opened on a playlist's page leads back to that page, where it was left", () async {
    final vm = await create();
    vm.navigateTo(AppSection.playlists);
    vm.playlists.createPlaylist('Mix', vm.library.tracks.take(2).toList());
    final visit = vm.playlists.pageVisit;

    vm.openAlbum(vm.library.albums.first);
    expect(vm.albums.backText, 'Mix');
    vm.albums.closeAlbumDetail();
    expect(vm.selectedSection, AppSection.playlists);
    expect(vm.playlists.selectedPlaylist?.name, 'Mix');
    expect(vm.playlists.pageVisit, visit, reason: 'returned to, not opened anew');
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

  test('a tab keeps its open page while another is shown; chosen again, it goes back to its list', () async {
    final vm = await create();
    vm.navigateTo(AppSection.albums);
    vm.albums.openAlbum(vm.library.albums.first);
    vm.navigateTo(AppSection.playlists);
    vm.playlists.createPlaylist('Mix', vm.library.tracks.take(2).toList());
    expect(vm.playlists.isPlaylistDetailOpen, isTrue);

    // Another tab and back: each page is where it was left.
    vm.navigateTo(AppSection.albums);
    expect(vm.albums.isAlbumDetailOpen, isTrue);
    vm.navigateTo(AppSection.playlists);
    expect(vm.playlists.isPlaylistDetailOpen, isTrue);

    // The tab on show chosen again: back to its list, then to the list's top.
    var toTop = 0;
    final unsubscribe = vm.scrollToTopRequested.listen((_) => toTop++);
    addTearDown(unsubscribe);
    vm.navigateTo(AppSection.playlists);
    expect((vm.playlists.isPlaylistDetailOpen, toTop), (false, 0));
    vm.navigateTo(AppSection.playlists);
    expect(toTop, 1);
    vm.navigateTo(AppSection.albums);
    vm.navigateTo(AppSection.albums);
    expect(vm.albums.isAlbumDetailOpen, isFalse);
  });

  test(
    "a page opened from another tab's page stays in that tab, with its way back; its own tab keeps its own",
    () async {
      final vm = await create();
      vm.navigateTo(AppSection.tracks);
      vm.openAlbum(vm.library.albums.first);
      expect((vm.selectedTab, vm.selectedSection), (AppSection.tracks, AppSection.albums));
      expect(vm.albums.backText, Localizer.get('NavTracks'));

      // Albums shows its own list; Tracks comes back with the album open, and Back from it to the tracks.
      vm.navigateTo(AppSection.albums);
      expect(
        (vm.selectedTab, vm.selectedSection, vm.albums.isAlbumDetailOpen),
        (AppSection.albums, AppSection.albums, false),
      );
      vm.navigateTo(AppSection.tracks);
      expect((vm.selectedSection, vm.albums.isAlbumDetailOpen), (AppSection.albums, true));
      expect(vm.tryNavigateBack(), isTrue);
      expect(
        (vm.selectedTab, vm.selectedSection, vm.albums.isAlbumDetailOpen),
        (AppSection.tracks, AppSection.tracks, false),
      );
    },
  );

  test('back walks a chain of pages: a similar album, its artist, and on back to the search', () async {
    final vm = await create();
    vm.openSearch();
    vm.searchQuery = 'kind';
    final kind = vm.library.albums.firstWhere((a) => a.title == 'Kind of Blue');
    final other = vm.library.albums.firstWhere((a) => a.title != 'Kind of Blue');
    vm.openAlbum(kind);
    vm.openAlbum(other); // from its Similar albums
    expect(vm.albums.backText, 'Kind of Blue');
    vm.openArtistByName(other.artist);
    expect((vm.selectedTab, vm.selectedSection), (AppSection.artists, AppSection.artists));
    expect(vm.artists.backText, other.title);

    expect(vm.tryNavigateBack(), isTrue);
    expect((vm.selectedSection, vm.albums.selectedAlbum?.title), (AppSection.albums, other.title));
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.albums.selectedAlbum?.title, 'Kind of Blue');
    expect(vm.albums.backText, 'Search');
    expect(vm.tryNavigateBack(), isTrue);
    expect((vm.isSearchOpen, vm.searchQuery), (true, 'kind'));
    expect(vm.tryNavigateBack(), isTrue);
    expect((vm.isSearchOpen, vm.selectedSection, vm.artists.isArtistDetailOpen), (false, AppSection.artists, false));
  });

  test('an artist opened from a related artist leads back to the first; the tab chosen again drops the way', () async {
    final vm = await create();
    final miles = vm.library.artists.firstWhere((a) => a.name == 'Miles Davis');
    final daft = vm.library.artists.firstWhere((a) => a.name == 'Daft Punk');
    vm.navigateTo(AppSection.artists);
    vm.artists.openArtist(miles);
    vm.openArtist(daft); // from its Related artists
    expect(vm.artists.backText, 'Miles Davis');
    expect(vm.tryNavigateBack(), isTrue);
    expect(vm.artists.selectedArtist?.name, 'Miles Davis');

    vm.openArtist(daft);
    vm.openAlbum(daft.albums.first);
    vm.navigateTo(AppSection.artists);
    expect((vm.selectedSection, vm.artists.isArtistDetailOpen), (AppSection.artists, false), reason: 'its list');
    expect(vm.tryNavigateBack(), isFalse, reason: 'nothing left to go back to');
  });

  test('back to the place a page was opened from brings back what was over it (a sheet)', () async {
    final vm = await create();
    vm.navigateTo(AppSection.playlists);
    var reopened = 0;
    vm.openAlbum(vm.library.albums.first, reopen: () => reopened++);
    expect((vm.selectedTab, reopened), (AppSection.playlists, 0));
    expect(vm.tryNavigateBack(), isTrue);
    expect((vm.selectedSection, reopened), (AppSection.playlists, 1));
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
    expect(vm.nowPlayingTab, NowPlayingTab.track);
    expect(vm.player.isQueueOpen, isFalse);

    vm.nowPlayingTab = NowPlayingTab.queue;
    expect(vm.player.isQueueOpen, isTrue);
    vm.nowPlayingTab = NowPlayingTab.lyrics;
    expect(vm.player.isQueueOpen, isTrue);

    vm.closeNowPlaying();
    expect(vm.nowPlayingTab, NowPlayingTab.track);
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
      ..setSetting('preference.theme', 'dark')
      ..setSetting('preference.online_lyrics', '0')
      ..setSetting('preference.sidebar_pinned', '1')
      ..setSetting('preference.sidebar_opened', '1');
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final vm = MainViewModel(TestSupport.createEngine(), library, ServerSession(library, repo));
    await vm.start();
    expect(Localizer.instance.language, 'de');
    expect(vm.theme, WiretuneTheme.dark);
    expect(vm.useOnlineLyrics, isFalse);
    expect(vm.lyrics.isOnlineEnabled, isFalse);
    expect(vm.showPerformanceStats, isFalse);
    expect(vm.isSidebarPinned, isTrue);
    expect(vm.hasOpenedSidebar, isTrue);

    vm.changeLanguage('hu');
    vm.setTheme(WiretuneTheme.airy);
    vm.showPerformanceStats = true;
    vm.isSidebarPinned = false;
    await Future<void>.delayed(Duration.zero);
    expect(repo.getSetting('preference.language'), 'hu');
    expect(repo.getSetting('preference.theme'), 'airy');
    expect(repo.getSetting('preference.show_performance_stats'), '1');
    expect(repo.getSetting('preference.sidebar_pinned'), '0');
    Localizer.instance.setLanguage('en');
  });

  test('the streaming quality is remembered, and applied at the next start', () async {
    final repo = testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final engine = TestSupport.createEngine();
    final vm = MainViewModel(engine, library, ServerSession(library, repo));
    await vm.start();
    expect(vm.streamingQuality, StreamingQuality.original);

    vm.streamingQuality = StreamingQuality.normal;
    await Future<void>.delayed(Duration.zero);
    expect(engine.streamingQuality, StreamingQuality.normal);
    expect(repo.getSetting('preference.streaming_quality'), 'normal');

    final again = TestSupport.createEngine();
    final restarted = MainViewModel(again, library, ServerSession(library, repo));
    await restarted.start();
    expect(again.streamingQuality, StreamingQuality.normal);
    expect(restarted.streamingQuality, StreamingQuality.normal);
  });

  test('the equalizer is remembered, filters only while it is on, and a preset switches it on', () async {
    final repo = testRepository();
    final library = LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final engine = TestSupport.createEngine();
    final vm = MainViewModel(engine, library, ServerSession(library, repo));
    await vm.start();
    expect((vm.isEqualizerOn, vm.equalizer.isFlat, engine.equalizer.isFlat), (false, true, true));

    vm.setEqualizerBand(5, 4);
    expect(vm.equalizer.gains[5], 4);
    expect(engine.equalizer.isFlat, isTrue, reason: 'set, but off: the sound is not filtered');

    vm.isEqualizerOn = true;
    expect(engine.equalizer.gains[5], 4);
    vm.setEqualizerBand(0, 2.5, save: false); // a slider still being dragged is not saved
    expect(engine.equalizer.gains[0], 2.5);
    expect(Equalizer.fromJson(repo.getSetting('preference.equalizer')).gains[0], 0);
    vm.setEqualizerBand(0, 2.5);
    expect(Equalizer.fromJson(repo.getSetting('preference.equalizer')).gains[0], 2.5);
    vm.setEqualizerBand(99, 1); // no such band
    expect(vm.equalizer.gains, hasLength(10));

    vm.isEqualizerOn = false;
    vm.setEqualizerPreset('bass');
    expect(vm.isEqualizerOn, isTrue, reason: 'a preset is chosen to be heard');
    expect(engine.equalizer.gains, Equalizer.presets['bass']);
    vm.setEqualizerPreset('flat');
    expect(vm.equalizer.isFlat, isTrue);
    vm.setEqualizerPreset('no such preset');
    expect(vm.equalizer.isFlat, isTrue);

    vm.setEqualizerBand(2, -3);
    final again = TestSupport.createEngine();
    final restarted = MainViewModel(again, library, ServerSession(library, repo));
    await restarted.start();
    expect(restarted.isEqualizerOn, isTrue);
    expect(again.equalizer.gains[2], -3);
  });
}
