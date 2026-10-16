// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:wiretune_core/wiretune_core.dart' hide Playlist;

import 'device_reservation.dart';

/// Plays through libmpv (media_kit), which decodes with FFmpeg: FLAC, ALAC, APE, WavPack, DSD, Opus and the rest play
/// the same on every platform.
///
/// On the desktop the device list comes from mpv: ALSA hardware devices (`hw:`) on Linux, WASAPI endpoints on Windows
/// and Core Audio devices on macOS can be opened exclusively. Bit-perfect is exclusive access, the volume at 100 %, no
/// filters and no resampling requested; whether the device then gets the samples untouched depends on its driver.
class MediaKitAudioDriver with AudioDriverEvents implements AudioDriver {
  MediaKitAudioDriver({required this.allowDeviceSelection, required this.enableSpectrum}) {
    _subscriptions.addAll([
      _player.stream.playing.listen(_onPlaying),
      _player.stream.completed.listen(_onCompleted),
      _player.stream.playlist.listen(_onPlaylist),
      _player.stream.position.listen(_onPosition),
      _player.stream.error.listen(_onError),
      _player.stream.log.listen(_onLog),
    ]);
  }

  /// Whether the user may pick an output (desktop); phones and TVs play to the system's output.
  final bool allowDeviceSelection;

  /// Whether to run the spectrum analyser (it needs `ffmpeg` on the PATH; desktop only).
  final bool enableSpectrum;

