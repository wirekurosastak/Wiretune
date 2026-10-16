// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Plays on Tizen TVs through the platform's media player (the Tizen implementation of audioplayers). The TV decides
/// the output; there is no device choice and no exclusive mode, and what decodes depends on the TV's firmware.
class TizenAudioDriver with AudioDriverEvents implements AudioDriver {
  static const String _playerId = 'wiretune-player';

  final AudioplayersPlatformInterface _platform = AudioplayersPlatformInterface.instance;
  Future<void>? _created;
  StreamSubscription<AudioEvent>? _events;
  Timer? _positionTimer;
  PlaybackState _state = PlaybackState.stopped;
  Duration _position = Duration.zero;
  int _generation = 0;
  double _volume = 1.0;

  @override
  PlaybackState get state => _state;

  @override
  Duration get currentPosition => _position;

  Future<void> _ensureCreated() => _created ??= () async {
    await _platform.create(_playerId);
    _events = _platform
        .getEventStream(_playerId)
        .listen(
          (event) {
            if (event.eventType == AudioEventType.complete && _state == PlaybackState.playing) {
              _generation++;
              _setState(PlaybackState.stopped);
              trackEnded.emit(null);
            }
          },
          onError: (Object error) {
            WiretuneLog.warn('TizenDriver', 'Player error: ${WiretuneLog.redact('$error')}');
            _generation++;
            _setState(PlaybackState.error);
            playbackFailed.emit(Localizer.format('DriverPlaybackFailed', [WiretuneLog.redact('$error')]));
          },
        );
  }();

  @override
  Future<List<AudioOutputDevice>> detectDevices() async => const [
    AudioOutputDevice(id: 'tizen', nameKey: 'AudioSystemDefaultOutput', driverType: 'Tizen', isDefault: true),
  ];

  @override
  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitPerfect}) async {}

  @override
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition) async {
    await _ensureCreated();
    final generation = ++_generation;
    _position = startPosition;
    _setState(PlaybackState.playing);
    try {
      await _platform.stop(_playerId);
      await _platform.setSourceUrl(_playerId, audioSource, isLocal: !audioSource.startsWith('http'));
      if (generation != _generation) return;
      await _platform.setVolume(_playerId, _volume);
      if (startPosition > Duration.zero) await _platform.seek(_playerId, startPosition);
      await _platform.resume(_playerId);
      _startPositionTimer();
    } catch (e) {
      if (generation != _generation) return;
      _setState(PlaybackState.error);
      playbackFailed.emit(Localizer.format('DriverCannotStart', [WiretuneLog.redact('$e')]));
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_state != PlaybackState.playing) return;
      final millis = await _platform.getCurrentPosition(_playerId);
      if (millis == null) return;
      _position = Duration(milliseconds: millis);
      positionChanged.emit(_position);
    });
  }

  @override
  Future<void> pause() async {
    if (_state != PlaybackState.playing) return;
    _setState(PlaybackState.paused);
    await _platform.pause(_playerId);
  }

  @override
  Future<void> resume() async {
    if (_state != PlaybackState.paused) return;
    _setState(PlaybackState.playing);
    await _platform.resume(_playerId);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    await _platform.seek(_playerId, position);
    positionChanged.emit(position);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _positionTimer?.cancel();
    _position = Duration.zero;
    _setState(PlaybackState.stopped);
    if (_created != null) await _platform.stop(_playerId);
  }

  @override
  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    if (_created != null) unawaited(_platform.setVolume(_playerId, _volume));
  }

  /// The TV's player plays one track at a time: each ends with [trackEnded] and the next one opens then.
  @override
  Future<void> setNext(String? audioSource) async {}

  /// The TV's player reads no ReplayGain tags.
  @override
  void setNormalization(VolumeNormalization mode) {}

  void _setState(PlaybackState newState) {
    if (_state == newState) return;
    _state = newState;
    stateChanged.emit(newState);
  }

  @override
  Future<void> dispose() async {
    _positionTimer?.cancel();
    await _events?.cancel();
    if (_created != null) await _platform.dispose(_playerId);
  }
}
