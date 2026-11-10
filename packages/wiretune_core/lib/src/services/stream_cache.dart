// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'wiretune_log.dart';

/// Keeps the server tracks that were streamed, so that playing one again reads it from the disk instead of the server.
///
/// The player streams a track through a relay on this device ([sourceFor] gives its address), which passes the server's
/// answer on and writes the same bytes into the track's file as they go by: nothing is fetched twice, and a track
/// skipped after a few seconds costs nothing extra. Once every byte of a track has come by (in one go, or in the pieces
/// the player's seeks asked for), the file is kept, and the next [sourceFor] gives its path. The oldest files go
/// once the folder is over [limitBytes]. Pieces of a track not complete yet are kept only until the app closes. The files
/// have their audio extension (Android lets an app put only audio files into the music folder), and a `.nomedia` file
/// keeps them out of other music apps.
class StreamCache {
  StreamCache(this.directory, {this.limitBytes = defaultLimitBytes, http.Client? client})
    : _client = client ?? http.Client();

  static const int defaultLimitBytes = 2 * 1024 * 1024 * 1024;

  final String directory;
  final int limitBytes;
  final http.Client _client;

  HttpServer? _server;

  /// In the relay's addresses, so that another program on this device can't use it to reach the server.
  final String _secret = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// Where each track the relay serves comes from on the server, by its key.
  final Map<String, String> _upstreams = {};

  /// The tracks being filled in, by key.
  final Map<String, _Partial> _partials = {};

