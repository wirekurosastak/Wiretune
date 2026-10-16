// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:typed_data';

import '../localization/localizer.dart';
import '../models/audio_format.dart';
import '../util/event.dart';

/// Volume normalization from the files' ReplayGain tags: each track at the same loudness, or each album (keeping the
/// differences between its tracks). A file without the tags plays unchanged.
enum VolumeNormalization { off, track, album }

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

  /// The track ended and the one given to [setNext] took over without a gap; drivers that can't do that never raise it
  /// (theirs ends with [trackEnded]).
  Event<void> get advanced;

  /// Playback could not start or stopped unexpectedly; the argument is a user-facing message.
  Event<String> get playbackFailed;

  /// The outputs this driver can play to.
  Future<List<AudioOutputDevice>> detectDevices();

  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitPerfect});
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  Future<void> stop();
  void setVolume(double volume);

  /// What to play right when the current track ends, without a gap ([advanced] tells when it did); null for nothing. A
  /// new [play] forgets it. A driver that can't play gaplessly ignores it.
  Future<void> setNext(String? audioSource);

  /// Applies [mode] from now on; a driver that cannot normalize ignores it, and bit-perfect output never normalizes.
  void setNormalization(VolumeNormalization mode);
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
  final Event<void> advanced = Event<void>();
  @override
  final Event<String> playbackFailed = Event<String>();
}

enum PlaybackState { stopped, playing, paused, error }

/// An output the player can send audio to.
class AudioOutputDevice {
  const AudioOutputDevice({
    this.id = 'default',
    String? name,
    this.nameKey,
    this.driverType = 'Default',
    this.hardwareCard = '',
    this.isExclusiveSupported = false,
    this.isBitPerfectSupported = false,
    this.isDefault = false,
    this.supportedSampleRates = const [44100, 48000, 88200, 96000, 176400, 192000],
  }) : _name = name;

  final String id;
  final String? _name;

  /// Key of the translated name to use when no explicit name was given.
  final String? nameKey;

  /// ALSA, PipeWire, WASAPI, CoreAudio, Android, Tizen ...
  final String driverType;
  final String hardwareCard;
  final bool isExclusiveSupported;
  final bool isBitPerfectSupported;
  final bool isDefault;
  final List<int> supportedSampleRates;

  /// Name shown to the user. Devices without an explicit name get a translated "default output" text that is looked
  /// up when read, so it follows the interface language.
  String get name => _name ?? Localizer.get(nameKey ?? 'AudioSystemDefaultOutput');

  String get displayTitle => hardwareCard.trim().isEmpty ? name : '$name ($hardwareCard)';
}
