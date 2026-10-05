import 'dart:async';
import 'dart:typed_data';

import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../services/wiretune_log.dart';
import '../util/event.dart';
import '../util/text.dart';
import 'audio_driver.dart';

/// Holds the current track, the output device, the mode switches (exclusive, bit-perfect) and the volume, and gives a
/// platform [AudioDriver] the commands.
///
/// Bit-perfect switches exclusive on; switching exclusive off switches bit-perfect off. If no device supports a mode,
/// the engine says so through [playbackFailed] and the mode stays off. Changing mode or device mid-track restarts the
/// track at the current position.
class WiretuneAudioEngine {
  WiretuneAudioEngine(this._driver, {Future<List<AudioOutputDevice>> Function()? deviceDetector})
    : _detectDevices = deviceDetector ?? _driver.detectDevices {
    _subscriptions.addAll([
      _driver.stateChanged.listen(stateChanged.emit),
      _driver.positionChanged.listen(positionChanged.emit),
      _driver.spectrumDataAvailable.listen(spectrumDataAvailable.emit),
      _driver.trackEnded.listen(trackEnded.emit),
      _driver.playbackFailed.listen(playbackFailed.emit),
    ]);
    _initialDeviceScan = refreshDevices();
  }

  final AudioDriver _driver;
  final Future<List<AudioOutputDevice>> Function() _detectDevices;
  final List<void Function()> _subscriptions = [];
  late final Future<void> _initialDeviceScan;

  List<AudioOutputDevice> _availableDevices = const [];
  Track? _currentTrack;
  AudioOutputDevice? _currentDevice;
  bool _isExclusiveMode = false;
  bool _isBitperfect = false;
  double _volume = 1.0;
  double _volumeBeforeBitperfect = 1.0;
  bool _isMuted = false;
  String? _streamToken;
  Future<String?> Function()? _streamTokenProvider;
  String? Function(Track track)? _offlineCopy;
  bool _disposed = false;

  final Event<PlaybackState> stateChanged = Event<PlaybackState>();
  final Event<Duration> positionChanged = Event<Duration>();
  final Event<Track?> trackChanged = Event<Track?>();
  final Event<bool> bitperfectChanged = Event<bool>();
  final Event<bool> exclusiveModeChanged = Event<bool>();
  final Event<Float32List> spectrumDataAvailable = Event<Float32List>();
  final Event<void> trackEnded = Event<void>();
  final Event<void> devicesChanged = Event<void>();
  final Event<String> playbackFailed = Event<String>();

  AudioDriver get driver => _driver;
  Track? get currentTrack => _currentTrack;
  PlaybackState get state => _driver.state;
  Duration get currentPosition => _driver.currentPosition;
  double get volume => _isBitperfect ? 1.0 : (_isMuted ? 0.0 : _volume);
  bool get isMuted => _isMuted;
  bool get isExclusiveMode => _isExclusiveMode;
  bool get isBitperfect => _isBitperfect;
  AudioOutputDevice? get currentDevice => _currentDevice;
  List<AudioOutputDevice> get availableDevices => _availableDevices;

  /// Waits for the device scan started by the constructor.
  Future<void> get ready => _initialDeviceScan;

  /// The signal path of the current track as the player describes it: what Wiretune requested, not what it measured.
  String get signalPathDescription {
    final track = _currentTrack;
    if (track == null) return Localizer.get('SignalNone');

    final device = _currentDevice?.displayTitle ?? Localizer.get('DefaultOutput');
    final processing = Localizer.get(_isBitperfect ? 'SignalProcessingBitPerfect' : 'SignalProcessingMixer');
    final access = Localizer.get(_isExclusiveMode ? 'SignalAccessExclusive' : 'SignalAccessShared');
    final transport = Localizer.get(
      track.isLocal
          ? 'SignalTransportLocal'
          : (_offlineCopy?.call(track) != null ? 'SignalTransportDownloaded' : 'SignalTransportServer'),
    );

    return [
      Localizer.format('SignalSource', [track.format.tagSpec]),
      Localizer.format('SignalTransport', [transport]),
      Localizer.format('SignalProcessing', [processing]),
      Localizer.format('SignalAccess', [access]),
      Localizer.format('SignalTarget', [device]),
    ].join('\n');
  }

