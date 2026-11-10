// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:typed_data';

import '../localization/localizer.dart';
import '../models/library_models.dart';
import '../services/download_service.dart';
import '../services/stream_cache.dart';
import '../services/wiretune_log.dart';
import '../util/event.dart';
import '../util/text.dart';
import 'audio_driver.dart';
import 'equalizer.dart';

/// Holds the current track, the output device, the mode switches (exclusive, bit-perfect) and the volume, and gives a
/// platform [AudioDriver] the commands.
///
/// Bit-perfect switches exclusive on; switching exclusive off switches bit-perfect off. If no device supports a mode,
/// the engine says so through [playbackFailed] and the mode stays off. Changing mode or device mid-track restarts the
/// track at the current position.
class WiretuneAudioEngine {
  WiretuneAudioEngine(this._driver) {
    _subscriptions.addAll([
      _driver.stateChanged.listen(stateChanged.emit),
      _driver.positionChanged.listen(positionChanged.emit),
      _driver.spectrumDataAvailable.listen(spectrumDataAvailable.emit),
      _driver.trackEnded.listen((_) {
        _finishCaching(_currentTrack);
        trackEnded.emit(null);
      }),
      _driver.advanced.listen((_) => _onAdvanced()),
      _driver.playbackFailed.listen(playbackFailed.emit),
    ]);
    _initialDeviceScan = refreshDevices();
  }

  final AudioDriver _driver;
  final List<void Function()> _subscriptions = [];
  late final Future<void> _initialDeviceScan;

  List<AudioOutputDevice> _availableDevices = const [];
  Track? _currentTrack;

  /// What follows the current track without a gap ([setNextTrack]), and what the driver was given for it.
  Track? _nextTrack;
  String? _nextSource;
  AudioOutputDevice? _currentDevice;
  bool _isExclusiveMode = false;
  bool _isBitPerfect = false;
  double _volume = 1.0;
  double _volumeBeforeBitPerfect = 1.0;
  bool _isMuted = false;
  VolumeNormalization _normalization = VolumeNormalization.off;
  String? _streamToken;
  Future<String?> Function()? _streamTokenProvider;
  String? Function(Track track)? _offlineCopy;
  StreamCache? _streamCache;
  bool _disposed = false;

  // Counts the requests to play or stop: a track whose start waited for a stream token is not started once another
  // request came meanwhile (a downloaded track skipped to needs no token, and would otherwise start first).
  int _request = 0;

  final Event<PlaybackState> stateChanged = Event<PlaybackState>();
  final Event<Duration> positionChanged = Event<Duration>();
  final Event<Track?> trackChanged = Event<Track?>();
  final Event<bool> bitPerfectChanged = Event<bool>();
  final Event<bool> exclusiveModeChanged = Event<bool>();
  final Event<Float32List> spectrumDataAvailable = Event<Float32List>();
  final Event<void> trackEnded = Event<void>();

  /// The track ended and the one given to [setNextTrack] took over without a gap (it is in [trackChanged] too).
  final Event<Track> advanced = Event<Track>();
  final Event<void> devicesChanged = Event<void>();
  final Event<String> playbackFailed = Event<String>();

  /// The output of the track playing now was read ([measuredOutput] has it).
  final Event<void> outputMeasured = Event<void>();

  AudioDriver get driver => _driver;
  Track? get currentTrack => _currentTrack;
  PlaybackState get state => _driver.state;
  Duration get currentPosition => _driver.currentPosition;
  double get volume => _isBitPerfect ? 1.0 : (_isMuted ? 0.0 : _volume);
  bool get isMuted => _isMuted;
  bool get isExclusiveMode => _isExclusiveMode;
  bool get isBitPerfect => _isBitPerfect;

  /// How much of a server track is asked for; bit-perfect output always plays the file.
  StreamingQuality get streamingQuality => _streamingQuality;
  StreamingQuality _streamingQuality = StreamingQuality.original;

  /// From the next track on: the one playing goes on as it is.
  Future<void> setStreamingQuality(StreamingQuality quality) async {
    if (quality == _streamingQuality) return;
    _streamingQuality = quality;
    _nextSource = null;
    await _offerNext(); // the next track is handed over again, as the new quality
  }

  /// Whether the server is asked to convert [track]: not for a download, a local file, bit-perfect output or a lossy
  /// file that is at or below the bitrate already (the server sends such a file as it is).
  bool isConverted(Track track) {
    final kbps = _streamingQuality.kbps;
    if (kbps == 0 || _isBitPerfect || !streams(track)) return false;
    return track.format.isLossless || track.format.bitrateKbps > kbps;
  }

