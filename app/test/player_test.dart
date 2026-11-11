// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune/src/view_models/settings_view_models.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  (PlayerViewModel, List<Track>, FakeAudioDriver) createQueue({int count = 4, int startAt = 1}) {
    final driver = FakeAudioDriver();
    final player = PlayerViewModel(TestSupport.createEngine(driver), createLibrary());
    final tracks = [for (var i = 1; i <= count; i++) TestSupport.makeTrack('t$i', 'Song $i')];
    player.playQueue(tracks, tracks[startAt]);
    return (player, tracks, driver);
  }

  test('a track counts as played once 30 seconds of it were heard, or half of a shorter one', () async {
    final driver = FakeAudioDriver();
    final library = createLibrary([
      TestSupport.makeTrack('t1', 'Song 1'),
      TestSupport.makeTrack('t2', 'Song 2'),
      TestSupport.makeTrack('t3', 'Interlude', minutes: 0.5),
    ])..initialize();
    final player = PlayerViewModel(TestSupport.createEngine(driver), library);
    List<int> plays() => [
      for (final id in ['t1', 't2', 't3']) library.playCount(id),
    ];

    player.playQueue([
      for (final id in ['t1', 't2', 't3']) library.getTrack(id)!,
    ]);
    await pumpEventQueue();
    driver.simulatePlaying(const Duration(seconds: 29));
    player.nextTrack();
    await pumpEventQueue();
    expect(plays(), [0, 0, 0], reason: 'skipped before 30 seconds');

    // A jump far into the track is not listening to it.
    await driver.seek(const Duration(minutes: 2));
    driver.simulatePlaying(const Duration(seconds: 29));
    expect(plays(), [0, 0, 0]);
    driver.simulatePlaying(const Duration(seconds: 60));
    expect(plays(), [0, 1, 0], reason: 'once, however long it plays on');

    player.nextTrack();
    await pumpEventQueue();
    driver.simulatePlaying(const Duration(seconds: 15));
    expect(plays(), [0, 1, 1], reason: 'half of a track of 30 seconds');
  });

  group('queue', () {
    test('playing a list starts the chosen track', () {
      final (player, tracks, driver) = createQueue(startAt: 2);
      expect(player.currentTrack, tracks[2]);
      expect(driver.lastSource, tracks[2].filePath);
      expect(player.currentQueueIndex, 2);
      expect(player.isCurrent(tracks[2]), isTrue);
    });

    test('play next goes right after the current track, add to queue at the end; nothing queued, they play', () {
      final (player, tracks, _) = createQueue(count: 3, startAt: 0);
      final extra = [TestSupport.makeTrack('x1', 'Extra 1'), TestSupport.makeTrack('x2', 'Extra 2')];
      player.playNext(extra);
      player.addToQueue([extra[0]]);
      expect(player.queueTracks.map((t) => t.title), ['Song 1', 'Extra 1', 'Extra 2', 'Song 2', 'Song 3', 'Extra 1']);
      expect(player.currentQueueIndex, 0, reason: 'the track that plays goes on');
      player.nextTrack();
      expect(player.currentTrack, extra[0]);

      final driver = FakeAudioDriver();
      final fresh = PlayerViewModel(TestSupport.createEngine(driver), createLibrary());
      fresh.addToQueue(extra);
      expect(fresh.currentTrack, extra[0]);
      expect(driver.lastSource, extra[0].filePath);
    });

    test(
      "queued tracks' undo takes back those entries, not other copies; the playing one gives way to what follows",
      () {
        final (player, tracks, _) = createQueue(count: 3, startAt: 0);
        final undoNext = player.playNext([tracks[0], tracks[1]])!; // Song 1, Song 1, Song 2, Song 2, Song 3
        final undoLast = player.addToQueue([tracks[2]])!; // ..., Song 3, Song 3
        player.moveQueueTrack(4, 0); // Song 3, Song 1, Song 1, Song 2, Song 2, Song 3
        expect(player.currentQueueIndex, 1);
        undoNext();
        expect(player.queueTracks.map((t) => t.title), ['Song 3', 'Song 1', 'Song 2', 'Song 3']);
        expect(player.currentQueueIndex, 1, reason: 'the track that plays goes on');
        undoLast();
        expect(player.queueTracks.map((t) => t.title), ['Song 3', 'Song 1', 'Song 2']);

        final undo = player.playNext([TestSupport.makeTrack('x', 'Extra'), tracks[0]])!;
        player.nextTrack();
        expect(player.currentTrack?.title, 'Extra');
        undo();
        expect(player.queueTracks.map((t) => t.title), ['Song 3', 'Song 1', 'Song 2']);
        expect(player.currentTrack, tracks[1], reason: 'what followed them plays');

        final gone = player.addToQueue([TestSupport.makeTrack('y', 'Gone'), tracks[0]])!;
        player.removeQueueItem(player.queueItems.last);
        gone();
        expect(player.queueTracks.map((t) => t.title), [
          'Song 3',
          'Song 1',
          'Song 2',
          'Gone',
        ], reason: 'no longer together');
      },
    );

    test('while shuffling, play next still plays next, and unshuffling keeps it after the current track', () {
      final (player, tracks, _) = createQueue(count: 5, startAt: 1);
      player.setShuffle(true);
      final next = TestSupport.makeTrack('n', 'Next');
      player.playNext([next]);
      expect(player.queueTracks[player.currentQueueIndex + 1], next);
      player.setShuffle(false);
      expect(player.queueTracks.map((t) => t.title).take(2), ['Song 2', 'Next']);
    });

    test('a track queued twice is played and removed as the entry chosen, not its first copy', () {
      final (player, tracks, _) = createQueue(count: 3, startAt: 0);
      player.addToQueue([tracks[1]]); // Song 1, Song 2, Song 3, Song 2
      player.playQueueItem(player.queueItems[3]);
      expect(player.currentQueueIndex, 3);
      player.removeQueueItem(player.queueItems[1]);
      expect(player.queueTracks.map((t) => t.title), ['Song 1', 'Song 3', 'Song 2']);
      expect(player.currentQueueIndex, 2, reason: 'still the copy that plays');
      player.moveQueueTrack(2, 0);
      expect(player.currentQueueIndex, 0);
    });

    test('removing the playing track continues with the next one, not the first', () {
      final (player, tracks, _) = createQueue(startAt: 1);
      player.removeQueueItem(player.queueItems[1]);
      expect(player.queueTracks.map((t) => t.title), ['Song 1', 'Song 3', 'Song 4']);
      expect(player.currentQueueIndex, 1);
      expect(player.queueItems[1].isCurrent, isTrue);
    });

    test('removing the playing track when it is the last ends the playback instead of restarting', () {
      final (player, tracks, _) = createQueue(startAt: 3);
      player.removeQueueItem(player.queueItems[3]);
      expect(player.queueTracks, hasLength(3));
      expect(player.queueItems.any((item) => item.isCurrent), isFalse);
    });

    test('removing the playing track with repeat-all wraps around to the first', () {
      final (player, tracks, _) = createQueue(startAt: 3);
      player.setRepeatMode(RepeatMode.all);
      player.removeQueueItem(player.queueItems[3]);
      expect(player.currentQueueIndex, 0);
    });

    test('removing the only track empties the queue', () {
      final (player, tracks, _) = createQueue(count: 1, startAt: 0);
      player.removeQueueItem(player.queueItems[0]);
      expect(player.queueTracks, isEmpty);
      expect(player.queueItems, isEmpty);
    });

    test('removing another track keeps the playing one current', () {
      for (final (remove, expected) in [(0, 1), (3, 2)]) {
        final (player, tracks, _) = createQueue(startAt: 2);
        player.removeQueueItem(player.queueItems[remove]);
        expect(player.currentQueueIndex, expected);
        expect(player.queueTracks[player.currentQueueIndex].title, 'Song 3');
      }
    });

    test("a removed track's undo puts it back where it was, unless it played or the queue changed", () {
      List<String> titles(PlayerViewModel player) => [for (final t in player.queueTracks) t.title];
      final (player, tracks, _) = createQueue(startAt: 2);
      player.removeQueueItem(player.queueItems[1])!();
      expect(titles(player), ['Song 1', 'Song 2', 'Song 3', 'Song 4']);
      expect(player.currentQueueIndex, 2, reason: 'the track that plays goes on');
      player.removeQueueItem(player.queueItems[0])!(); // the first goes back before what followed it
      player.removeQueueItem(player.queueItems[3])!();
      expect(titles(player), ['Song 1', 'Song 2', 'Song 3', 'Song 4']);
      expect(player.currentQueueIndex, 2);

      expect(player.removeQueueItem(player.queueItems[2]), isNull, reason: 'it played: the music has moved on');
      expect(player.currentTrack?.title, 'Song 4');
      final undo = player.removeQueueItem(player.queueItems[1])!;
      player.playQueue(tracks.take(2), tracks[0]);
      undo();
      expect(titles(player), ['Song 1', 'Song 2'], reason: 'another queue');

      // Shuffled, it goes back into the unshuffled order too.
      final (shuffled, _, _) = createQueue(startAt: 0);
      shuffled.setShuffle(true);
      final last = shuffled.queueTracks.last;
      shuffled.removeQueueItem(shuffled.queueItems.last)!();
      expect(shuffled.queueTracks.last, last);
      shuffled.setShuffle(false);
      expect(titles(shuffled), ['Song 1', 'Song 2', 'Song 3', 'Song 4']);
    });

    test('a track removed while shuffled does not come back when shuffle is turned off', () {
      final (player, tracks, _) = createQueue(startAt: 0);
      player.setShuffle(true);
      final victim = player.queueTracks.last;
      player.removeQueueItem(player.queueItems.last);
      player.setShuffle(false);
      expect(player.queueTracks, isNot(contains(victim)));
      expect(player.queueTracks, hasLength(tracks.length - 1));
    });

    test('moving entries keeps the current track current', () {
      final (player, tracks, _) = createQueue(startAt: 1);
      player.moveQueueTrack(1, 3);
      expect(player.queueTracks.map((t) => t.id), ['t1', 't3', 't4', 't2']);
      expect(player.currentQueueIndex, 3);
      player.moveQueueTrackUp(player.queueItems[3]);
      expect(player.currentQueueIndex, 2);
      player.moveQueueTrack(0, 9); // out of range: nothing happens
      expect(player.queueTracks.first, tracks[0]);
    });

    test('clearing keeps only the current track', () {
      final (player, tracks, _) = createQueue(startAt: 2);
      player.clearQueue();
      expect(player.queueTracks, [tracks[2]]);
      expect(player.currentQueueIndex, 0);
    });
  });

  group('transport', () {
    test('next stops at the end without repeat, wraps with repeat-all', () {
      final (player, tracks, driver) = createQueue(startAt: 3);
      player.nextTrack();
      expect(driver.state, PlaybackState.stopped);
      expect(player.currentTrack, isNull);

      final (wrapping, wrapTracks, _) = createQueue(startAt: 3);
      wrapping.setRepeatMode(RepeatMode.all);
      wrapping.nextTrack();
      expect(wrapping.currentTrack, wrapTracks[0]);
    });

    test('previous restarts the track after three seconds, otherwise goes back', () async {
      final (player, tracks, driver) = createQueue(startAt: 2);
      await driver.seek(const Duration(seconds: 10));
      player.previousTrack();
      await Future<void>.delayed(Duration.zero);
      expect(driver.currentPosition, Duration.zero);
      expect(player.currentTrack, tracks[2]);

      player.previousTrack();
      expect(player.currentTrack, tracks[1]);

      // A swipe shows the one before coming in: it goes there however far the track has played.
      await driver.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      player.previousTrack(restart: false);
      expect(player.currentTrack, tracks[0]);
    });

    test('a track that ends moves on; repeat-one plays it again', () {
      final (player, tracks, driver) = createQueue(startAt: 0);
      driver.simulateTrackEnded();
      expect(player.currentTrack, tracks[1]);

      player.setRepeatMode(RepeatMode.one);
      final calls = driver.playCalls;
      driver.simulateTrackEnded();
      expect(player.currentTrack, tracks[1]);
      expect(driver.playCalls, calls + 1);
    });

    test(
      "the queue's end goes on with music like the last (autoplay); turned off, or with nothing alike, it stops",
      () {
        final library = createLibrary([
          TestSupport.makeTrack('a1', 'Blue', artist: 'Miles Davis', album: 'Kind of Blue'),
          TestSupport.makeTrack('b1', 'Steps', artist: 'Miles Davis', album: 'Milestones'),
          TestSupport.makeTrack('b2', 'Sid', artist: 'Miles Davis', album: 'Milestones', trackNumber: 2),
        ]);
        library.initialize();
        final driver = FakeAudioDriver();
        final player = PlayerViewModel(TestSupport.createEngine(driver), library);
        final kind = library.albums.firstWhere((a) => a.title == 'Kind of Blue');
        player.playQueue(kind.tracks, null, () => kind.title, kind);

        driver.simulateTrackEnded();
        expect(player.queueTracks.first.title, 'Blue');
        expect({for (final t in player.queueTracks.skip(1)) t.title}, {'Steps', 'Sid'}, reason: 'More by the artist');
        expect(player.currentTrack?.album, 'Milestones');
        expect(player.playingFrom, Localizer.get('Autoplay'));

        // The rest plays out; nothing alike is left, so the last track stays, stopped.
        driver.simulateTrackEnded();
        final last = player.currentTrack;
        driver.simulateTrackEnded();
        expect((player.queueTracks.length, player.currentTrack, player.isPlaying), (3, last, false));

        player.isAutoplayEnabled = false;
        player.playQueue([kind.tracks.single]);
        driver.simulateTrackEnded();
        expect((player.queueTracks.length, player.isPlaying), (1, false), reason: 'off: it stops');
      },
    );

    test(
      "a track Autoplay chose and the listener skipped steers it away from that artist, until they choose again",
      () async {
        Track track(String id, String artist, String album) => TestSupport.makeTrack(
          id,
          'Song $id',
          artist: artist,
          album: album,
          trackNumber: int.parse(id.substring(1)),
        );
        final library = createLibrary([
          track('s1', 'Seed', 'Seed album'),
          for (final artist in ['B', 'C']) ...[
            track('${artist.toLowerCase()}1', artist, '$artist album'),
            track('${artist.toLowerCase()}2', artist, '$artist album'),
          ],
        ]);
        library.initialize();
        library.setRelatedMusic(
          facts: const RelatedMusicFacts(
            similarArtists: {
              'seed': {'b': 1, 'c': 0.5},
            },
          ),
        );
        final driver = FakeAudioDriver();
        final player = PlayerViewModel(TestSupport.createEngine(driver), library);
        final seed = library.getTrack('s1')!;
        int firstB() => [
          for (var i = 0; i < 30; i++) player.autoplayTracks([seed], random: math.Random(i)).first.artist,
        ].where((artist) => artist == 'B').length;
        expect(firstB(), greaterThan(20), reason: 'B is the closest');

        player.playQueue([seed]);
        driver.simulateTrackEnded(); // Autoplay goes on
        await pumpEventQueue();
        final chosen = player.currentTrack!;
        expect(player.playingFrom, Localizer.get('Autoplay'));
        driver.simulatePlaying(const Duration(seconds: 10));
        player.nextTrack(); // skipped before it counted
        await pumpEventQueue();
        final skipped = chosen.artist;
        final firstSkipped = [
          for (var i = 0; i < 30; i++) player.autoplayTracks([seed], random: math.Random(i)).first.artist,
        ].where((artist) => artist == skipped).length;
        expect(firstSkipped, lessThan(5), reason: '$skipped was skipped');

        player.playQueue([seed]); // the listener's own choice
        expect(firstB(), greaterThan(20));
      },
    );

    test('repeat cycles off, all, one', () {
      final (player, _, _) = createQueue();
      player.toggleRepeat();
      expect(player.repeatMode, RepeatMode.all);
      player.toggleRepeat();
      expect(player.repeatMode, RepeatMode.one);
      player.toggleRepeat();
      expect(player.repeatMode, RepeatMode.off);
    });

    test('after a restart the queue is back, paused where it was, and play goes on from there', () async {
      final library = createLibrary([for (var i = 1; i <= 4; i++) TestSupport.makeTrack('t$i', 'Song $i')]);
      library.initialize();
      final driver = FakeAudioDriver();
      final before = PlayerViewModel(TestSupport.createEngine(driver), library);
      before.restoreSession(); // nothing saved yet
      final tracks = [for (var i = 1; i <= 4; i++) library.getTrack('t$i')!];
      before.playQueue(tracks.reversed, tracks[2]);
      before.setRepeatMode(RepeatMode.all);
      driver.positionChanged.emit(const Duration(seconds: 75));
      await before.pause();
      before.saveSession();

      final after = FakeAudioDriver();
      final player = PlayerViewModel(TestSupport.createEngine(after), library);
      player.restoreSession();
      expect(player.queueTracks.map((t) => t.title), ['Song 4', 'Song 3', 'Song 2', 'Song 1']);
      expect(player.currentTrack?.title, 'Song 3');
      expect(player.currentQueueIndex, 1);
      expect(player.position.value, const Duration(seconds: 75));
      expect(player.repeatMode, RepeatMode.all);
      expect(player.isPlaying, isFalse);
      expect(after.playCalls, 0, reason: 'nothing plays by itself');

      await player.play();
      expect(after.lastSource, tracks[2].filePath);
      expect(after.currentPosition, const Duration(seconds: 75));
    });

    test('the sleep timer pauses after its time, or at the end of the track with the next one waiting', () async {
      final (player, tracks, driver) = createQueue(count: 3, startAt: 0);
      player.setSleepTimer(const Duration(milliseconds: 1));
      expect(player.sleepAt != null || player.sleepsAtTrackEnd, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.isPlaying, isFalse);
      expect(player.sleepAt != null || player.sleepsAtTrackEnd, isFalse);

      await player.play();
      player.sleepAtTrackEnd();
      final calls = driver.playCalls;
      driver.simulateTrackEnded();
      expect(driver.playCalls, calls, reason: 'nothing more plays');
      expect(player.currentTrack, tracks[1], reason: 'the next track waits');
      expect(player.sleepAt != null || player.sleepsAtTrackEnd, isFalse);
      await player.play();
      expect(driver.lastSource, tracks[1].filePath);
    });

    test('the next entry is ready before the track ends and takes over without a new start', () async {
      final (player, tracks, driver) = createQueue(count: 3, startAt: 0);
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, tracks[1].filePath);

      final calls = driver.playCalls;
      driver.simulateGaplessEnd();
      await Future<void>.delayed(Duration.zero);
      expect(driver.playCalls, calls, reason: 'nothing was opened anew');
      expect(player.currentTrack, tracks[1]);
      expect(player.currentQueueIndex, 1);
      expect(driver.nextSource, tracks[2].filePath);

      player.setRepeatMode(RepeatMode.one);
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, tracks[1].filePath, reason: 'repeat one plays it again');
      player.setRepeatMode(RepeatMode.off);
      player.moveQueueTrack(2, 0); // the last one to the front: nothing follows the current one now
      await Future<void>.delayed(Duration.zero);
      expect(player.queueTracks.last, tracks[1]);
      expect(driver.nextSource, isNull);
      player.moveQueueTrack(0, 2);
      player.sleepAtTrackEnd();
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, isNull, reason: 'the sleep timer stops at the end of the track');
    });

    test('with gapless playback off nothing is offered ahead and the next track opens after the end', () async {
      final (player, tracks, driver) = createQueue(count: 3, startAt: 0);
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, tracks[1].filePath);

      player.isGaplessEnabled = false;
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, isNull);
      driver.simulateTrackEnded();
      await Future<void>.delayed(Duration.zero);
      expect(driver.lastSource, tracks[1].filePath);
      expect(driver.nextSource, isNull);

      player.isGaplessEnabled = true;
      await Future<void>.delayed(Duration.zero);
      expect(driver.nextSource, tracks[2].filePath);
    });

    test('shuffle starting from a track plays it first and still plays every track', () {
      final driver = FakeAudioDriver();
      final player = PlayerViewModel(TestSupport.createEngine(driver), createLibrary());
      final tracks = [for (var i = 0; i < 20; i++) TestSupport.makeTrack('t$i', 'Song $i')];
      player.setShuffle(true);
      player.playQueue(tracks, tracks[7]);
      expect(player.queueTracks.first, tracks[7]);
      expect(player.queueTracks.toSet(), tracks.toSet());
    });

    test('turning shuffle off mid-queue continues in the original order after the current track', () {
      final (player, tracks, _) = createQueue(count: 6, startAt: 0);
      player.setShuffle(true);
      player.playQueueTrack(tracks[2]);
      player.setShuffle(false);
      expect(player.queueTracks.map((t) => t.id), ['t3', 't4', 't5', 't6']);
      expect(player.currentTrack, tracks[2]);
    });

    test('a single track ends the queue, and back plays it again', () {
      final (player, tracks, _) = createQueue(count: 1, startAt: 0);
      player.nextTrack();
      expect(player.currentTrack, isNull);
      player.previousTrack();
      expect(player.currentTrack, tracks[0]);
    });

    test('an empty list plays nothing and keeps the queue, also through shuffle on and off', () {
      final (player, tracks, _) = createQueue(startAt: 0);
      player.playQueue(const []);
      expect(player.currentTrack, tracks[0]);
      player.setShuffle(true);
      player.setShuffle(false);
      expect(player.queueTracks, tracks);
    });

    test('a playback failure is shown and cleared when playback starts again', () {
      final (player, _, driver) = createQueue();
      driver.simulateFailure('HTTP 401');
      expect(player.errorMessage, 'HTTP 401');
      expect(player.hasError, isTrue);
      player.nextTrack();
      expect(player.hasError, isFalse);
    });

    test('volume, mute and the bit-perfect lock', () async {
      final (player, _, driver) = createQueue();
      expect(player.isVolumeDisabledOrMuted, isFalse);
      player.setVolume(40);
      expect(driver.volume, closeTo(0.4, 0.001));
      player.toggleMute();
      expect(player.isVolumeDisabledOrMuted, isTrue);
      expect(driver.volume, 0);
      player.setVolume(30); // the slider moved while muted unmutes
      expect(player.isMuted, isFalse);
      expect(driver.volume, closeTo(0.3, 0.001));
      player.settleVolume();
      player.setVolume(0); // the slider down to 0 is muted, and unmuting brings back where it rested
      player.settleVolume();
      expect(player.isMuted, isTrue);
      player.toggleMute();
      expect((player.isMuted, player.volume), (false, 30.0));
      player
        ..stepVolume(-30)
        ..toggleMute();
      expect(player.volume, 30, reason: 'a step is a rest too, and 0 is none');
      player.setVolume(40);

      await player.toggleBitPerfect();
      expect(player.isVolumeLocked, isTrue);
      expect(player.volume, 100);
      expect(driver.volume, 1.0); // unity gain where the samples are scaled
      player.setVolume(10);
      expect(driver.volume, 1.0);
      player.toggleMute(); // refused in bit-perfect mode
      expect(player.isMuted, isFalse);
      await player.toggleBitPerfect();
      expect(player.volume, 40);
    });

    test(
      "the audio settings' switches are the engine's: bit-perfect brings exclusive, exclusive off ends both",
      () async {
        final settings = AudioSettingsViewModel(TestSupport.createEngine());
        addTearDown(settings.dispose);
        var told = 0;
        settings.addListener(() => told++);

        await settings.setBitPerfect(true);
        expect((settings.isBitPerfect, settings.isExclusiveMode), (true, true));
        expect(told, greaterThan(0));
        await settings.setExclusiveMode(false);
        expect((settings.isBitPerfect, settings.isExclusiveMode), (false, false));
      },
    );

    test('the spectrum follows the driver while playing and falls silent when stopped', () async {
      final (player, _, driver) = createQueue();
      driver.simulateSpectrum(List.filled(32, 0.5));
      expect(player.spectrum.value.first, 0.5);
      await driver.pause();
      expect(player.spectrum.value.first, 0);
    });
  });
}