  /// Opens the relay, and clears what an earlier run left unfinished.
  Future<void> start() async {
    try {
      final folder = Directory(directory)..createSync(recursive: true);
      _hideFromMusicApps();
      for (final entry in folder.listSync().whereType<File>()) {
        if (_isPart(entry.path)) entry.deleteSync();
      }
      _trim();
      final server = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => unawaited(_serve(request)));
      WiretuneLog.info('StreamCache', "Played tracks are kept in '$directory'.");
    } catch (e, s) {
      // Without it, tracks stream straight from the server, as before.
      WiretuneLog.error('StreamCache', "The cache in '$directory' can't be used", e, s);
    }
  }

  /// A `.nomedia` file, which keeps other music apps from listing the folder. Without it the cache works all the same.
  void _hideFromMusicApps() {
    try {
      final hidden = File(p.join(directory, '.nomedia'));
      if (!hidden.existsSync()) hidden.createSync();
    } on FileSystemException catch (e) {
      WiretuneLog.warn('StreamCache', "No .nomedia in the cache: other music apps may list it (${e.message}).");
    }
  }

  /// The track [key] played to its end: the parts of it that never came by (skipped over by jumps in it) are fetched,
  /// and it is kept. Nothing happens for a track that didn't stream through the relay, or is kept already.
  Future<void> finish(String key, String extension) async {
    final name = _fileName(key, extension);
    final partial = _partials[name];
    final upstream = _upstreams[name];
    if (partial == null || upstream == null || partial.isComplete) return;
    try {
      for (final (start, end) in partial.gaps) {
        final request = http.Request('GET', Uri.parse(upstream))
          ..headers[HttpHeaders.rangeHeader] = 'bytes=$start-${end - 1}';
        final answer = await _client.send(request);
        final span = _span(answer);
        if (span == null || span.start != start || span.total != partial.total) {
          await answer.stream.drain<void>();
          WiretuneLog.info('StreamCache', 'The server sent no part of a track, which is not kept.');
          return;
        }
        var offset = start;
        await for (final chunk in answer.stream) {
          partial.write(offset, chunk);
          offset += chunk.length;
        }
      }
      if (partial.isComplete) _keep(name, partial);
    } catch (e) {
      WiretuneLog.info('StreamCache', "The rest of a track couldn't be fetched: ${e.runtimeType}");
    }
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    for (final partial in _partials.values) {
      partial.close();
    }
    _partials.clear();
    _client.close();
  }

  /// What the player plays for the server track [key] (which names the track's file and the quality asked of it) at
  /// [upstream], an audio file of [extension]: the kept file, else the relay's address for it; [upstream] itself while
  /// the relay isn't open.
  String sourceFor(String key, String extension, String upstream) {
    final name = _fileName(key, extension);
    final file = File(p.join(directory, name));
    if (file.existsSync()) {
      try {
        file.setLastModifiedSync(DateTime.now()); // the last to go
      } catch (_) {
        // Only its place in the order of removal: the file still plays.
      }
      return file.path;
    }
    final server = _server;
    if (server == null) return upstream;
    _upstreams[name] = upstream;
    return 'http://127.0.0.1:${server.port}/$_secret/$name';
  }

  /// Whether the server track [key] is kept.
  bool has(String key, String extension) => File(p.join(directory, _fileName(key, extension))).existsSync();

  /// Letters, digits, `-` and `_` only, and the extension: a file name, and a path segment of the relay's address.
  static String _fileName(String key, String extension) {
    String clean(String text) => text.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${clean(key)}.${clean(extension)}';
  }

  /// A track not complete yet: `<name>.part.<extension>`, an audio file to Android too.
  static String _partName(String name) => '${p.withoutExtension(name)}.part${p.extension(name)}';

  static bool _isPart(String path) => p.basename(path).contains('.part.');

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final upstream = segments.length == 2 && segments[0] == _secret ? _upstreams[segments[1]] : null;
    if (upstream == null || (request.method != 'GET' && request.method != 'HEAD')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final name = segments[1];
    final kept = File(p.join(directory, name));
    if (kept.existsSync()) return _serveKept(request, kept);
    final forward = http.Request(request.method, Uri.parse(upstream));
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) forward.headers[HttpHeaders.rangeHeader] = range;
    http.StreamedResponse answer;
    try {
      answer = await _client.send(forward);
    } catch (e) {
      // The player reports it as the server being out of reach, as it would without the cache.
      WiretuneLog.warn('StreamCache', "The server can't be reached for a stream: ${e.runtimeType}");
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    try {
      response.statusCode = answer.statusCode;
      for (final header in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
      ]) {
        final value = answer.headers[header];
        if (value != null) response.headers.set(header, value);
      }
      final span = request.method == 'GET' ? _span(answer) : null;
      final partial = span == null ? null : _partial(name, span.total);
      var offset = span?.start ?? 0;
      await response.addStream(
        answer.stream.map((chunk) {
          partial?.write(offset, chunk);
          offset += chunk.length;
          return chunk;
        }),
      );
      await response.close();
      if (partial != null && partial.isComplete) _keep(name, partial);
    } catch (e) {
      // The player went on (a skip, a seek, the app closing) or the server went away: what came by stays in the
      // track's pieces, and the player asks again for what it wants.
      WiretuneLog.info('StreamCache', 'A stream through the cache ended early: ${e.runtimeType}');
      try {
        await response.close();
      } catch (_) {
        // Already closed by the player.
      }
    }
  }

  /// A track kept since the player was given the relay's address for it (a jump in it, the spectrum decoding it): the
  /// file answers, all of it or the range asked for, and the server isn't asked again.
  Future<void> _serveKept(HttpRequest request, File file) async {
    final response = request.response;
    try {
      final length = file.lengthSync();
      final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty ? length - 1 : min(int.parse(range[2]!), length - 1);
      if (start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = end - start + 1;
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      if (request.method == 'GET') await response.addStream(file.openRead(start, end + 1));
      await response.close();
    } catch (e) {
      // The player went on, or the file went (the cache trimmed): the player asks again for what it wants.
      WiretuneLog.info('StreamCache', 'A stream from the cache ended early: ${e.runtimeType}');
      try {
        await response.close();
      } catch (_) {
        // Already closed by the player.
      }
    }
  }

  /// Where the server's answer starts in the file and how long the whole file is; null when it doesn't say.
  static ({int start, int total})? _span(http.StreamedResponse answer) {
    if (answer.statusCode == HttpStatus.ok) {
      final length = answer.contentLength;
      return length == null || length <= 0 ? null : (start: 0, total: length);
    }
    if (answer.statusCode == HttpStatus.partialContent) {
      final match = RegExp(r'^bytes (\d+)-\d+/(\d+)$').firstMatch(answer.headers[HttpHeaders.contentRangeHeader] ?? '');
      if (match == null) return null;
      return (start: int.parse(match[1]!), total: int.parse(match[2]!));
    }
    return null;
  }

  _Partial? _partial(String name, int total) {
    final existing = _partials[name];
    if (existing != null && existing.total == total) return existing;
    existing?.close();
    try {
      return _partials[name] = _Partial(File(p.join(directory, _partName(name))), total);
    } on FileSystemException catch (e) {
      WiretuneLog.warn('StreamCache', "A track can't be kept: ${e.message}");
      return null;
    }
  }

  /// Every byte of the track came by: it is kept, and the oldest go while the folder is too big. Once: another stream
  /// of the same track that ends after it finds it kept.
  void _keep(String name, _Partial partial) {
    if (!identical(_partials[name], partial)) return;
    _partials.remove(name);
    partial.close();
    try {
      partial.file.renameSync(p.join(directory, name));
      _trim(keep: name);
    } on FileSystemException catch (e) {
      WiretuneLog.warn('StreamCache', "A streamed track couldn't be kept: ${e.message}");
    }
  }

  /// Removes the files used longest ago until the kept ones fit in [limitBytes]; never [keep].
  void _trim({String? keep}) {
    final files = [
      for (final entry in Directory(directory).listSync().whereType<File>())
        if (!_isPart(entry.path) && !p.basename(entry.path).startsWith('.')) (file: entry, stat: entry.statSync()),
    ]..sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var size = files.fold<int>(0, (sum, entry) => sum + entry.stat.size);
    for (final entry in files) {
      if (size <= limitBytes) break;
      if (p.basename(entry.file.path) == keep) continue;
      try {
        entry.file.deleteSync();
        size -= entry.stat.size;
      } on FileSystemException catch (e) {
        WiretuneLog.warn('StreamCache', "An old cached track couldn't be removed: ${e.message}");
      }
    }
  }
}

