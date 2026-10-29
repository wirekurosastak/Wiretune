// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune_core/wiretune_core.dart';

/// The lossy formats the server converts to.
enum TranscodeFormat {
  opus('opus', 'audio/ogg', 128, 24, 256),
  mp3('mp3', 'audio/mpeg', 192, 64, 320);

  const TranscodeFormat(this.extension, this.mimeType, this.defaultKbps, this.minKbps, this.maxKbps);

  final String extension;
  final String mimeType;

  /// The bitrate asked for when none is given, and the range an asked one is kept within.
  final int defaultKbps;
  final int minKbps;
  final int maxKbps;

  static TranscodeFormat? named(String? name) => values.asNameMap()[name?.toLowerCase()];
}

/// A conversion a player asked for: `?format=opus&bitrate=96` on a stream address.
class TranscodeRequest {
  const TranscodeRequest(this.format, this.bitrateKbps);

  final TranscodeFormat format;
  final int bitrateKbps;

  /// The request in [format] and [bitrate] (as text from an address), or null for none: no format, an unknown one, or
  /// `raw`. A missing or wrong bitrate is the format's default; a bitrate out of range is brought into it.
  static TranscodeRequest? parse(String? format, String? bitrate) {
    final target = TranscodeFormat.named(format);
    if (target == null) return null;
    final asked = int.tryParse(bitrate ?? '');
    return TranscodeRequest(target, (asked ?? target.defaultKbps).clamp(target.minKbps, target.maxKbps));
  }

  /// Whether converting [track] to this would not make it smaller or lighter: a lossy file that is at or below the
  /// bitrate already is sent as it is.
  bool isPointlessFor(Track track) => !track.format.isLossless && track.format.bitrateKbps <= bitrateKbps;
}

/// Converts music files to Opus or MP3 with `ffmpeg`, for a player on a slow connection. A converted file is kept on disk
/// by what it came from and what it was converted to, so each is made once and then sent like any file (with ranges).
/// Several asks for the same one wait for the same conversion, and only a few run at a time: a conversion takes a core.
class Transcoder {
  Transcoder(
    this.cacheDirectory, {
    this.ffmpeg = 'ffmpeg',
    this.maxCacheBytes = 2 * 1024 * 1024 * 1024,
    int concurrency = 2,
  }) : _slots = concurrency;

  final String cacheDirectory;
  final String ffmpeg;

  /// The most the kept files may take; the ones asked for longest ago go first.
  final int maxCacheBytes;

  int _slots;
  final Queue<Completer<void>> _waiting = Queue();
  final Map<String, Future<File?>> _running = {};
  Future<bool>? _available;

  /// Whether `ffmpeg` runs here; looked up once.
  Future<bool> get isAvailable => _available ??= _probe();

  Future<bool> _probe() async {
    try {
      final result = await Process.run(ffmpeg, ['-hide_banner', '-encoders']);
      final output = '${result.stdout}';
      final ok = result.exitCode == 0 && output.contains('libopus') && output.contains('libmp3lame');
      if (!ok) {
        WiretuneLog.warn(
          'Transcoder',
          'ffmpeg is there, but without the Opus and MP3 encoders: players get the original files.',
        );
      }
      return ok;
    } on ProcessException {
      WiretuneLog.info('Transcoder', 'ffmpeg is not installed: players get the original files, never converted ones.');
      return false;
    }
  }

  /// The converted file of [track] as [request] asks, made now if it isn't kept; null when it can't be made (no ffmpeg,
  /// a file ffmpeg can't read): the caller sends the original instead.
  Future<File?> convert(Track track, TranscodeRequest request) async {
    if (!await isAvailable) return null;
    final source = File(track.filePath);
    final FileStat stat;
    try {
      stat = await source.stat();
    } on FileSystemException {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;

    final key = sha1
        .convert(
          utf8.encode(
            '${track.id}|${stat.size}|${stat.modified.millisecondsSinceEpoch}|${request.format.name}|${request.bitrateKbps}',
          ),
        )
        .toString();
    final target = File(p.join(cacheDirectory, '$key.${request.format.extension}'));
    if (await target.exists()) {
      try {
        await target.setLastModified(DateTime.now()); // asked for just now: the last to go
      } on FileSystemException {
        // A file we can read but not touch is still sent.
      }
      return target;
    }
    // A block, not an arrow: whenComplete waits for a future its callback returns, and `remove` returns this very one.
    return _running[key] ??= _make(track, request, target).whenComplete(() {
      _running.remove(key);
    });
  }

  Future<File?> _make(Track track, TranscodeRequest request, File target) async {
    await _acquire();
    try {
      // Another ask may have finished it while this one waited for a slot.
      if (await target.exists()) return target;
      await Directory(cacheDirectory).create(recursive: true);
      final partial = File('${target.path}.part');
      final codec = switch (request.format) {
        TranscodeFormat.opus => ['-c:a', 'libopus', '-vbr', 'on', '-application', 'audio', '-f', 'ogg'],
        TranscodeFormat.mp3 => ['-c:a', 'libmp3lame', '-ar', '44100', '-f', 'mp3'],
      };
      WiretuneLog.info(
        'Transcoder',
        "Converting '${track.artist} - ${track.title}' to ${request.format.name} ${request.bitrateKbps} kbit/s",
      );
      final Process process;
      try {
        // Arguments as a list, no shell: the file's name is only ever the one after -i.
        process = await Process.start(ffmpeg, [
          '-nostdin',
          '-loglevel',
          'error',
          '-y',
          '-i',
          track.filePath,
          '-map',
          '0:a:0',
          '-vn',
          '-map_metadata',
          '-1',
          ...codec,
          '-b:a',
          '${request.bitrateKbps}k',
          partial.path,
        ]);
      } on ProcessException catch (e) {
        WiretuneLog.warn('Transcoder', 'Could not start ffmpeg: ${e.message}');
        return null;
      }
      unawaited(process.stdout.drain<void>());
      final errors = process.stderr.transform(utf8.decoder).join();
      final timeout = Timer(const Duration(minutes: 15), process.kill);
      final code = await process.exitCode;
      timeout.cancel();
      if (code != 0) {
        WiretuneLog.warn('Transcoder', "ffmpeg could not convert '${track.filePath}' (exit $code): ${await errors}");
        await _delete(partial);
        return null;
      }
      await partial.rename(target.path);
      unawaited(_prune(keep: target.path));
      return target;
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_slots > 0) {
      _slots--;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(); // the slot goes straight to the next
    } else {
      _slots++;
    }
  }

  /// Deletes the kept files asked for longest ago until what is left fits [maxCacheBytes]; [keep] stays.
  Future<void> _prune({required String keep}) async {
    try {
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final entry in Directory(cacheDirectory).list()) {
        if (entry is! File || entry.path.endsWith('.part')) continue;
        final stat = await entry.stat();
        files.add((entry, stat));
        total += stat.size;
      }
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= maxCacheBytes) break;
        if (file.path == keep) continue;
        await _delete(file);
        total -= stat.size;
      }
    } on FileSystemException catch (e) {
      WiretuneLog.debug('Transcoder', 'Could not tidy the converted files: ${e.message}');
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
