import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:wiretune_core/wiretune_core.dart';

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
  Process? _reservation;
  String? _reservedCard;

  PlaybackState _state = PlaybackState.stopped;
  AudioOutputDevice? _device;
  bool _exclusive = false;
  bool _bitperfect = false;
  double _volume = 1.0;
  int _generation = 0;
  String? _lastError;
  DateTime _lastPositionEvent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  String get driverName => 'libmpv (media_kit)';

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
          isBitperfectSupported: true,
          supportedSampleRates: _rates,
        ),
    ];
  }

  static const _rates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000];

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
          isBitperfectSupported: true,
          supportedSampleRates: _rates,
        );
      case 'wasapi':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: 'WASAPI',
          hardwareCard: description,
          isExclusiveSupported: true,
          isBitperfectSupported: true,
          supportedSampleRates: _rates,
        );
      case 'coreaudio':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: 'Core Audio',
          hardwareCard: description,
          isExclusiveSupported: true,
          isBitperfectSupported: true,
          supportedSampleRates: _rates,
        );
      case 'pipewire' || 'pulse':
        return AudioOutputDevice(
          id: name,
          name: description,
          driverType: output == 'pipewire' ? 'PipeWire' : 'PulseAudio',
          hardwareCard: description,
          supportedSampleRates: _rates,
        );
      default:
        return null;
    }
  }

  @override
  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitperfect}) async {
    _device = device;
    _exclusive = exclusive;
    _bitperfect = bitperfect;
    final native = _player.platform;
    if (native is! NativePlayer) return;

    if (allowDeviceSelection) {
      await _player.setAudioDevice(AudioDevice(device.id, device.name));
      await native.setProperty('audio-exclusive', exclusive ? 'yes' : 'no');
      await _reserveCard(device);
    }

    // Bit-perfect: no gain, no filters, no replay gain, no resampling requested (mpv's `audio-format` is left unset,
    // which keeps the decoder's sample format).
    await native.setProperty('af', '');
    await native.setProperty('replaygain', 'no');
    await native.setProperty('audio-samplerate', '0');
    await native.setProperty('audio-channels', bitperfect ? 'auto' : 'auto-safe');
    await _applyVolume();
  }

  /// On Linux an ALSA hardware device is usually held by PipeWire; `pw-reserve` asks it to let go for as long as
  /// Wiretune uses the card.
  Future<void> _reserveCard(AudioOutputDevice device) async {
    final card = device.id.startsWith('alsa/hw:') ? device.hardwareCard : null;
    if (card == _reservedCard) return;
    _reservation?.kill();
    _reservation = null;
    _reservedCard = null;
    if (card == null || !Platform.isLinux) return;

    final index = _cardIndex(card);
    if (index == null) return;
    try {
      _reservation = await Process.start('pw-reserve', ['-n', 'Audio$index', '-a', 'Wiretune', '-p', '10', '-r']);
      _reservedCard = card;
      unawaited(_reservation!.stdout.drain<void>());
      unawaited(_reservation!.stderr.drain<void>());
      // Give PipeWire a moment to release the device before mpv opens it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } on ProcessException {
      WiretuneLog.debug('MediaKitDriver', 'pw-reserve is not available; the card may be busy if PipeWire holds it.');
    }
  }

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
    final generation = ++_generation;
    _lastError = null;
    _setState(PlaybackState.playing);
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
    _startCheck?.cancel();
    _setState(PlaybackState.stopped);
    _pcm.cancelAndReset();
    await _player.stop();
  }

  @override
  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    unawaited(_applyVolume());
  }

  Future<void> _applyVolume() => _player.setVolume(_bitperfect ? 100 : _volume * 100);

  // ── mpv's reports ──────────────────────────────────────────────────────────────────────────────

  void _onPlaying(bool playing) {
    if (playing && _state == PlaybackState.error) _setState(PlaybackState.playing);
  }

  void _onCompleted(bool completed) {
    if (!completed || _state != PlaybackState.playing) return;
    _generation++;
    _setState(PlaybackState.stopped);
    trackEnded.emit(null);
  }

  void _onPosition(Duration position) {
    final now = DateTime.now();
    if (now.difference(_lastPositionEvent) < const Duration(milliseconds: 150)) return;
    _lastPositionEvent = now;
    positionChanged.emit(position);
  }

  void _onError(String message) {
    _lastError = WiretuneLog.redact(message);
    WiretuneLog.warn('MediaKitDriver', 'mpv: $_lastError');
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
    _generation++;
    _setState(PlaybackState.error);
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
      final playing = _state == PlaybackState.playing && _player.state.playing;
      if (playing && _pcm.tryGetWindow(_player.state.position, _window)) {
        spectrumDataAvailable.emit(_analyzer.processPcm(_window, isPlaying: true));
      } else {
        spectrumDataAvailable.emit(_analyzer.processPcm(_window, isPlaying: false));
      }
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
    _spectrumTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _pcm.dispose();
    _reservation?.kill();
    await _player.dispose();
  }

  /// The output's current device and modes, for diagnostics.
  @override
  String toString() => 'MediaKitAudioDriver(device: ${_device?.id}, exclusive: $_exclusive, bitperfect: $_bitperfect)';
}
