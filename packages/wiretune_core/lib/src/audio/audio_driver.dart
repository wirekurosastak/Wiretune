// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:typed_data';

import '../localization/localizer.dart';
import '../models/audio_format.dart';
import '../util/event.dart';

/// Volume normalization from the files' ReplayGain tags: each track at the same loudness, or each album (keeping the
/// differences between its tracks). A file without the tags plays unchanged.
enum VolumeNormalization { off, track, album }

/// How much of a server track is sent: the original file, or the server's conversion to Opus at a bitrate (which needs
/// `ffmpeg` on the server; without it the file is sent as it is). Downloads and bit-perfect output are always the file.
enum StreamingQuality {
  original(0),
  high(160),
  normal(96),
  dataSaver(48);

  const StreamingQuality(this.kbps);

  /// The Opus bitrate asked of the server; 0 for the file itself.
  final int kbps;
}

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

  /// Whether [readOutput] can ever tell; a driver that can't is not asked.
  bool get reportsOutput;

  /// What the output was actually opened with for the track playing now, as the player reports it (not as was asked
  /// for); null when the output isn't open yet.
  Future<AudioOutputInfo?> readOutput();
  Future<void> dispose();
}

/// The format the output was opened with.
class AudioOutputInfo {
  const AudioOutputInfo({required this.sampleRate, required this.sampleFormat, this.channels, this.backend});

  final int sampleRate;

  /// The sample format as the player names it: `s16`, `s32`, `float`, …
  final String sampleFormat;
  final int? channels;

  /// The output driver: `alsa`, `pipewire`, `wasapi`, `coreaudio`, …
  final String? backend;

  /// The bits one sample of [sampleFormat] holds; null for a format this doesn't know.
  int? get bitsPerSample {
    final match = RegExp(r'^(?:s|u)(\d+)p?$').firstMatch(sampleFormat);
    if (match != null) return int.parse(match.group(1)!);
    return switch (sampleFormat.replaceAll('p', '')) {
      'float' => 32,
      'double' => 64,
      _ => null,
    };
  }
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

  /// A driver that can't tell what its output was opened with.
  @override
  bool get reportsOutput => false;

  @override
  Future<AudioOutputInfo?> readOutput() async => null;
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

  /// Name shown to the user. Devices without an explicit name get a translated "default output" text that is looked
  /// up when read, so it follows the interface language.
  String get name => _name ?? Localizer.get(nameKey ?? 'AudioSystemDefaultOutput');

  String get displayTitle => hardwareCard.trim().isEmpty ? name : '$name ($hardwareCard)';
}
