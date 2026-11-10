// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/wiretune_log.dart';

/// The current track decoded to 16-bit mono 44.1 kHz PCM in memory, by a separate `ffmpeg` process or the platform's
/// own [decoder], so the spectrum analyser can read the window at the playback position. It never touches the audio
/// that is being played.
///
/// Decoding stops after 20 minutes of audio (about 106 MB), so a very long mix cannot exhaust memory. A server track is
/// requested from the server a second time for this; the player downloads it and hands it to `ffmpeg` on its standard
/// input, so the address with the stream token never stands in the process list.
class PcmCache {
  PcmCache({this.decoder, this.decoderSeeks = false});

  /// Decodes a source (a file path or a stream URL) into that PCM, little-endian, in chunks, from a time in it: a
  /// phone's own decoder, as a phone has no `ffmpeg`. Null: `ffmpeg`.
  final Stream<List<int>> Function(String source, Duration from)? decoder;

  /// Whether [decoder] starts at the time it is given (Android's does); one that doesn't always starts at the
  /// beginning. `ffmpeg` does.
  final bool decoderSeeks;

  /// Decoding starts again at the playback position once that is this far past what is decoded (a jump ahead), rather
  /// than leaving the bars still until it gets there; or before it (a jump back).
  static const Duration _restartAhead = Duration(seconds: 3);

  /// A little before the position decoding starts again at, for the window around the position.
  static const Duration _restartLead = Duration(milliseconds: 500);

  static const int sampleRate = 44100;
  static const int _maxSamples = sampleRate * 60 * 20;

  Int16List _samples = Int16List(0);
  int _sampleCount = 0;

  /// The sample of the track that the first one decoded is: where decoding started.
  int _first = 0;

  /// When decoding last started again at the position: not again for a moment, while it gets going.
  final Stopwatch _sinceRestart = Stopwatch();
  Process? _process;
  HttpClient? _download;
  StreamSubscription<List<int>>? _subscription;
  String? _currentSource;
  int _generation = 0;
  int _pendingByte = -1;

  /// Whether ffmpeg was found; false after a start failed, so playback does not try again for every track.
  static bool? _available;

  /// Starts decoding [audioSource] in the background (a file path or a stream URL).
  Future<void> loadTrack(String audioSource) async {
    if (_currentSource == audioSource && _sampleCount > 0) return;
    await _decode(audioSource, Duration.zero);
  }

  /// Decodes [audioSource] from [from] on, in place of what was decoded.
  Future<void> _decode(String audioSource, Duration from) async {
    cancelAndReset();
    if (_available == false) return;

    _currentSource = audioSource;
    final generation = ++_generation;
    _samples = Int16List(sampleRate * 180); // three minutes; grows on demand
    _sampleCount = 0;
    _first = (from.inMicroseconds * sampleRate) ~/ 1000000;
    _pendingByte = -1;
    final seconds = (from.inMilliseconds / 1000).toStringAsFixed(3);

    final decoder = this.decoder;
    if (decoder != null) {
      _subscription = decoder(audioSource, from).listen(
        (chunk) => _append(chunk, generation),
        onError: (Object e) {
          if (generation == _generation) WiretuneLog.warn('PcmCache', 'PCM decode error: $e');
        },
        cancelOnError: true,
      );
      return;
    }

    Process process;
    try {
      // Arguments as a list (no shell): file names may contain quotes and must never become options.
      process = await Process.start('ffmpeg', [
        '-nostdin',
        '-loglevel',
        'error',
        // A file is sought in; a stream on the standard input is decoded up to there and dropped.
        if (from > Duration.zero && !_isUrl(audioSource)) ...['-ss', seconds],
        '-i',
        _isUrl(audioSource) ? 'pipe:0' : audioSource,
        if (from > Duration.zero && _isUrl(audioSource)) ...['-ss', seconds],
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
    if (_isUrl(audioSource)) {
      unawaited(_feed(process, audioSource, generation));
    }
    _subscription = process.stdout.listen(
      (chunk) => _append(chunk, generation),
      onError: (Object e) {
        if (generation == _generation) WiretuneLog.warn('PcmCache', 'PCM decode error: $e');
      },
      cancelOnError: true,
    );
  }

  static bool _isUrl(String source) => source.startsWith('http://') || source.startsWith('https://');

  /// Downloads [url] into the standard input of [process]. It ends when the file does, or when decoding stops and
  /// `ffmpeg` closes its input (the 20-minute limit, a new track).
  Future<void> _feed(Process process, String url, int generation) async {
    // ffmpeg closing its input is an error on the pipe; nobody else waits for it.
    unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    final client = _download = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        if (generation == _generation) WiretuneLog.info('PcmCache', 'The server answered ${response.statusCode}.');
        process.kill();
        return;
      }
      await process.stdin.addStream(response);
      await process.stdin.close();
    } on Object catch (e) {
      if (generation == _generation) WiretuneLog.debug('PcmCache', 'The download for the spectrum ended: $e');
    } finally {
      client.close(force: true);
      if (identical(_download, client)) _download = null;
    }
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

  /// Copies a window of samples (-1..1) centred on [position] into [destination]; false while nothing is decoded. A
  /// position well past what is decoded, or before it (a jump in the track), has decoding start again there.
  bool tryGetWindow(Duration position, Float32List destination) {
    final center = (position.inMicroseconds * sampleRate) ~/ 1000000;
    _followJump(position, center);
    if (_sampleCount == 0) return false;
    final start = center - destination.length ~/ 2 - _first;
    for (var i = 0; i < destination.length; i++) {
      final index = start + i;
      destination[i] = index >= 0 && index < _sampleCount ? _samples[index] / 32768.0 : 0;
    }
    return true;
  }

  void _followJump(Duration position, int center) {
    final source = _currentSource;
    if (source == null || (decoder != null && !decoderSeeks)) return;
    final ahead = (_restartAhead.inMicroseconds * sampleRate) ~/ 1000000;
    final away = center < _first || center > _first + _sampleCount + ahead;
    if (!away || (_sinceRestart.isRunning && _sinceRestart.elapsed < const Duration(milliseconds: 1500))) return;
    _sinceRestart
      ..reset()
      ..start();
    final from = position - _restartLead;
    unawaited(_decode(source, from < Duration.zero ? Duration.zero : from));
  }

  void _stopProcess() {
    _download?.close(force: true);
    _download = null;
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
    _first = 0;
    _samples = Int16List(0);
  }

  void dispose() => cancelAndReset();
}