  /// Supplies the token appended to stream URLs. It is asked for each time a server track starts, so a long-running
  /// player always uses a token that is still valid.
  void setStreamTokenProvider(Future<String?> Function()? provider) => _streamTokenProvider = provider;

  /// Supplies the path of a downloaded copy of a server track: a track that has one plays from it, without the server.
  void setOfflineCopyProvider(String? Function(Track track)? provider) => _offlineCopy = provider;

  Future<void> refreshDevices() async {
    List<AudioOutputDevice> devices;
    try {
      devices = await _detectDevices();
    } catch (e) {
      WiretuneLog.warn('AudioEngine', 'Audio device detection failed: $e');
      devices = [];
    }

    _availableDevices = devices;
    final current = _currentDevice;
    _currentDevice = current == null || !devices.any((d) => d.id == current.id)
        ? (devices.where((d) => d.isDefault).firstOrNull ?? devices.firstOrNull)
        : devices.firstWhere((d) => d.id == current.id);

    final device = _currentDevice;
    if (device != null) {
      try {
        await _driver.initialize(device, exclusive: _isExclusiveMode, bitperfect: _isBitperfect);
      } catch (e, s) {
        WiretuneLog.error('AudioEngine', "Initialising output '${device.name}' failed: $e", e, s);
        playbackFailed.emit(Localizer.format('EngineDeviceInitFailed', [device.name, '$e']));
      }
    }
    devicesChanged.emit(null);
  }

  /// Starts [track], at [start] (another device handing its playback over continues where it was).
  Future<void> playTrack(Track track, {Duration start = Duration.zero}) async {
    _currentTrack = track;
    trackChanged.emit(track);

    // A downloaded copy needs no token, and must not wait for a server that may be out of reach.
    if (!track.isLocal && _streamTokenProvider != null && _offlineCopy?.call(track) == null) {
      await _refreshStreamToken();
    }

    final source = resolveSource(track);
    if (source == null || source.isEmpty) {
      playbackFailed.emit(Localizer.format('EngineNoSource', [track.title]));
      return;
    }

    WiretuneLog.info('AudioEngine', "PlayTrack: '${track.artist} - ${track.title}' (${track.format.tagSpec})");
    await _driver.play(source, track.format, start);
  }

  Future<void> pause() => _driver.pause();

  Future<void> resume() => _driver.resume();

  Future<void> stop() {
    _currentTrack = null;
    trackChanged.emit(null);
    return _driver.stop();
  }

  Future<void> seek(Duration position) => _driver.seek(position);

  void setVolume(double volume) {
    if (_isBitperfect) {
      _driver.setVolume(1.0);
      return;
    }
    _volume = volume.clamp(0.0, 1.0);
    _driver.setVolume(_isMuted ? 0.0 : _volume);
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    if (!_isBitperfect) _driver.setVolume(_isMuted ? 0.0 : _volume);
  }

  Future<void> setExclusiveMode(bool enabled) async {
    await _initialDeviceScan;
    if (_isExclusiveMode == enabled) return;

    if (enabled) {
      final exclusiveDevice = _preferredExclusiveDevice();
      if (exclusiveDevice == null) {
        playbackFailed.emit(Localizer.get('EngineNoExclusive'));
        exclusiveModeChanged.emit(false);
        return;
      }
      _currentDevice = exclusiveDevice;
    } else {
      if (_isBitperfect) _disableBitperfect();
      _currentDevice =
          _availableDevices.where((d) => d.isDefault).firstOrNull ?? _availableDevices.firstOrNull ?? _currentDevice;
    }

    _isExclusiveMode = enabled;
    exclusiveModeChanged.emit(enabled);
    await _reinitializeOutput();
  }

