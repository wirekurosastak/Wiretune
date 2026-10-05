// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/wiretune_log.dart';

/// The current track decoded to 16-bit mono 44.1 kHz PCM in memory, by a separate `ffmpeg` process, so the spectrum
/// analyser can read the window at the playback position. It never touches the audio that is being played.
///
/// Decoding stops after 20 minutes of audio (about 106 MB), so a very long mix cannot exhaust memory. A server track is
/// requested from the server a second time for this.
class PcmCache {
  static const int sampleRate = 44100;
  static const int _maxSamples = sampleRate * 60 * 20;

  Int16List _samples = Int16List(0);
  int _sampleCount = 0;
  Process? _process;
  StreamSubscription<List<int>>? _subscription;
  String? _currentSource;
  int _generation = 0;
  int _pendingByte = -1;

  /// Whether ffmpeg was found; false after a start failed, so playback does not try again for every track.
  static bool? _available;

  /// Starts decoding [audioSource] in the background (a file path or a stream URL).
  Future<void> loadTrack(String audioSource) async {
    if (_currentSource == audioSource && _sampleCount > 0) return;
    cancelAndReset();
    if (_available == false) return;

    _currentSource = audioSource;
    final generation = ++_generation;
    _samples = Int16List(sampleRate * 180); // three minutes; grows on demand
    _sampleCount = 0;
    _pendingByte = -1;

    Process process;
    try {
      // Arguments as a list (no shell): file names may contain quotes and must never become options.
      process = await Process.start('ffmpeg', [
        '-nostdin',
        '-loglevel',
        'error',
        '-i',
        audioSource,
        '-f',
        's16le',
        '-ac',
        '1',
        '-ar',
        '$sampleRate',
        '-vn',
        '-',
      ]);
      _available = true;
    } on ProcessException catch (e) {
      _available = false;
      WiretuneLog.info('PcmCache', 'ffmpeg is not available, so the spectrum analyser stays off: ${e.message}');
      return;
    }

    if (generation != _generation) {
      process.kill();
      return;
    }
    _process = process;
    unawaited(process.stderr.drain<void>());
    _subscription = process.stdout.listen(
      (chunk) => _append(chunk, generation),
      onError: (Object e) {
        if (generation == _generation) WiretuneLog.warn('PcmCache', 'PCM decode error: $e');
      },
      cancelOnError: true,
    );
  }

  void _append(List<int> chunk, int generation) {
    // A worker that lost the race must not append the previous track's audio to the next track's samples.
    if (generation != _generation) return;

    var i = 0;
    if (_pendingByte >= 0 && chunk.isNotEmpty) {
      _store(_pendingByte | (chunk[0] << 8));
      _pendingByte = -1;
      i = 1;
    }
    for (; i + 1 < chunk.length; i += 2) {
      if (!_store(chunk[i] | (chunk[i + 1] << 8))) return;
    }
    if (i < chunk.length) _pendingByte = chunk[i];
  }

  bool _store(int raw) {
    if (_sampleCount >= _maxSamples) {
      WiretuneLog.info('PcmCache', 'Track longer than the spectrum cache limit; visualisation stops after 20 minutes.');
      _stopProcess();
      return false;
    }
    if (_sampleCount >= _samples.length) {
      final bigger = Int16List(_maxSamples < _samples.length * 2 ? _maxSamples : _samples.length * 2);
      bigger.setRange(0, _sampleCount, _samples);
      _samples = bigger;
    }
    _samples[_sampleCount++] = raw >= 0x8000 ? raw - 0x10000 : raw;
    return true;
  }

  /// Copies a window of samples (-1..1) centred on [position] into [destination]; false while nothing is decoded.
  bool tryGetWindow(Duration position, Float32List destination) {
    if (_sampleCount == 0) return false;
    final center = (position.inMicroseconds * sampleRate) ~/ 1000000;
    final start = center - destination.length ~/ 2;
    for (var i = 0; i < destination.length; i++) {
      final index = start + i;
      destination[i] = index >= 0 && index < _sampleCount ? _samples[index] / 32768.0 : 0;
    }
    return true;
  }

  void _stopProcess() {
    _subscription?.cancel();
    _subscription = null;
    _process?.kill();
    _process = null;
  }

  void cancelAndReset() {
    _generation++;
    _stopProcess();
    _currentSource = null;
    _sampleCount = 0;
    _samples = Int16List(0);
  }

  void dispose() => cancelAndReset();
}
