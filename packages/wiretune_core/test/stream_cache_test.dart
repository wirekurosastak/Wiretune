// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/testing.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The cache of streamed tracks: the relay passes the server's answer on and keeps a track once all of it came by.
void main() {
  late Directory folder;
  late HttpServer server;
  late StreamCache cache;
  final track = Uint8List.fromList(List.generate(300 * 1024, (i) => Random(i).nextInt(256)));
  var served = 0;

  /// While set, the server sends the first half of its next answer and the rest once this completes.
  Completer<void>? hold;

  setUpAll(useTempDataDirectory);

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('wiretune_stream_cache_');
    served = 0;
    hold = null;
    // A server that sends the track, or the range asked for, as Wiretune's does.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!request.uri.path.startsWith('/api/stream/')) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value('range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty ? track.length - 1 : int.parse(range[2]!);
      final response = request.response
        ..headers.contentType = ContentType('audio', 'flac')
        ..headers.set('accept-ranges', 'bytes')
        ..contentLength = end - start + 1;
      if (range != null) {
        response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $start-$end/${track.length}');
      }
      served += end - start + 1;
      final held = hold;
      hold = null;
      if (held == null) {
        response.add(track.sublist(start, end + 1));
      } else {
        final middle = (start + end) ~/ 2;
        response.add(track.sublist(start, middle));
        await response.flush();
        await held.future;
        response.add(track.sublist(middle, end + 1));
      }
      await response.close();
    });
    cache = StreamCache(folder.path);
    await cache.start();
  });

  tearDown(() async {
    await cache.close();
    await server.close(force: true);
    folder.deleteSync(recursive: true);
  });

  String upstream(String name) => 'http://127.0.0.1:${server.port}/api/stream/$name?token=secret';

  Future<http.Response> get(String url, [String? range]) => http.get(Uri.parse(url), headers: {'range': ?range});

  test('a track streamed whole is kept, and played from the disk the next time', () async {
    final relay = cache.sourceFor('t1-v1', 'flac', upstream('t1'));
    expect(relay, startsWith('http://127.0.0.1:'));
    expect(relay, isNot(contains('token')), reason: "the server's address stays in the app");

    final answer = await get(relay);
    expect(answer.statusCode, 200);
    expect(answer.bodyBytes, track);
    expect(served, track.length);

    final kept = cache.sourceFor('t1-v1', 'flac', upstream('t1'));
    expect(kept, p.join(folder.path, 't1-v1.flac'), reason: 'an audio file, as Android wants in the music folder');
    expect(File(kept).readAsBytesSync(), track);
    expect(cache.has('t1-v1', 'flac'), isTrue);
  });

  test('a track kept meanwhile answers from the disk at its relay address, without the server', () async {
    final relay = cache.sourceFor('t7', 'flac', upstream('t7'));
    await get(relay);
    expect(cache.has('t7', 'flac'), isTrue);
    served = 0;

    // The player still holds the relay's address: a jump in the track, the spectrum decoding it.
    final whole = await get(relay);
    expect(whole.statusCode, 200);
    expect(whole.bodyBytes, track);
    final piece = await get(relay, 'bytes=1000-1999');
    expect((piece.statusCode, piece.headers['content-range']), (206, 'bytes 1000-1999/${track.length}'));
    expect(piece.bodyBytes, track.sublist(1000, 2000));
    expect((await get(relay, 'bytes=250000-')).bodyBytes, track.sublist(250000));
    expect(served, 0, reason: 'the server is not asked for a track that is here');
    expect((await get(relay, 'bytes=${track.length}-')).statusCode, 416);

    // Nothing is left to fill in or to fetch at the track's end.
    await cache.finish('t7', 'flac');
    expect(served, 0);
    expect([for (final f in folder.listSync()) p.basename(f.path)]..sort(), ['.nomedia', 't7.flac']);
  });

  test('two streams of a track ending one after the other keep it once', () async {
    final relay = cache.sourceFor('t8', 'flac', upstream('t8'));
    // The player's and the spectrum's: the first is still half way when the second has brought the whole track.
    final release = hold = Completer<void>();
    final slow = get(relay);
    await until(() => hold == null);
    await get(relay);
    expect(cache.has('t8', 'flac'), isTrue);

    final log = File(WiretuneLog.logPath!);
    final before = log.lengthSync();
    release.complete();
    expect((await slow).bodyBytes, track);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the relay ends its side of it
    expect(log.readAsStringSync().substring(before), isNot(contains("couldn't be kept")));
    expect(File(p.join(folder.path, 't8.flac')).readAsBytesSync(), track);
  });

  test("the pieces a player's seeks ask for add up to the track", () async {
    final relay = cache.sourceFor('t2', 'flac', upstream('t2'));
    final first = await get(relay, 'bytes=0-99999');
    expect(first.statusCode, 206);
    expect(first.bodyBytes, track.sublist(0, 100000));
    expect(cache.has('t2', 'flac'), isFalse);

    expect((await get(relay, 'bytes=200000-')).bodyBytes, track.sublist(200000));
    expect(cache.has('t2', 'flac'), isFalse, reason: 'a gap in the middle');
    await get(relay, 'bytes=90000-210000');
    expect(cache.has('t2', 'flac'), isTrue);
    expect(File(cache.sourceFor('t2', 'flac', upstream('t2'))).readAsBytesSync(), track);
    expect(served, 100000 + (track.length - 200000) + 120001, reason: 'nothing fetched but what the player asked for');
  });

  test('a track played to its end after a jump is kept, only the part jumped over fetched for it', () async {
    final relay = cache.sourceFor('t6', 'flac', upstream('t6'));
    await get(relay, 'bytes=0-49999');
    await get(relay, 'bytes=250000-');
    expect(cache.has('t6', 'flac'), isFalse);
    served = 0;

    await cache.finish('t6', 'flac');
    expect(cache.has('t6', 'flac'), isTrue);
    expect(File(cache.sourceFor('t6', 'flac', upstream('t6'))).readAsBytesSync(), track);
    expect(served, 200000, reason: 'the gap alone');

    // A track that didn't stream through the cache, or is kept already: nothing to do.
    served = 0;
    await cache.finish('t6', 'flac');
    await cache.finish('never-played', 'flac');
    expect(served, 0);
  });

  test('a track only partly played is not kept, nor is a refusal', () async {
    await get(cache.sourceFor('t3', 'flac', upstream('t3')), 'bytes=0-999');
    expect(cache.has('t3', 'flac'), isFalse);
    List<String> files() => [for (final f in folder.listSync()) p.basename(f.path)]..sort();
    expect(files(), ['.nomedia', 't3.part.flac'], reason: 'other music apps leave the folder alone');
    await cache.close();

    // Restarted: what was left unfinished is gone.
    cache = StreamCache(folder.path);
    await cache.start();
    expect(files(), ['.nomedia']);

    final missing = cache.sourceFor('t4', 'flac', 'http://127.0.0.1:${server.port}/nothing');
    expect((await get(missing)).statusCode, 404, reason: "the server's answer, passed on");
    expect(cache.has('t4', 'flac'), isFalse);
    final unreachable = cache.sourceFor('t5', 'flac', upstream('t5'));
    await server.close(force: true);
    expect((await get(unreachable)).statusCode, 502, reason: 'the server is gone');
    expect(cache.has('t5', 'flac'), isFalse);
  });

  test('the folder keeps to its limit, the tracks played longest ago going first', () async {
    await cache.close();
    cache = StreamCache(folder.path, limitBytes: track.length * 2);
    await cache.start();
    for (final (i, name) in ['a', 'b', 'c'].indexed) {
      await get(cache.sourceFor(name, 'flac', upstream(name)));
      File(p.join(folder.path, '$name.flac')).setLastModifiedSync(DateTime(2026, 1, 1 + i));
    }
    final kept = folder.listSync().map((f) => p.basename(f.path)).toList()..sort();
    expect(kept, ['.nomedia', 'b.flac', 'c.flac']);
  });

  test("another program on the device can't use the relay", () async {
    final relay = Uri.parse(cache.sourceFor('t5', 'flac', upstream('t5')));
    expect((await http.get(relay.replace(path: '/wrong/t5'))).statusCode, 404);
    expect((await http.get(relay.replace(path: '${relay.path}x'))).statusCode, 404);
    expect((await http.post(relay)).statusCode, 404);
    expect(served, 0);
  });

  test('a server track streams through the cache under its file and its quality', () {
    final track = TestSupport.makeServerTrack('s1', 'Naima')
      ..fileSizeBytes = 1234
      ..fileModifiedAt = DateTime.utc(2026);
    final time = DateTime.utc(2026).millisecondsSinceEpoch;
    expect(WiretuneAudioEngine.cacheKey(track, null), 's1-1234-$time');
    expect(WiretuneAudioEngine.cacheKey(track, StreamingQuality.normal), 's1-1234-$time-opus96');
  });
}