  Future<void> setBitperfectMode(bool enabled) async {
    await _initialDeviceScan;
    if (_isBitperfect == enabled) return;

    if (!enabled) {
      _disableBitperfect();
      await _reinitializeOutput();
      return;
    }

    final current = _currentDevice;
    final device = current != null && current.isBitperfectSupported && current.isExclusiveSupported
        ? current
        : _preferredExclusiveDevice(requireBitperfect: true);
    if (device == null) {
      playbackFailed.emit(Localizer.get('EngineNoBitPerfect'));
      bitperfectChanged.emit(false);
      return;
    }

    _currentDevice = device;
    if (!_isExclusiveMode) {
      _isExclusiveMode = true;
      exclusiveModeChanged.emit(true);
    }

    _volumeBeforeBitperfect = _volume;
    _isBitperfect = true;
    _volume = 1.0;
    _driver.setVolume(1.0);
    bitperfectChanged.emit(true);
    await _reinitializeOutput();
  }

  Future<void> setOutputDevice(AudioOutputDevice device) async {
    _currentDevice = device;
    if (!device.isExclusiveSupported && _isExclusiveMode) {
      if (_isBitperfect) _disableBitperfect();
      _isExclusiveMode = false;
      exclusiveModeChanged.emit(false);
    }
    await _reinitializeOutput();
  }

  void _disableBitperfect() {
    _isBitperfect = false;
    _volume = _volumeBeforeBitperfect;
    _driver.setVolume(_isMuted ? 0.0 : _volume);
    bitperfectChanged.emit(false);
  }

  AudioOutputDevice? _preferredExclusiveDevice({bool requireBitperfect = false}) {
    final candidates = _availableDevices
        .where((d) => d.isExclusiveSupported && (!requireBitperfect || d.isBitperfectSupported))
        .toList();
    if (candidates.isEmpty) return null;

    final current = _currentDevice;
    // 1. The current device, when it can do it.
    if (current != null) {
      final match = candidates.where((d) => d.id == current.id).firstOrNull;
      if (match != null) return match;

      // 2. A shared sink (a PipeWire sink, the system default): the hardware device of the same card.
      final sameCard = candidates
          .where(
            (d) =>
                (d.hardwareCard.isNotEmpty && containsIgnoreCase(current.name, d.hardwareCard)) ||
                (current.hardwareCard.isNotEmpty && containsIgnoreCase(d.name, current.hardwareCard)),
          )
          .firstOrNull;
      if (sameCard != null) return sameCard;
    }

    // 3. A USB DAC rather than HDMI or the motherboard's audio.
    final usb = candidates
        .where((d) => containsIgnoreCase(d.name, 'USB') || containsIgnoreCase(d.hardwareCard, 'USB'))
        .firstOrNull;
    if (usb != null) return usb;

    // 4. Any direct hardware device.
    return candidates.where((d) => d.driverType.contains('ALSA') || d.id.contains('hw:')).firstOrNull ??
        candidates.first;
  }

  /// Applies the current device and mode to the driver, and restarts playback in place if a track is playing.
  Future<void> _reinitializeOutput() async {
    final device = _currentDevice;
    if (device == null) return;

    await _driver.initialize(device, exclusive: _isExclusiveMode, bitperfect: _isBitperfect);

    final track = _currentTrack;
    if (track != null && state == PlaybackState.playing) {
      final source = resolveSource(track);
      if (source != null) await _driver.play(source, track.format, currentPosition);
    }
  }

  Future<void> _refreshStreamToken() async {
    try {
      final token = await _streamTokenProvider!();
      _streamToken = token == null || token.isEmpty ? null : token;
    } catch (e) {
      // Keep the token we have: it may still be valid, and if not the server's refusal is reported by playback.
      WiretuneLog.warn('AudioEngine', 'Could not refresh the stream token: $e');
    }
  }

  /// The file path of a local track; for a server track the downloaded copy, or else the stream URL with the stream
  /// token appended.
  String? resolveSource(Track track) {
    final url = track.streamUrl;
    if (url == null || url.isEmpty) return track.filePath.isEmpty ? null : track.filePath;
    final copy = _offlineCopy?.call(track);
    if (copy != null) return copy;
    final token = _streamToken;
    if (token == null) return url;
    return '$url${url.contains('?') ? '&' : '?'}token=${Uri.encodeQueryComponent(token)}';
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final unsubscribe in _subscriptions) {
      unsubscribe();
    }
    await _driver.dispose();
  }
}
