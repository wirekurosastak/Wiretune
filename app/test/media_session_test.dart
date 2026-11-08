// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/audio/media_session.dart';
import 'package:wiretune/src/view_models/library_view_models.dart';
import 'package:wiretune_core/wiretune_core.dart' hide PlaybackState;

import 'support.dart';

/// The system's media session (Android's notification, lock screen and Auto, Control Center, MPRIS) moves the
/// progress on by itself from the position it was given and the time it was taken: it is told about changes, never
/// about a track that simply plays on.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test(
    "the notification has the track's heart and shuffle beside the transport; they mark it, and follow it",
    () async {
      final library = createLibrary([TestSupport.makeTrack('1', 'One'), TestSupport.makeTrack('2', 'Two')]);
      library.initialize();
      final vm = createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
      final session = WiretuneMediaSession(vm);
      List<String> icons() => [for (final c in session.playbackState.value.controls) c.androidIcon];

      expect(icons(), isNot(contains('drawable/ic_favorite_border')), reason: 'no heart without a track');
      vm.player.playQueue(vm.library.tracks);
      await pumpEventQueue();
      expect(icons().first, 'drawable/ic_favorite_border');
      expect(icons().last, 'drawable/ic_shuffle');
      expect(session.playbackState.value.androidCompactActionIndices, [1, 2, 3], reason: 'folded: the transport');

      await session.customAction(WiretuneMediaSession.favoriteAction);
      await pumpEventQueue();
      expect(vm.library.isFavorite('1'), isTrue);
      expect(icons().first, 'drawable/ic_favorite');

      await session.customAction(WiretuneMediaSession.shuffleAction);
      await pumpEventQueue();
      expect(vm.player.isShuffle, isTrue);
      expect(icons().last, 'drawable/ic_shuffle_on');

      // A heart marked elsewhere (the app, another device) shows here too.
      vm.library.toggleFavorite(vm.player.currentTrack!.id);
      await pumpEventQueue();
      expect(icons().first, 'drawable/ic_favorite_border');

      session.playbackState.close();
      vm.dispose();
    },
  );

  test(
    "Android's home-screen widget is told what plays, the heart and shuffle too, and only when that changes",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final told = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('wiretune/power'),
        (call) async {
          if (call.method == 'showOnWidget') told.add(call.arguments as Map<Object?, Object?>);
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('wiretune/power'),
          null,
        ),
      );
      final library = createLibrary([TestSupport.makeTrack('1', 'One')]);
      library.initialize();
      final vm = createMainViewModel(library, TestSupport.createEngine(FakeAudioDriver()));
      final session = WiretuneMediaSession(vm, homeWidget: true);
      await pumpEventQueue();
      expect(told.single['title'], isNull, reason: 'nothing plays');

      vm.player.playQueue(vm.library.tracks);
      await pumpEventQueue();
      expect((told.last['title'], told.last['playing'], told.last['favorite']), ('One', true, false));
      final before = told.length;
      vm.player.position.value = const Duration(seconds: 5);
      await pumpEventQueue();
      expect(told, hasLength(before), reason: 'the position is no news to it');

      vm.library.toggleFavorite('1');
      vm.player.toggleShuffle();
      await pumpEventQueue();
      expect((told.last['favorite'], told.last['shuffle']), (true, true));

      session.playbackState.close();
      vm.dispose();
    },
  );

  test('the playback state is published at changes, not at every position update', () async {
    final driver = FakeAudioDriver();
    final library = createLibrary([TestSupport.makeTrack('1', 'One'), TestSupport.makeTrack('2', 'Two')]);
    library.initialize();
    final vm = createMainViewModel(library, TestSupport.createEngine(driver));
    var now = DateTime(2026, 10, 5, 12);
    final session = WiretuneMediaSession(vm, now: () => now);
    final published = <PlaybackState>[];
    session.playbackState.skip(1).listen(published.add); // the first is the seed, not a publication
    Future<void> settle() => pumpEventQueue();

    vm.player.playQueue(vm.library.tracks);
    await settle();
    expect((published.last.playing, published.last.updatePosition), (true, Duration.zero));
    final started = published.length;

    // Ten seconds of playback, a position update every 150 ms, at the pace of the clock: nothing to tell.
    for (var ms = 150; ms <= 10000; ms += 150) {
      now = now.add(const Duration(milliseconds: 150));
      driver.positionChanged.emit(Duration(milliseconds: ms));
    }
    await settle();
    expect(published, hasLength(started));

    // A seek is a jump the system cannot know of.
    driver.positionChanged.emit(const Duration(minutes: 2));
    await settle();
    expect(published, hasLength(started + 1));
    expect((published.last.updatePosition, published.last.updateTime), (const Duration(minutes: 2), now));

    // A stream that stalls for three seconds falls behind the system's count: corrected as soon as it moves again.
    now = now.add(const Duration(seconds: 3));
    driver.positionChanged.emit(const Duration(minutes: 2, milliseconds: 150));
    await settle();
    expect(published, hasLength(started + 2));
    expect(published.last.updatePosition, const Duration(minutes: 2, milliseconds: 150));

    // The modes, the next track (which starts from its beginning) and a pause are told as they happen.
    vm.player.toggleRepeat();
    await settle();
    expect(published.last.repeatMode, AudioServiceRepeatMode.all);
    vm.player.nextTrack();
    await settle();
    expect((published.last.queueIndex, published.last.updatePosition), (1, Duration.zero));
    await vm.player.pause();
    await settle();
    expect(published.last.playing, isFalse);

    session.playbackState.close();
    vm.dispose();
  });

  test('another queue of the same length is published, and a search result in the car plays', () async {
    final library = createLibrary([
      TestSupport.makeTrack('a1', 'One', album: 'A'),
      TestSupport.makeTrack('a2', 'Two', album: 'A'),
      TestSupport.makeTrack('b1', 'Naima', album: 'B'),
      TestSupport.makeTrack('b2', 'Giant Steps', album: 'B'),
    ]);
    library.initialize();
    final vm = createMainViewModel(library);
    final session = WiretuneMediaSession(vm);
    List<String> published() => [for (final item in session.queue.value) item.id];

    List<String> idsOf(String album) => [
      for (final t in library.albums.firstWhere((a) => a.title == album).tracks) 'track:${t.id}',
    ];
    vm.player.playQueue(library.albums.firstWhere((a) => a.title == 'A').tracks);
    await pumpEventQueue();
    expect(published(), idsOf('A'));
    vm.player.playQueue(library.albums.firstWhere((a) => a.title == 'B').tracks);
    await pumpEventQueue();
    expect(published(), idsOf('B'));

    final found = await session.search('giant');
    expect(found.map((item) => item.id), ['search:giant|b2']);
    await session.playFromMediaId(found.single.id);
    await pumpEventQueue();
    expect(vm.player.currentTrack?.id, 'b2');

    vm.dispose();
  });

  test("the car's lists are in the order chosen in the app", () async {
    final library = createLibrary([
      TestSupport.makeTrack('1', 'Beta', artist: 'Zed', album: 'Old')..addedAt = DateTime.utc(2025),
      TestSupport.makeTrack('2', 'Alpha', artist: 'Abba', album: 'New')..addedAt = DateTime.utc(2026),
    ]);
    library.initialize();
    final vm = createMainViewModel(library);
    final session = WiretuneMediaSession(vm);
    Future<List<String?>> titles(String id) async => [for (final item in await session.getChildren(id)) item.title];

    expect(await titles('tracks'), ['Alpha', 'Beta']); // ABC, as the Tracks page starts
    vm.tracks.setSortField(TrackSortField.artist);
    vm.tracks.setSortField(TrackSortField.artist);
    expect(await titles('tracks'), ['Beta', 'Alpha']);
    vm.albums.setSortField(AlbumSortField.added);
    expect(await titles('albums'), ['New', 'Old']);

    vm.dispose();
  });
}
