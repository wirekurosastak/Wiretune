// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../platform.dart';

/// The phone's side of playing music: the audio focus (a call pauses, a navigation prompt ducks, unplugged headphones
/// pause), and on Android a CPU lock while playing and a Wi-Fi lock while the music comes over the network, so a stream
/// keeps flowing with the screen off (a local file or a download leaves the radio free to sleep). All of it is about
/// the sound this phone makes: music it plays on another device (remote control) goes on through a call.
abstract final class MobileAudio {
  static const MethodChannel _power = MethodChannel('wiretune/power');
  static const double _duckLevel = 0.2;

  static Future<void> attach(WiretuneAudioEngine engine) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    var resumeAfterInterruption = false;
    var ducked = false;

    Future<void> holdLocks() async {
      if (!AppPlatform.current.isAndroid) return;
      final playing = engine.state == PlaybackState.playing;
      final track = engine.currentTrack;
      try {
        await _power.invokeMethod<void>('setPlaying', {
          'playing': playing,
          'streaming': playing && track != null && engine.streams(track),
        });
      } on MissingPluginException {
        // Not registered (tests): nothing to hold.
      }
    }

    engine.stateChanged.listen((state) async {
      if (state == PlaybackState.playing) await session.setActive(true);
      await holdLocks();
    });
    // The next track may come from elsewhere (a stream after a download) without playback ever pausing.
    engine.trackChanged.listen((_) => holdLocks());

    session.interruptionEventStream.listen((event) async {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            if (!engine.isBitPerfect) {
              ducked = true;
              engine.driver.setVolume(engine.volume * _duckLevel);
            }
          case AudioInterruptionType.pause || AudioInterruptionType.unknown:
            resumeAfterInterruption =
                engine.state == PlaybackState.playing && event.type == AudioInterruptionType.pause;
            if (engine.state == PlaybackState.playing) await engine.pause();
        }
      } else {
        if (ducked) {
          ducked = false;
          engine.driver.setVolume(engine.volume);
        }
        if (resumeAfterInterruption) {
          resumeAfterInterruption = false;
          if (engine.state == PlaybackState.paused) await engine.resume();
        }
      }
    });

    session.becomingNoisyEventStream.listen((_) {
      if (engine.state == PlaybackState.playing) unawaited(engine.pause());
    });
  }
}