  /// The chosen volume normalization; bit-perfect output skips it.
  VolumeNormalization get normalization => _normalization;
  AudioOutputDevice? get currentDevice => _currentDevice;
  List<AudioOutputDevice> get availableDevices => _availableDevices;

  /// Waits for the device scan started by the constructor.
  Future<void> get ready => _initialDeviceScan;

  /// What the output was opened with for the current track, read from the player once it plays; null before that, or
  /// when the driver can't tell.
  AudioOutputInfo? get measuredOutput => _measuredOutput;
  AudioOutputInfo? _measuredOutput;

  /// Reads what the driver opened for [request]'s track, once it has: the output opens a moment after playing starts.
  Future<void> _measureOutput(int request) async {
    _measuredOutput = null;
    if (!_driver.reportsOutput) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      if (request != _request || _disposed) return;
      if (_driver.state == PlaybackState.playing) {
        final info = await _driver.readOutput();
        if (request != _request || _disposed) return;
        if (info != null) {
          _measuredOutput = info;
          outputMeasured.emit(null);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// The line that says what the output really is, and whether that is what the file holds: a rate or a bit depth
  /// that changed on the way is said, so "bit-perfect" is not taken on trust.
  String? _outputLine(Track track) {
    final output = _measuredOutput;
    if (output == null) return null;
    final bits = output.bitsPerSample;
    final channels = output.channels;
    final parts = [
      '${_kilohertz(output.sampleRate)} kHz',
      output.sampleFormat,
      if (channels != null) Localizer.format('SignalChannels', [channels]),
      if (output.backend != null) output.backend!,
    ];
    final format = track.format;
    final notes = <String>[];
    if (format.isLossless) {
      if (format.sampleRate > 0 && format.sampleRate != output.sampleRate) {
        notes.add(Localizer.format('SignalOutputResampled', [_kilohertz(format.sampleRate)]));
      }
      if (bits != null && format.bitsPerSample > bits) notes.add(Localizer.get('SignalOutputShallower'));
    }
    final line = Localizer.format('SignalOutput', [parts.join(', ')]);
    return notes.isEmpty ? line : '$line – ${notes.join(', ')}';
  }

  static String _kilohertz(int rate) {
    final text = (rate / 1000.0).toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  /// The signal path of the current track as the player describes it: what Wiretune requested, and below it, once the
  /// output is open, what the player says it opened.
  String get signalPathDescription {
    final track = _currentTrack;
    if (track == null) return Localizer.get('SignalNone');

    final isLossless = track.format.isLossless;
    final device = _currentDevice?.displayTitle ?? Localizer.get('DefaultOutput');
    var processing = Localizer.get(
      _isBitPerfect
          ? (isLossless ? 'SignalProcessingBitPerfect' : 'SignalProcessingBitPerfectLossy')
          : 'SignalProcessingMixer',
    );
    if (!_isBitPerfect && _normalization != VolumeNormalization.off) {
      processing = Localizer.format('SignalProcessingNormalized', [
        processing,
        Localizer.get(_normalization == VolumeNormalization.album ? 'NormalizationAlbum' : 'NormalizationTrack'),
      ]);
    }
    if (!_isBitPerfect && !_equalizer.isFlat) {
      processing = Localizer.format('SignalProcessingEqualizer', [processing]);
    }
    final access = Localizer.get(_isExclusiveMode ? 'SignalAccessExclusive' : 'SignalAccessShared');
    final transport = isConverted(track)
        ? Localizer.format('SignalTransportServerConverted', [_streamingQuality.kbps])
        : Localizer.get(
            track.isLocal
                ? 'SignalTransportLocal'
                : (!streams(track)
                      ? 'SignalTransportDownloaded'
                      : (isLossless ? 'SignalTransportServer' : 'SignalTransportServerLossy')),
          );

    return [
      Localizer.format('SignalSource', [track.format.tagSpec]),
      Localizer.format('SignalTransport', [transport]),
      Localizer.format('SignalProcessing', [processing]),
      Localizer.format('SignalAccess', [access]),
      Localizer.format('SignalTarget', [device]),
      ?_outputLine(track),
    ].join('\n');
  }

  /// Supplies the token appended to stream URLs. It is asked for each time a server track starts, so a long-running
  /// player always uses a token that is still valid.
  void setStreamTokenProvider(Future<String?> Function()? provider) => _streamTokenProvider = provider;

  /// Supplies the path of a downloaded copy of a server track: a track that has one plays from it, without the server.
  void setOfflineCopyProvider(String? Function(Track track)? provider) => _offlineCopy = provider;

  /// Server tracks stream through [cache], which keeps them for the next time.
  void setStreamCache(StreamCache? cache) => _streamCache = cache;

  /// Whether [track] comes over the network now: it [streams], and the [StreamCache] hasn't kept it yet.
  bool fetches(Track track) =>
      streams(track) && !(_streamCache?.has(cacheKey(track, _converted(track)), _cacheExtension(track)) ?? false);

  StreamingQuality? _converted(Track track) => isConverted(track) ? _streamingQuality : null;

  /// The kept file's extension: Opus for a conversion, else the track's own format's.
  String _cacheExtension(Track track) => isConverted(track) ? 'opus' : DownloadService.extensionOf(track.format.codec);

  /// Whether [track] plays over the network: a server track without a downloaded copy.
  bool streams(Track track) => !track.isLocal && _offlineCopy?.call(track) == null;

  Future<void> refreshDevices() async {
    List<AudioOutputDevice> devices;
    try {
      devices = await _driver.detectDevices();
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
    // The device a mode was set up on may be gone (a DAC unplugged): the default one that takes its place must not be
    // reported as exclusive or bit-perfect.
    if (device != null) _dropModesTheDeviceLacks(device);
    if (device != null) {
      try {
        await _driver.initialize(device, exclusive: _isExclusiveMode, bitPerfect: _isBitPerfect);
      } catch (e, s) {
        WiretuneLog.error('AudioEngine', "Initialising output '${device.name}' failed: $e", e, s);
        playbackFailed.emit(Localizer.format('EngineDeviceInitFailed', [device.name, '$e']));
      }
    }
    devicesChanged.emit(null);
  }

  /// Starts [track], at [start] (another device handing its playback over continues where it was).
  Future<void> playTrack(Track track, {Duration start = Duration.zero}) async {
    final request = ++_request;
    _currentTrack = track;
    trackChanged.emit(track);

    // A downloaded copy needs no token, and must not wait for a server that may be out of reach.
    if (_streamTokenProvider != null && streams(track)) {
      await _refreshStreamToken();
      if (request != _request || _disposed) return;
    }

    final source = _resolveSource(track);
    if (source == null || source.isEmpty) {
      playbackFailed.emit(Localizer.format('EngineNoSource', [track.title]));
      return;
    }

    WiretuneLog.info('AudioEngine', "PlayTrack: '${track.artist} - ${track.title}' (${track.format.tagSpec})");
    await _driver.play(source, track.format, start);
    // The driver forgot the next track: it is given again for this one.
    _nextSource = null;
    if (request == _request) unawaited(_measureOutput(request));
    if (request == _request) await _offerNext();
  }

  /// Has [track] start right when the current one ends, without a gap (the driver permitting); null for nothing. It
  /// stays until changed, also across new tracks: the player keeps it up to date.
  Future<void> setNextTrack(Track? track) async {
    _nextTrack = track;
    await _offerNext();
  }

  Future<void> _offerNext() async {
    final track = _nextTrack;
    if (track != null && _streamTokenProvider != null && streams(track)) {
      await _refreshStreamToken();
      if (_disposed || !identical(track, _nextTrack)) return;
    }
    final source = track == null ? null : _resolveSource(track);
    if (source == _nextSource) return;
    _nextSource = source;
    await _driver.setNext(source);
  }

  /// [track] played to its end: the cache fills in what jumps in it skipped, and keeps it.
  void _finishCaching(Track? track) {
    final cache = _streamCache;
    if (track == null || cache == null || !streams(track)) return;
    unawaited(cache.finish(cacheKey(track, _converted(track)), _cacheExtension(track)));
  }

  void _onAdvanced() {
    final track = _nextTrack;
    if (track == null) return;
    _finishCaching(_currentTrack);
    _request++;
    _currentTrack = track;
    _nextTrack = null;
    _nextSource = null;
    WiretuneLog.info('AudioEngine', "Gapless: '${track.artist} - ${track.title}' (${track.format.tagSpec})");
    unawaited(_measureOutput(_request));
    trackChanged.emit(track);
    advanced.emit(track);
  }

  Future<void> pause() => _driver.pause();

  Future<void> resume() => _driver.resume();

  Future<void> stop() {
    _request++;
    _currentTrack = null;
    _measuredOutput = null;
    trackChanged.emit(null);
    return _driver.stop();
  }

  Future<void> seek(Duration position) => _driver.seek(position);

  void setVolume(double volume) {
    if (_isBitPerfect) {
      _driver.setVolume(1.0);
      return;
    }
    _volume = volume.clamp(0.0, 1.0);
    _driver.setVolume(_isMuted ? 0.0 : _volume);
  }

  void setNormalization(VolumeNormalization mode) {
    _normalization = mode;
    _driver.setNormalization(mode);
  }

  /// The equalizer; bit-perfect output never uses it (the driver plays flat then).
  Equalizer get equalizer => _equalizer;
  Equalizer _equalizer = Equalizer.flat();

  /// Tells the driver whether a spectrum is on screen ([AudioDriver.spectrumShown]).
  set spectrumShown(bool shown) => _driver.spectrumShown = shown;

  void setEqualizer(Equalizer equalizer) {
    _equalizer = equalizer;
    _driver.setEqualizer(equalizer);
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    if (!_isBitPerfect) _driver.setVolume(_isMuted ? 0.0 : _volume);
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
      if (_isBitPerfect) _disableBitPerfect();
      _currentDevice =
          _availableDevices.where((d) => d.isDefault).firstOrNull ?? _availableDevices.firstOrNull ?? _currentDevice;
    }

    _isExclusiveMode = enabled;
    exclusiveModeChanged.emit(enabled);
    await _reinitializeOutput();
  }

  Future<void> setBitPerfectMode(bool enabled) async {
    await _initialDeviceScan;
    if (_isBitPerfect == enabled) return;

    if (!enabled) {
      _disableBitPerfect();
      await _reinitializeOutput();
      return;
    }

    final current = _currentDevice;
    final device = current != null && current.isBitPerfectSupported && current.isExclusiveSupported
        ? current
        : _preferredExclusiveDevice(requireBitPerfect: true);
    if (device == null) {
      playbackFailed.emit(Localizer.get('EngineNoBitPerfect'));
      bitPerfectChanged.emit(false);
      return;
    }

    _currentDevice = device;
    if (!_isExclusiveMode) {
      _isExclusiveMode = true;
      exclusiveModeChanged.emit(true);
    }

    _volumeBeforeBitPerfect = _volume;
    _isBitPerfect = true;
    _volume = 1.0;
    _driver.setVolume(1.0);
    bitPerfectChanged.emit(true);
    await _reinitializeOutput();
  }

  Future<void> setOutputDevice(AudioOutputDevice device) async {
    _currentDevice = device;
    _dropModesTheDeviceLacks(device);
    await _reinitializeOutput();
  }

  void _dropModesTheDeviceLacks(AudioOutputDevice device) {
    if (_isBitPerfect && !(device.isBitPerfectSupported && device.isExclusiveSupported)) _disableBitPerfect();
    if (_isExclusiveMode && !device.isExclusiveSupported) {
      _isExclusiveMode = false;
      exclusiveModeChanged.emit(false);
    }
  }

  void _disableBitPerfect() {
    _isBitPerfect = false;
    _volume = _volumeBeforeBitPerfect;
    _driver.setVolume(_isMuted ? 0.0 : _volume);
    bitPerfectChanged.emit(false);
  }

  AudioOutputDevice? _preferredExclusiveDevice({bool requireBitPerfect = false}) {
    final candidates = _availableDevices
        .where((d) => d.isExclusiveSupported && (!requireBitPerfect || d.isBitPerfectSupported))
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

    await _driver.initialize(device, exclusive: _isExclusiveMode, bitPerfect: _isBitPerfect);

    final track = _currentTrack;
    if (track != null && state == PlaybackState.playing) {
      final source = _resolveSource(track);
      if (source != null) {
        await _driver.play(source, track.format, currentPosition);
        _nextSource = null;
        unawaited(_measureOutput(_request));
        await _offerNext();
      }
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
  /// token appended (through the [StreamCache], which gives its kept copy once it has one).
  String? _resolveSource(Track track) {
    final url = track.streamUrl;
    if (url == null || url.isEmpty) return track.filePath.isEmpty ? null : track.filePath;
    final copy = _offlineCopy?.call(track);
    if (copy != null) return copy;
    final token = _streamToken;
    final converted = isConverted(track);
    final convert = converted ? 'format=opus&bitrate=${_streamingQuality.kbps}' : null;
    final query = [?convert, if (token != null) 'token=${Uri.encodeQueryComponent(token)}'];
    final upstream = query.isEmpty ? url : '$url${url.contains('?') ? '&' : '?'}${query.join('&')}';
    return _streamCache?.sourceFor(cacheKey(track, _converted(track)), _cacheExtension(track), upstream) ?? upstream;
  }

  /// What a server track is kept as in the [StreamCache]: the track, its file's size and time (a changed file is
  /// another), and the quality it was converted to, if it was.
  static String cacheKey(Track track, StreamingQuality? converted) => [
    track.id,
    track.fileSizeBytes,
    track.fileModifiedAt?.millisecondsSinceEpoch ?? 0,
    if (converted != null) 'opus${converted.kbps}',
  ].join('-');

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final unsubscribe in _subscriptions) {
      unsubscribe();
    }
    await _driver.dispose();
  }
}
