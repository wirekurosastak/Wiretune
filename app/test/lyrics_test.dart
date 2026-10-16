// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/lyrics_view_model.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  group('lyrics', () {
    (PlayerViewModel, LyricsViewModel) createLyrics({LyricsProvider? own, LyricsProvider? online}) {
      final player = PlayerViewModel(TestSupport.createEngine(), createLibrary());
      return (player, LyricsViewModel(player, own: own, online: online));
    }

    Future<String?> nothing(Track track) async => null;

    test('are loaded only while the panel is open, and follow the track', () async {
      final requested = <String>[];
      final (player, lyrics) = createLyrics(
        own: (track) async {
          requested.add(track.id);
          return 'Lyrics of ${track.id}';
        },
      );

      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requested, isEmpty); // panel closed: nothing is read
      expect(lyrics.hasLyrics, isFalse);

      player.isQueueOpen = true;
      expect(await waitUntil(() => lyrics.plainText == 'Lyrics of t1'), isTrue);

      player.currentTrack = TestSupport.makeTrack('t2', 'Two');
      expect(await waitUntil(() => lyrics.plainText == 'Lyrics of t2'), isTrue);

      player.isQueueOpen = false;
      player.isQueueOpen = true; // reopening does not fetch again
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requested, ['t1', 't2']);

      player.currentTrack = null;
      expect(lyrics.plainText, isNull);
      expect(lyrics.hasLyrics, isFalse);
    });

    test('own lyrics are used without asking the internet', () async {
      var asked = 0;
      final (player, lyrics) = createLyrics(
        own: (_) async => 'From the tag',
        online: (_) async {
          asked++;
          return 'From the internet';
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.hasLyrics), isTrue);
      expect(lyrics.plainText, 'From the tag');
      expect(lyrics.origin, LyricsOrigin.tags);
      expect(lyrics.sourceText, "Source: the track's own tags");
      expect(asked, 0);
    });

    test('a track without lyrics is looked up online and the source is credited', () async {
      final (player, lyrics) = createLyrics(own: nothing, online: (_) async => 'From the internet');
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.hasLyrics), isTrue);
      expect(lyrics.origin, LyricsOrigin.online);
      expect(lyrics.sourceText, 'Source: LRCLIB');
      expect(lyrics.isLoading, isFalse);
      expect(lyrics.showEmptyState, isFalse);
    });

    test('with the lookup switched off nothing is sent and the panel points to the setting', () async {
      var asked = 0;
      final (player, lyrics) = createLyrics(
        own: nothing,
        online: (_) async {
          asked++;
          return 'x';
        },
      );
      lyrics.isOnlineEnabled = false;
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.showEmptyState), isTrue);
      expect(asked, 0);
      expect(lyrics.emptyText, contains('Settings'));

      lyrics.isOnlineEnabled = true; // switched on while the panel is open: looked up at once
      expect(await waitUntil(() => lyrics.hasLyrics), isTrue);
      expect(lyrics.origin, LyricsOrigin.online);

      lyrics.isOnlineEnabled = false; // and off again: the internet's lyrics go away
      expect(await waitUntil(() => !lyrics.hasLyrics && !lyrics.isLoading), isTrue);
    });

    test('when nothing is found the panel says so', () async {
      final (player, lyrics) = createLyrics(own: nothing, online: nothing);
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.showEmptyState), isTrue);
      expect(lyrics.emptyText, 'No lyrics found for this track.');
      expect(lyrics.sourceText, '');
    });

    test('while looking the panel shows a note, not the empty message', () async {
      final pending = Completer<String?>();
      final (player, lyrics) = createLyrics(own: nothing, online: (_) => pending.future);
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(lyrics.isLoading, isTrue);
      expect(lyrics.showEmptyState, isFalse);
      pending.complete('Done');
      expect(await waitUntil(() => lyrics.hasLyrics), isTrue);
      expect(lyrics.isLoading, isFalse);
    });

    test('when the service cannot be reached the panel says that, and reopening tries again', () async {
      var asked = 0;
      final (player, lyrics) = createLyrics(
        own: nothing,
        online: (_) async {
          asked++;
          throw const LyricsLookupException('offline');
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.lookupFailed), isTrue);
      expect(lyrics.showEmptyState, isTrue);
      expect(lyrics.emptyText, contains('Lyrics service unreachable'));
      expect(asked, 1);

      player.isQueueOpen = false;
      player.isQueueOpen = true;
      expect(await waitUntil(() => asked == 2), isTrue);
    });

    test('a failing own provider does not stop the internet lookup', () async {
      final (player, lyrics) = createLyrics(
        own: (_) async => throw StateError('disk on fire'),
        online: (_) async => 'Online',
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => lyrics.hasLyrics), isTrue);
      expect(lyrics.origin, LyricsOrigin.online);
    });

    test('a slow lookup for a track that is no longer playing is ignored', () async {
      final slow = Completer<String?>();
      var asked = false;
      final (player, lyrics) = createLyrics(
        own: nothing,
        online: (track) {
          if (track.id != 't1') return Future.value('Lyrics of t2');
          asked = true;
          return slow.future;
        },
      );
      player.isQueueOpen = true;
      player.currentTrack = TestSupport.makeTrack('t1', 'One');
      expect(await waitUntil(() => asked), isTrue);
      player.currentTrack = TestSupport.makeTrack('t2', 'Two');
      expect(await waitUntil(() => lyrics.plainText == 'Lyrics of t2'), isTrue);

      slow.complete('Lyrics of t1 (late)');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(lyrics.plainText, 'Lyrics of t2');
      expect(lyrics.isLoading, isFalse);
    });

    test('time-synced lyrics highlight the line at the position', () async {
      final driver = FakeAudioDriver();
      final player = PlayerViewModel(TestSupport.createEngine(driver), createLibrary());
      final lyrics = LyricsViewModel(player, own: (_) async => '[00:01.00]One\n[00:05.00]Two\n[00:09.00]Three');
      player.isQueueOpen = true;
      player.playQueue([TestSupport.makeTrack('t1', 'Song')]);
      expect(await waitUntil(() => lyrics.isSynced), isTrue);
      expect(lyrics.currentLine.value, -1);

      await driver.seek(const Duration(seconds: 6));
      expect(lyrics.currentLine.value, 1);

      lyrics.seekTo(lyrics.lines[2]);
      expect(player.position.value, const Duration(seconds: 9));
      expect(lyrics.currentLine.value, 2);
    });
  });
}
