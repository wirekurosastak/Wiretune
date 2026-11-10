// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Whether any process on this Linux system has [text] in its command line.
bool _inProcessList(String text) {
  for (final entry in Directory('/proc').listSync()) {
    try {
      if (File(p.join(entry.path, 'cmdline')).readAsStringSync().contains(text)) return true;
    } on FileSystemException {
      // A process that ended, or one that is not ours.
    }
  }
  return false;
}

bool _hasSound(PcmCache cache) {
  final window = Float32List(1024);
  return cache.tryGetWindow(const Duration(milliseconds: 500), window) && window.any((v) => v.abs() > 0.05);
}

void main() {
  final ffmpeg = hasTool('ffmpeg');
  late Directory folder;
  late String wav;

  setUpAll(() {
    useTempDataDirectory();
    folder = Directory.systemTemp.createTempSync('wiretune_pcm_');
    wav = p.join(folder.path, 'tone.wav');
    writeWav(wav, 44100, seconds: 2);
  });
  tearDownAll(() => folder.deleteSync(recursive: true));

  group('decoded by ffmpeg', skip: ffmpeg ? false : 'ffmpeg is not installed', () {
    test('a file is decoded where it is', () async {
      final cache = PcmCache();
      addTearDown(cache.dispose);
      await cache.loadTrack(wav);
      await until(() => _hasSound(cache));
    });

    test('a stream is downloaded by the player, and its address never reaches the process list', () async {
      final bytes = File(wav).readAsBytesSync();
      final requests = <Uri>[];
      final halfSent = Completer<void>();
      final goOn = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request.uri);
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, bytes.length ~/ 2));
        await request.response.flush();
        halfSent.complete();
        await goOn.future; // ffmpeg is running now, waiting for the rest
        request.response.add(bytes.sublist(bytes.length ~/ 2));
        await request.response.close();
      });

      final cache = PcmCache();
      addTearDown(cache.dispose);
      await cache.loadTrack('http://127.0.0.1:${server.port}/api/stream/abc?token=secret-stream-token');
      await halfSent.future;
      if (Platform.isLinux) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(_inProcessList('secret-stream-token'), isFalse);
      }
      goOn.complete();

      await until(() => _hasSound(cache));
      expect(requests.single.queryParameters['token'], 'secret-stream-token');
    });

    test('a jump far ahead in the track has decoding start again there, not wait until it gets there', () async {
      // A minute of silence with a tone in its last ten seconds.
      final late = p.join(folder.path, 'late.wav');
      final made = await Process.run('ffmpeg', [
        '-v', 'error', '-y', '-f', 'lavfi', '-i', "aevalsrc='if(gt(t,50),sin(440*2*PI*t),0)':s=44100:d=60", late, //
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final cache = PcmCache();
      addTearDown(cache.dispose);
      await cache.loadTrack(late);
      bool soundAt(Duration position) {
        final window = Float32List(1024);
        return cache.tryGetWindow(position, window) && window.any((v) => v.abs() > 0.05);
      }

      await until(() => soundAt(const Duration(seconds: 55)));
    });

    test('a server that refuses leaves the spectrum empty, and a new track starts again', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });

      final cache = PcmCache();
      addTearDown(cache.dispose);
      await cache.loadTrack('http://127.0.0.1:${server.port}/api/stream/abc?token=old');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(_hasSound(cache), isFalse);

      await cache.loadTrack(wav);
      await until(() => _hasSound(cache));
    });
  });

  test(
    "a platform's decoder (an Android phone's) is used instead of ffmpeg, a chunk split mid-sample included",
    () async {
      // Half a second of silence, then a loud square wave: 16-bit little-endian mono.
      final samples = Int16List(44100);
      for (var i = 22050; i < samples.length; i++) {
        samples[i] = (i ~/ 50).isEven ? 20000 : -20000;
      }
      final bytes = samples.buffer.asUint8List();
      final asked = <String>[];
      final cache = PcmCache(
        decoder: (source, from) {
          asked.add(source);
          // An odd split: the cache has to keep the half sample for the next chunk.
          return Stream.fromIterable([bytes.sublist(0, 30001), bytes.sublist(30001)]);
        },
      );
      addTearDown(cache.dispose);
      await cache.loadTrack('/music/track.flac');
      await until(() => _hasSound(cache));
      expect(asked, ['/music/track.flac']);
      final window = Float32List(4);
      cache.tryGetWindow(const Duration(milliseconds: 250), window);
      expect(window, everyElement(0), reason: 'the silence where it was');
    },
  );

  test("a jump has a platform's decoder start again at it when it can, a while after the last", () async {
    for (final seeks in [true, false]) {
      final asked = <Duration>[];
      final cache = PcmCache(
        decoderSeeks: seeks,
        // A decoder that has given ten seconds so far, and goes on slowly.
        decoder: (source, from) {
          asked.add(from);
          return Stream.value(Int16List(44100 * 10).buffer.asUint8List());
        },
      );
      addTearDown(cache.dispose);
      await cache.loadTrack('/music/track.flac');
      await pumpEventQueue();
      final window = Float32List(4);
      cache.tryGetWindow(const Duration(seconds: 5), window);
      expect(asked, [Duration.zero], reason: 'decoded there already');

      cache.tryGetWindow(const Duration(minutes: 3), window);
      cache.tryGetWindow(const Duration(minutes: 3, seconds: 1), window);
      expect(
        asked,
        seeks ? [Duration.zero, const Duration(minutes: 2, seconds: 59, milliseconds: 500)] : [Duration.zero],
        reason: seeks ? 'once, just before the position' : "a decoder that can't start there isn't asked again",
      );
    }
  });
}