/// A track being filled in: its file, written where each piece belongs, and which parts of it are there.
class _Partial {
  _Partial(this.file, this.total) : _raf = file.openSync(mode: FileMode.write);

  final File file;
  final int total;
  final RandomAccessFile _raf;

  /// The parts written, as [start, end) pairs, sorted and apart.
  final List<(int, int)> _have = [];

  /// Kept or given up: another stream of the same track still going by writes nothing more.
  bool _closed = false;

  bool get isComplete => _have.length == 1 && _have.first == (0, total);

  /// The parts not written yet, as [start, end) pairs.
  List<(int, int)> get gaps {
    final gaps = <(int, int)>[];
    var at = 0;
    for (final (start, end) in _have) {
      if (start > at) gaps.add((at, start));
      at = end;
    }
    if (at < total) gaps.add((at, total));
    return gaps;
  }

  void write(int offset, List<int> bytes) {
    if (_closed || bytes.isEmpty || offset + bytes.length > total) return;
    _raf
      ..setPositionSync(offset)
      ..writeFromSync(bytes);
    var (start, end) = (offset, offset + bytes.length);
    final kept = <(int, int)>[];
    for (final (s, e) in _have) {
      if (e < start || s > end) {
        kept.add((s, e));
      } else {
        start = min(start, s);
        end = max(end, e);
      }
    }
    _have
      ..clear()
      ..addAll([...kept, (start, end)]..sort((a, b) => a.$1.compareTo(b.$1)));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _raf.closeSync();
    } catch (_) {
      // Closed already.
    }
  }
}
