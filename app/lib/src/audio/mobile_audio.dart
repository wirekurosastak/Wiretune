// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../platform.dart';

/// The phone's side of playing music: the audio focus (a call pauses, a navigation prompt ducks, unplugged headphones
/// pause), and on Android a CPU and Wi-Fi lock while playing, so a stream keeps flowing with the screen off. All of it
/// is about the sound this phone makes: music it plays on another device (remote control) goes on through a call.
abstract final class MobileAudio {
  static const MethodChannel _power = MethodChannel('wiretune/power');
  static const double _duckLevel = 0.2;

  static Future<void> attach(WiretuneAudioEngine engine) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    var resumeAfterInterruption = false;
    var ducked = false;

    engine.stateChanged.listen((state) async {
      final playing = state == PlaybackState.playing;
      if (playing) await session.setActive(true);
      if (AppPlatform.current.isAndroid) {
        try {
          await _power.invokeMethod<void>('setPlaying', playing);
        } on MissingPluginException {
          // Not registered (tests): nothing to hold.
        }
      }
    });

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
