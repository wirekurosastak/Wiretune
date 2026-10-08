// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/audio/media_session.dart';
import 'package:wiretune_core/wiretune_core.dart' hide PlaybackState;

import 'support.dart';

/// The system's media session (Android's notification, lock screen and Auto, Control Center, MPRIS) moves the
/// progress on by itself from the position it was given and the time it was taken: it is told about changes, never
/// about a track that simply plays on.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test('the playback state is published at changes, not at every position update', () async {
    final driver = FakeAudioDriver();
    final library = createLibrary([TestSupport.makeTrack('1', 'One'), TestSupport.makeTrack('2', 'Two')]);
    await library.initialize();
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
}
