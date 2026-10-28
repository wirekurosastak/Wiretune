// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

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
      player.toggleMute();

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
