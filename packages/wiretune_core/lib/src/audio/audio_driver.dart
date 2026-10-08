// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:typed_data';

import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../util/event.dart';

/// Plays audio on one platform. The engine ([WiretuneAudioEngine]) keeps the track, mode and volume and gives this
/// the commands; a driver reports back through its events.
abstract class AudioDriver {
  PlaybackState get state;
  Duration get currentPosition;

  Event<PlaybackState> get stateChanged;
  Event<Duration> get positionChanged;

  /// 64 band levels (0..1), about 30 times a second while playing; drivers without an analyser never raise it.
  Event<Float32List> get spectrumDataAvailable;
  Event<void> get trackEnded;

  /// Playback could not start or stopped unexpectedly; the argument is a user-facing message.
  Event<String> get playbackFailed;

  /// The outputs this driver can play to.
  Future<List<AudioOutputDevice>> detectDevices();

  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitperfect});
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  Future<void> stop();
  void setVolume(double volume);
  Future<void> dispose();
}

/// The events every driver raises, so an implementation only has to fire them.
mixin AudioDriverEvents implements AudioDriver {
  @override
  final Event<PlaybackState> stateChanged = Event<PlaybackState>();
  @override
  final Event<Duration> positionChanged = Event<Duration>();
  @override
  final Event<Float32List> spectrumDataAvailable = Event<Float32List>();
  @override
  final Event<void> trackEnded = Event<void>();
  @override
  final Event<String> playbackFailed = Event<String>();
}
