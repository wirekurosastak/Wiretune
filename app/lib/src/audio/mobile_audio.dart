import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../platform.dart';
import '../view_models/player_view_model.dart';

/// The phone's side of playing music: the audio focus (a call pauses, a navigation prompt ducks, unplugged headphones
/// pause), and on Android a CPU and Wi-Fi lock while playing, so a stream keeps flowing with the screen off.
class MobileAudio {
  MobileAudio._();

  static const MethodChannel _power = MethodChannel('wiretune/power');
  static const double _duckLevel = 0.2;

  static Future<void> attach(WiretuneAudioEngine engine, PlayerViewModel player) async {
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
            if (!engine.isBitperfect) {
              ducked = true;
              engine.driver.setVolume(engine.volume * _duckLevel);
            }
          case AudioInterruptionType.pause || AudioInterruptionType.unknown:
            resumeAfterInterruption =
                engine.state == PlaybackState.playing && event.type == AudioInterruptionType.pause;
            await player.pause();
        }
      } else {
        if (ducked) {
          ducked = false;
          engine.driver.setVolume(engine.volume);
        }
        if (resumeAfterInterruption) {
          resumeAfterInterruption = false;
          await player.play();
        }
      }
    });

    session.becomingNoisyEventStream.listen((_) => unawaited(player.pause()));
  }
}
