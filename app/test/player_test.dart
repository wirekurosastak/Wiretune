import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
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
      expect(tracks[2].isPlaying, isTrue);
    });

    test('removing the playing track continues with the next one, not the first', () {
      final (player, tracks, _) = createQueue(startAt: 1);
      player.removeQueueTrack(tracks[1]);
      expect(player.queueTracks.map((t) => t.title), ['Song 1', 'Song 3', 'Song 4']);
      expect(player.currentQueueIndex, 1);
      expect(player.queueItems[1].isCurrent, isTrue);
    });

    test('removing the playing track when it is the last ends the playback instead of restarting', () {
      final (player, tracks, _) = createQueue(startAt: 3);
      player.removeQueueTrack(tracks[3]);
      expect(player.queueTracks, hasLength(3));
      expect(player.queueItems.any((item) => item.isCurrent), isFalse);
    });

    test('removing the playing track with repeat-all wraps around to the first', () {
      final (player, tracks, _) = createQueue(startAt: 3);
      player.repeatMode = RepeatMode.all;
      player.removeQueueTrack(tracks[3]);
      expect(player.currentQueueIndex, 0);
    });

    test('removing the only track empties the queue', () {
      final (player, tracks, _) = createQueue(count: 1, startAt: 0);
      player.removeQueueTrack(tracks[0]);
      expect(player.queueTracks, isEmpty);
      expect(player.queueItems, isEmpty);
    });

    test('removing another track keeps the playing one current', () {
      for (final (remove, expected) in [(0, 1), (3, 2)]) {
        final (player, tracks, _) = createQueue(startAt: 2);
        player.removeQueueTrack(tracks[remove]);
        expect(player.currentQueueIndex, expected);
        expect(player.queueTracks[player.currentQueueIndex].title, 'Song 3');
      }
    });

    test('a track removed while shuffled does not come back when shuffle is turned off', () {
      final (player, tracks, _) = createQueue(startAt: 0);
      player.setShuffle(true);
      final victim = player.queueTracks.last;
      player.removeQueueTrack(victim);
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
      wrapping.repeatMode = RepeatMode.all;
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
    });

    test('a track that ends moves on; repeat-one plays it again', () {
      final (player, tracks, driver) = createQueue(startAt: 0);
      driver.simulateTrackEnded();
      expect(player.currentTrack, tracks[1]);

      player.repeatMode = RepeatMode.one;
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

      await player.toggleBitperfect();
      expect(player.isVolumeLocked, isTrue);
      expect(player.volume, 100);
      expect(driver.volume, 1.0); // unity gain where the samples are scaled
      player.setVolume(10);
      expect(driver.volume, 1.0);
      player.toggleMute(); // refused in bit-perfect mode
      expect(player.isMuted, isFalse);
      await player.toggleBitperfect();
      expect(player.volume, 40);
    });

    test('the spectrum follows the driver while playing and falls silent when stopped', () async {
      final (player, _, driver) = createQueue();
      driver.simulateSpectrum(List.filled(32, 0.5));
      expect(player.spectrum.value.first, 0.5);
      await driver.pause();
      expect(player.spectrum.value.first, 0);
    });
  });

  group('lyrics', () {
    PlayerViewModel createPlayer({LyricsProvider? own, LyricsProvider? online}) =>
        PlayerViewModel(TestSupport.createEngine(), createLibrary())
          ..lyricsProvider = own
          ..onlineLyricsProvider = online;

    Future<String?> nothing(Track track, CancellationToken ct) async => null;

    test('are loaded only while the panel is open, and follow the track', () async {
      final requested = <String>[];
      final player = createPlayer(
        own: (track, ct) async {
          requested.add(track.id);
          return 'Lyrics of ${track.id}';
        },
      );

      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requested, isEmpty); // panel closed: nothing is read
      expect(player.hasLyrics, isFalse);

      player.isQueueOpen = true;
      expect(await waitUntil(() => player.plainLyricsText == 'Lyrics of t1'), isTrue);

      player.currentTrack = TestSupport.makeTrack('t2', 'Two');
      expect(await waitUntil(() => player.plainLyricsText == 'Lyrics of t2'), isTrue);

      player.isQueueOpen = false;
      player.isQueueOpen = true; // reopening does not fetch again
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requested, ['t1', 't2']);

      player.currentTrack = null;
      expect(player.plainLyricsText, isNull);
      expect(player.hasLyrics, isFalse);
    });

    test('own lyrics are used without asking the internet', () async {
      var asked = 0;
      final player = createPlayer(
        own: (_, _) async => 'From the tag',
        online: (_, _) async {
          asked++;
          return 'From the internet';
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.hasLyrics), isTrue);
      expect(player.plainLyricsText, 'From the tag');
      expect(player.lyricsOrigin, LyricsOrigin.tags);
      expect(player.lyricsSourceText, "Source: the track's own tags");
      expect(asked, 0);
    });

    test('a track without lyrics is looked up online and the source is credited', () async {
      final player = createPlayer(own: nothing, online: (_, _) async => 'From the internet');
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.hasLyrics), isTrue);
      expect(player.lyricsOrigin, LyricsOrigin.online);
      expect(player.lyricsSourceText, 'Source: LRCLIB');
      expect(player.isLoadingLyrics, isFalse);
      expect(player.showLyricsEmptyState, isFalse);
    });

    test('with the lookup switched off nothing is sent and the panel points to the setting', () async {
      var asked = 0;
      final player = createPlayer(
        own: nothing,
        online: (_, _) async {
          asked++;
          return 'x';
        },
      );
      player.isOnlineLyricsEnabled = false;
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.showLyricsEmptyState), isTrue);
      expect(asked, 0);
      expect(player.lyricsEmptyText, contains('Settings'));

      player.isOnlineLyricsEnabled = true; // switched on while the panel is open: looked up at once
      expect(await waitUntil(() => player.hasLyrics), isTrue);
      expect(player.lyricsOrigin, LyricsOrigin.online);

      player.isOnlineLyricsEnabled = false; // and off again: the internet's lyrics go away
      expect(await waitUntil(() => !player.hasLyrics && !player.isLoadingLyrics), isTrue);
    });

    test('when nothing is found the panel says so', () async {
      final player = createPlayer(own: nothing, online: nothing);
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.showLyricsEmptyState), isTrue);
      expect(player.lyricsEmptyText, 'No lyrics found for this track.');
      expect(player.lyricsSourceText, '');
    });

    test('while looking the panel shows a note, not the empty message', () async {
      final pending = Completer<String?>();
      final player = createPlayer(own: nothing, online: (_, _) => pending.future);
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(player.isLoadingLyrics, isTrue);
      expect(player.showLyricsEmptyState, isFalse);
      pending.complete('Done');
      expect(await waitUntil(() => player.hasLyrics), isTrue);
      expect(player.isLoadingLyrics, isFalse);
    });

    test('when the service cannot be reached the panel says that, and reopening tries again', () async {
      var asked = 0;
      final player = createPlayer(
        own: nothing,
        online: (_, _) async {
          asked++;
          throw const LyricsLookupException('offline');
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.lyricsLookupFailed), isTrue);
      expect(player.showLyricsEmptyState, isTrue);
      expect(player.lyricsEmptyText, contains("Couldn't reach"));
      expect(asked, 1);

      player.isQueueOpen = false;
      player.isQueueOpen = true;
      expect(await waitUntil(() => asked == 2), isTrue);
    });

    test('a failing own provider does not stop the internet lookup', () async {
      final player = createPlayer(
        own: (_, _) async => throw StateError('disk on fire'),
        online: (_, _) async => 'Online',
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => player.hasLyrics), isTrue);
      expect(player.lyricsOrigin, LyricsOrigin.online);
    });

    test('a slow lookup for a track that is no longer playing is ignored, and cancelled', () async {
      final slow = Completer<String?>();
      CancellationToken? firstToken;
      final player = createPlayer(
        own: nothing,
        online: (track, ct) {
          if (track.id != 't1') return Future.value('Lyrics of t2');
          firstToken = ct;
          return slow.future;
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => firstToken != null), isTrue);
      player.currentTrack = TestSupport.makeTrack('t2', 'Two');
      expect(firstToken!.isCancelled, isTrue);
      expect(await waitUntil(() => player.plainLyricsText == 'Lyrics of t2'), isTrue);

      slow.complete('Lyrics of t1 (late)');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(player.plainLyricsText, 'Lyrics of t2');
      expect(player.isLoadingLyrics, isFalse);
    });

    test('time-synced lyrics highlight the line at the position', () async {
      final driver = FakeAudioDriver();
      final player = PlayerViewModel(TestSupport.createEngine(driver), createLibrary())
        ..lyricsProvider = ((_, _) async => '[00:01.00]One\n[00:05.00]Two\n[00:09.00]Three');
      player.isQueueOpen = true;
      player.playQueue([TestSupport.makeTrack('t1', 'Song')]);
      expect(await waitUntil(() => player.hasSyncedLyrics), isTrue);
      expect(player.currentLyricIndex.value, -1);

      await driver.seek(const Duration(seconds: 6));
      expect(player.currentLyricIndex.value, 1);
      expect(player.lyricLines[0].isPast, isTrue);
      expect(player.lyricLines[1].isActive, isTrue);

      player.seekToLyric(player.lyricLines[2]);
      expect(player.position.value, const Duration(seconds: 9));
      expect(player.currentLyricIndex.value, 2);
    });
  });
}