  final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'Wiretune',
      logLevel: MPVLogLevel.warn,
      bufferSize: 64 * 1024 * 1024,
    ),
  );
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final SpectrumAnalyzer _analyzer = SpectrumAnalyzer();
  final PcmCache _pcm = PcmCache();
  final Float32List _window = Float32List(SpectrumAnalyzer.fftSize);
  Timer? _spectrumTimer;
  Timer? _startCheck;
  Timer? _endCheck;
  Timer? _releaseTimer;
  final ExclusiveCardHolder _card = ExclusiveCardHolder();
  // One output change at a time, applied in the order asked: the device, the exclusive switch and the card claim of
  // one change are never mixed with those of another.
  final AsyncLock _output = AsyncLock();
  // The next track's entry in mpv's playlist: added, replaced and the finished one taken out one at a time.
  final AsyncLock _queue = AsyncLock();

  /// The entry after the current one in mpv's playlist ([setNext]) and its source; mpv opens it ahead and moves on to it
  /// gaplessly.
  (Media, String)? _next;

  /// The entry mpv went on to, until it plays (its first position) or turns out unplayable (an error).
  (Media, String)? _arriving;
  AudioOutputDevice? _configuredDevice;
  bool _exclusive = false;

  PlaybackState _state = PlaybackState.stopped;
  bool _bitPerfect = false;
  double _volume = 1.0;
  VolumeNormalization _normalization = VolumeNormalization.off;
  int _generation = 0;
  String? _lastError;
  DateTime _lastPositionEvent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  PlaybackState get state => _state;

  @override
  Duration get currentPosition => _player.state.position;

  // ── Devices ────────────────────────────────────────────────────────────────────────────────────

  @override
  Future<List<AudioOutputDevice>> detectDevices() async {
    const systemDefault = AudioOutputDevice(
      id: 'auto',
      nameKey: 'AudioSystemDefaultOutput',
      driverType: 'System',
      isDefault: true,
    );
    if (!allowDeviceSelection) return const [systemDefault];

    var devices = _player.state.audioDevices;
    if (devices.length <= 1) {
      // mpv fills the list a moment after it starts.
      try {
        devices = await _player.stream.audioDevices
            .firstWhere((list) => list.length > 1)
            .timeout(const Duration(seconds: 3));
      } on TimeoutException {
        devices = _player.state.audioDevices;
      }
    }

    final result = <AudioOutputDevice>[systemDefault];
    // PipeWire also answers as PulseAudio; its outputs would appear twice.
    final pipewire = devices.any((d) => d.name.startsWith('pipewire/'));
    for (final device in devices) {
      if (pipewire && device.name.startsWith('pulse/')) continue;
      final mapped = _describe(device);
      if (mapped != null) result.add(mapped);
    }
    // mpv often lists only the sound server's outputs. The ALSA hardware devices (the ones exclusive and bit-perfect
    // need) are added from `aplay -l`, or from /proc/asound when aplay is not installed.
    if (Platform.isLinux && !result.any((d) => d.driverType == 'ALSA Direct')) {
      result.addAll(await _alsaHardwareDevices());
    }
    return result;
  }

  static final RegExp _aplayLine = RegExp(
    r'card\s+(\d+):\s+[^\[]+\[([^\]]+)\],\s+device\s+(\d+):\s+[^\[]+\[([^\]]+)\]',
  );

  /// The playback devices in the output of `aplay -l`: card and device number, card name and device name.
  @visibleForTesting
  static List<(String card, String device, String cardName, String deviceName)> parseAplayList(String output) => [
    for (final m in _aplayLine.allMatches(output)) (m[1]!, m[3]!, m[2]!.trim(), m[4]!.trim()),
  ];

  /// The ALSA playback devices of the machine, as "ALSA: card (device)", opened by mpv as `alsa/hw:card,device`.
  static Future<List<AudioOutputDevice>> _alsaHardwareDevices() async {
    final found = <(String card, String device, String cardName, String deviceName)>[];
    try {
      final aplay = await Process.run('aplay', ['-l']).timeout(const Duration(seconds: 3));
      found.addAll(parseAplayList('${aplay.stdout}'));
    } catch (_) {
      // No aplay: read the kernel's list instead.
      try {
        final names = <String, String>{};
        for (final line in File('/proc/asound/cards').readAsLinesSync()) {
          final m = RegExp(r'^\s*(\d+)\s+\[[^\]]+\]:\s+.*?-\s+(.+)$').firstMatch(line);
          if (m != null) names[m[1]!] = m[2]!.trim();
        }
        for (final line in File('/proc/asound/pcm').readAsLinesSync()) {
          final m = RegExp(r'^(\d+)-(\d+):\s+[^:]*:\s+([^:]*):.*playback').firstMatch(line);
          if (m == null) continue;
          final card = int.parse(m[1]!).toString();
          final device = int.parse(m[2]!).toString();
          found.add((card, device, names[card] ?? 'Card $card', m[3]!.trim()));
        }
      } catch (_) {}
    }
    return [
      for (final (card, device, cardName, deviceName) in found)
        AudioOutputDevice(
          id: 'alsa/hw:$card,$device',
          name: cardName.toLowerCase() == deviceName.toLowerCase()
              ? 'ALSA: $cardName'
              : 'ALSA: $cardName ($deviceName)',
          driverType: 'ALSA Direct',
          hardwareCard: card,
          isExclusiveSupported: true,
          isBitPerfectSupported: true,
        ),
    ];
  }

  /// What a device of mpv's list is, or null for entries that only repeat what "auto" already offers.
  static AudioOutputDevice? _describe(AudioDevice device) {
    final name = device.name;
    final slash = name.indexOf('/');
    if (slash <= 0) return null; // "auto", "pipewire", "alsa", "pulse", "jack" ...: the system default again
    final output = name.substring(0, slash);
    final target = name.substring(slash + 1);
    final description = device.description.trim().isEmpty ? target : device.description.trim();

    switch (output) {
      case 'alsa':
        // Only the raw hardware devices: they bypass the sound server and can be held exclusively.
        if (!target.startsWith('hw:')) return null;
        final card = RegExp(r'CARD=([^,]+)').firstMatch(target)?.group(1) ?? target;
        return AudioOutputDevice(
          id: name,
          name: 'ALSA: $description',
          driverType: 'ALSA Direct',
          hardwareCard: card,
          isExclusiveSupported: true,
          isBitPerfectSupported: true,
        );
      case 'wasapi':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: 'WASAPI',
          hardwareCard: description,
          isExclusiveSupported: true,
          isBitPerfectSupported: true,
        );
      case 'coreaudio':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: 'Core Audio',
          hardwareCard: description,
          isExclusiveSupported: true,
          isBitPerfectSupported: true,
        );
      case 'pipewire' || 'pulse':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: output == 'pipewire' ? 'PipeWire' : 'PulseAudio',
          hardwareCard: description,
        );
      default:
        return null;
    }
  }

  @override
  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitPerfect}) =>
      _output.synchronized(() async {
        _bitPerfect = bitPerfect;
        _configuredDevice = device;
        _exclusive = exclusive;
        final native = _player.platform;
        if (native is! NativePlayer) return;

        if (allowDeviceSelection) {
          // The sound server lets go of the card before mpv opens it, and gets it back only once mpv has let go. While
          // nothing plays the card stays with the sound server: playing claims it.
          final card = exclusive ? _cardOf(device) : null;
          final inUse = _state == PlaybackState.playing || _state == PlaybackState.paused;
          if (card != null && inUse) await _card.hold(card);
          await _player.setAudioDevice(AudioDevice(device.id, device.name));
          await native.setProperty('audio-exclusive', exclusive ? 'yes' : 'no');
          if (_card.card != card) await _card.release();
        }

        // Bit-perfect: no gain, no filters, no replay gain, no resampling requested (mpv's `audio-format` is left
        // unset, which keeps the decoder's sample format).
        await native.setProperty('af', '');
        await _applyNormalization();
        // The next track is opened before the current one ends, and plays on the output as it is when its format is the
        // same (otherwise the output is set up again, with a short gap).
        await native.setProperty('prefetch-playlist', 'yes');
        await native.setProperty('gapless-audio', 'weak');
        await native.setProperty('audio-samplerate', '0');
        await native.setProperty('audio-channels', bitPerfect ? 'auto' : 'auto-safe');
        await _applyVolume();
      });

  /// On Linux an ALSA hardware device is usually held by the sound server (PipeWire, PulseAudio); claiming the card
  /// ([ExclusiveCardHolder]) asks it to let go for as long as Wiretune plays exclusively, and the card goes back to it
  /// however Wiretune ends. Null for every other device.
  int? _cardOf(AudioOutputDevice device) =>
      Platform.isLinux && device.id.startsWith('alsa/hw:') ? _cardIndex(device.hardwareCard) : null;

  /// Claims the card of the configured device when exclusive playback is about to use it.
  Future<void> _claimCard() => _output.synchronized(() async {
    final device = _configuredDevice;
    final card = allowDeviceSelection && _exclusive && device != null ? _cardOf(device) : null;
    if (card != null) await _card.hold(card);
  });

  /// The index of the ALSA card with the given short name, from /proc/asound/cards (" 2 [AUDIO  ]: ...").
  static int? _cardIndex(String card) {
    try {
      for (final line in File('/proc/asound/cards').readAsLinesSync()) {
        final match = RegExp(r'^\s*(\d+)\s+\[([^\]]+)\]').firstMatch(line);
        if (match != null && match.group(2)!.trim() == card) return int.parse(match.group(1)!);
      }
    } catch (_) {}
    return int.tryParse(card);
  }

  // ── Transport ──────────────────────────────────────────────────────────────────────────────────

  @override
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition) async {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    final generation = ++_generation;
    _lastError = null;
    _next = null;
    _arriving = null;
    _endCheck?.cancel();
    _setState(PlaybackState.playing);
    await _claimCard();
    if (generation != _generation) return;
    try {
      await _player.open(Media(audioSource, start: startPosition > Duration.zero ? startPosition : null), play: true);
    } catch (e) {
      // Do not stay in "playing" when the source could not even be opened.
      if (generation == _generation) _fail(WiretuneLog.redact('$e'));
      return;
    }
    if (generation != _generation) return;
    await _applyVolume();

    // A source that cannot be opened leaves mpv idle, sometimes without a clear error: check that playback started.
    _startCheck?.cancel();
    _startCheck = Timer(const Duration(seconds: 3), () {
      if (generation != _generation || _state != PlaybackState.playing) return;
      if (!_player.state.playing && !_player.state.completed && _player.state.position == Duration.zero) {
        _fail(_lastError);
      }
    });

    if (enableSpectrum) {
      unawaited(_pcm.loadTrack(audioSource));
      _startSpectrum();
    }
  }

  @override
  Future<void> pause() async {
    if (_state != PlaybackState.playing) return;
    _setState(PlaybackState.paused);
    await _player.pause();
  }

  @override
  Future<void> resume() async {
    if (_state != PlaybackState.paused) return;
    _setState(PlaybackState.playing);
    await _player.play();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position < Duration.zero ? Duration.zero : position);
    positionChanged.emit(position);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _next = null;
    _arriving = null;
    _startCheck?.cancel();
    _endCheck?.cancel();
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _setState(PlaybackState.stopped);
    _pcm.cancelAndReset();
    await _player.stop();
    await _card.release();
  }

  @override
  Future<void> setNext(String? audioSource) => _queue.synchronized(() async {
    final playlist = _player.state.playlist;
    _next = null;
    for (var i = playlist.medias.length - 1; i > playlist.index; i--) {
      await _player.remove(i);
    }
    // Stopped, the next play opens a playlist of its own; the engine gives the next track again then.
    if (audioSource == null || _state == PlaybackState.stopped || _state == PlaybackState.error) return;
    final media = Media(audioSource);
    _next = (media, audioSource);
    await _player.add(media);
  });

  /// mpv went on to the next entry; it is the current track once it plays.
  void _onPlaylist(Playlist playlist) {
    final next = _next;
    if (next == null || playlist.index < 1 || playlist.medias.elementAtOrNull(playlist.index)?.uri != next.$1.uri) {
      return;
    }
    _next = null;
    _arriving = next;
  }

  /// The next entry plays: it is the current track now, and the finished one leaves the playlist.
  void _arrived() {
    final (_, source) = _arriving!;
    _arriving = null;
    _generation++;
    unawaited(
      _queue.synchronized(() async {
        for (var i = _player.state.playlist.index - 1; i >= 0; i--) {
          await _player.remove(i);
        }
      }),
    );
    if (enableSpectrum) unawaited(_pcm.loadTrack(source));
    advanced.emit(null);
  }

  @override
  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    unawaited(_applyVolume());
  }

  @override
  void setNormalization(VolumeNormalization mode) {
    _normalization = mode;
    unawaited(_output.synchronized(_applyNormalization));
  }

  /// mpv's ReplayGain is a gain on its software volume (clipping prevented, a file without the tags plays unchanged),
  /// so it is left off for bit-perfect output.
  Future<void> _applyNormalization() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    final mode = _bitPerfect ? VolumeNormalization.off : _normalization;
    await native.setProperty('replaygain', mode == VolumeNormalization.off ? 'no' : mode.name);
  }

  Future<void> _applyVolume() => _player.setVolume(_bitPerfect ? 100 : _volume * 100);

  // ── mpv's reports ──────────────────────────────────────────────────────────────────────────────

  void _onPlaying(bool playing) {
    if (playing && _state == PlaybackState.error) _setState(PlaybackState.playing);
  }

  void _onCompleted(bool completed) {
    if (!completed || _state != PlaybackState.playing) return;
    // mpv reports the end of each file, also on its way to the next entry: that one plays on ([_onPlaylist] tells),
    // unless it can't be opened, which ends the playback after all.
    if (_next != null) {
      final generation = _generation;
      _endCheck?.cancel();
      _endCheck = Timer(const Duration(seconds: 2), () {
        if (generation == _generation && _arriving == null && _state == PlaybackState.playing) _end();
      });
      return;
    }
    _end();
  }

  void _end() {
    _endCheck?.cancel();
    _generation++;
    _setState(PlaybackState.stopped);
    _releaseTimer?.cancel();
    // The next track usually starts at once and keeps the card; when none does, the sound server gets it back.
    _releaseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_state != PlaybackState.playing) unawaited(_card.release());
    });
    trackEnded.emit(null);
  }

  void _onPosition(Duration position) {
    // The next entry's first position (the finished one's last ones are near its end).
    if (_arriving != null && position > Duration.zero && position < const Duration(seconds: 2)) _arrived();
    final now = DateTime.now();
    if (now.difference(_lastPositionEvent) < const Duration(milliseconds: 150)) return;
    _lastPositionEvent = now;
    positionChanged.emit(position);
  }

  void _onError(String message) {
    _lastError = WiretuneLog.redact(message);
    WiretuneLog.warn('MediaKitDriver', 'mpv: $_lastError');
    // The next entry can't be played: playback stops there with the error, as when a track is started that can't be.
    if (_arriving != null) {
      _arriving = null;
      _fail(_lastError);
      return;
    }
    // An error before anything was heard means the track cannot be played; later ones are glitches mpv recovers from.
    if (_state == PlaybackState.playing && _player.state.position == Duration.zero && !_player.state.playing) {
      final generation = _generation;
      Timer(const Duration(milliseconds: 500), () {
        if (generation == _generation && _state == PlaybackState.playing && !_player.state.playing) _fail(_lastError);
      });
    }
  }

  void _onLog(PlayerLog log) {
    if (log.level == 'error' || log.level == 'fatal') {
      WiretuneLog.debug('MediaKitDriver', '[${log.prefix}] ${log.text}');
    }
  }

  void _fail(String? message) {
    final generation = ++_generation;
    _setState(PlaybackState.error);
    // A track that could not play must not keep the device: mpv lets go of it, then the sound server gets the card.
    unawaited(() async {
      try {
        await _player.stop();
      } catch (_) {}
      if (generation == _generation) await _card.release();
    }());
    playbackFailed.emit(
      message == null || message.isEmpty
          ? Localizer.format('DriverCannotStart', [Localizer.get('Unknown')])
          : Localizer.format('DriverPlaybackFailed', [message]),
    );
  }

  void _setState(PlaybackState newState) {
    if (_state == newState) return;
    _state = newState;
    stateChanged.emit(newState);
    if (newState != PlaybackState.playing) _stopSpectrumSoon();
  }

  // ── Spectrum ───────────────────────────────────────────────────────────────────────────────────

  void _startSpectrum() {
    _spectrumTimer?.cancel();
    _spectrumTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      // Without decoded audio for the position the bars fall, as they do when playback stops.
      final live =
          _state == PlaybackState.playing &&
          _player.state.playing &&
          _pcm.tryGetWindow(_player.state.position, _window);
      spectrumDataAvailable.emit(_analyzer.processPcm(_window, isPlaying: live));
    });
  }

  void _stopSpectrumSoon() {
    // Let the bars fall for a moment, then stop the timer.
    final timer = _spectrumTimer;
    if (timer == null) return;
    Timer(const Duration(milliseconds: 900), () {
      if (_state != PlaybackState.playing && identical(_spectrumTimer, timer)) {
        timer.cancel();
        _spectrumTimer = null;
      }
    });
  }

  @override
  Future<void> dispose() async {
    _startCheck?.cancel();
    _endCheck?.cancel();
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _spectrumTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _pcm.dispose();
    await _player.dispose();
    await _card.release();
  }
}
