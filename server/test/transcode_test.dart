// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';
import 'package:wiretune_server/src/transcoder.dart';

import 'support.dart';

/// Streams converted to Opus or MP3 for a slow connection (skipped without ffmpeg, which converts).
void main() {
  final ffmpeg = hasTool('ffmpeg');
  final skip = ffmpeg ? false : 'ffmpeg is not installed';

  group('what a player asks for', () {
    test('is a format and a bitrate kept within what the format allows', () {
      TranscodeRequest? ask(String? format, String? bitrate) => TranscodeRequest.parse(format, bitrate);

      expect(ask('opus', '96')?.bitrateKbps, 96);
      expect(ask('OPUS', '96')?.format, TranscodeFormat.opus);
      expect(ask('opus', null)?.bitrateKbps, 128, reason: "the format's own");
      expect(ask('opus', 'many')?.bitrateKbps, 128);
      expect(ask('opus', '9')?.bitrateKbps, 24, reason: 'brought up into the range');
      expect(ask('opus', '9000')?.bitrateKbps, 256);
      expect(ask('mp3', '320')?.bitrateKbps, 320);
      expect(ask('mp3', '32')?.bitrateKbps, 64);
      for (final nothing in [null, '', 'raw', 'flac', 'wav']) {
        expect(ask(nothing, '96'), isNull, reason: '"$nothing" is the file itself');
      }
    });

    test('is not made for a lossy file that is at or below the bitrate already', () {
      Track lossy(int kbps) => Track(
        format: AudioFormat(codec: 'MP3', bitrateKbps: kbps, isLossless: false),
        filePath: '/a.mp3',
      );
      final request = TranscodeRequest.parse('opus', '128')!;
      expect(request.isPointlessFor(lossy(128)), isTrue);
      expect(request.isPointlessFor(lossy(96)), isTrue);
      expect(request.isPointlessFor(lossy(320)), isFalse);
      expect(request.isPointlessFor(Track(filePath: '/a.flac')), isFalse, reason: 'lossless is always worth it');
    });
  });

  group('over the API', skip: skip, () {
    late ServerFixture server;
    late Api client;
    late Map<String, dynamic> first;

    setUp(() async {
      server = await ServerFixture.start();
      (client, _) = await setupAdmin(server);
      first = (await server.waitForTracks(client, 3)).firstWhere((t) => t['title'] == '01 First');
    });
    tearDown(() => server.close());

    String stream([String query = '']) => '/api/stream/${first['id']}$query';
    Directory cache() => Directory(p.join(server.dataPath, 'Transcodes'));
    List<File> kept() => cache().existsSync() ? cache().listSync().whereType<File>().toList() : [];

    test('the file itself is sent without a format, with an unknown one, or with raw', () async {
      final original = File(p.join(server.musicFolder, 'Artist A', 'Album 1', '01 First.wav')).readAsBytesSync();
      for (final query in ['', '?format=wav', '?format=raw&bitrate=64', '?bitrate=64']) {
        final response = await client.get(stream(query));
        expect(response.statusCode, 200, reason: query);
        expect(response.bodyBytes, original, reason: query);
      }
      expect(kept(), isEmpty);
    });

    test('Opus is converted once, smaller, playable with ranges, and kept for the next ask', () async {
      final original = (first['fileSizeBytes'] as int);
      final response = await client.get(stream('?format=opus&bitrate=64'));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'audio/ogg');
      expect(ascii.decode(response.bodyBytes.sublist(0, 4)), 'OggS');
      expect(response.bodyBytes.length, lessThan(original ~/ 4));
      expect(response.headers['accept-ranges'], 'bytes');

      final converted = kept();
      expect(converted.map((f) => p.extension(f.path)), ['.opus']);
      final madeAt = converted.single.lastModifiedSync();

      final part = await client.get(stream('?format=opus&bitrate=64'), headers: {'Range': 'bytes=10-59'});
      expect(part.statusCode, 206);
      expect(part.bodyBytes, response.bodyBytes.sublist(10, 60));
      expect(kept(), hasLength(1), reason: 'the second ask used the kept one');
      expect(kept().single.lastModifiedSync().isBefore(madeAt), isFalse);

      // Another bitrate is another file.
      expect((await client.get(stream('?format=opus&bitrate=32'))).statusCode, 200);
      expect(kept(), hasLength(2));
    });

    test('MP3 is converted too, also from a rate it can not take as it is', () async {
      writeWav(p.join(server.musicFolder, 'Artist A', 'Album 1', '01 First.wav'), 96000, seconds: 1);
      await client.post('/api/library/scan');
      await server.waitForTracks(client, 3);
      final response = await client.get(stream('?format=mp3&bitrate=128'));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'audio/mpeg');
      expect(ascii.decode(response.bodyBytes.sublist(0, 3)), 'ID3');
    });

    test('many asks for the same conversion share one', () async {
      final responses = await Future.wait([for (var i = 0; i < 5; i++) client.get(stream('?format=opus&bitrate=48'))]);
      expect(responses.map((r) => r.statusCode), everyElement(200));
      expect(responses.map((r) => sha1.convert(r.bodyBytes).toString()).toSet(), hasLength(1));
      expect(kept(), hasLength(1));
      expect(kept().map((f) => p.extension(f.path)), ['.opus'], reason: 'no half-made file is left');
    });

    test('a file ffmpeg can not read is sent as it is', () async {
      final path = p.join(server.musicFolder, 'Artist A', 'Album 1', '01 First.wav');
      File(path).writeAsBytesSync(List.filled(4096, 7)); // damaged since the scan
      final response = await client.get(stream('?format=opus&bitrate=64'));
      expect(response.statusCode, 200);
      expect(response.bodyBytes, hasLength(4096));
      expect(kept(), isEmpty, reason: 'nothing half-made is kept');
    });

    test('another account may ask too, and a missing track is a 404 either way', () async {
      final (guest, _) = await registerGuest(server, client);
      expect((await guest.get(stream('?format=opus'))).statusCode, 200);
      expect((await client.get('/api/stream/nonsense?format=opus')).statusCode, 404);
    });
  });

  group('the converted files kept', skip: skip, () {
    late Directory folder;
    setUp(() => folder = Directory.systemTemp.createTempSync('wiretune_transcode_'));
    tearDown(() => folder.deleteSync(recursive: true));

    Track track(String name) {
      final path = p.join(folder.path, '$name.wav');
      writeWav(path, 44100, seconds: 1);
      return Track(id: name, title: name, artist: 'A', filePath: path);
    }

    test('are the ones asked for longest ago to go, when they take more than the limit', () async {
      final cache = p.join(folder.path, 'cache');
      final transcoder = Transcoder(cache, maxCacheBytes: 1);
      final request = TranscodeRequest.parse('opus', '64')!;
      final a = await transcoder.convert(track('a'), request);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final b = await transcoder.convert(track('b'), request);
      expect(a, isNotNull);
      expect(b, isNotNull);
      await until(() => Directory(cache).listSync().length == 1);
      expect(File(b!.path).existsSync(), isTrue, reason: 'the one just made stays');
      expect(File(a!.path).existsSync(), isFalse);
    });

    test('are made again when the file changed', () async {
      final transcoder = Transcoder(p.join(folder.path, 'cache'));
      final request = TranscodeRequest.parse('opus', '64')!;
      final song = track('song');
      final before = await transcoder.convert(song, request);
      writeWav(song.filePath, 44100, seconds: 2);
      final after = await transcoder.convert(song, request);
      expect(after!.path, isNot(before!.path));
    });

    test('are not made without ffmpeg, which is said once', () async {
      final transcoder = Transcoder(p.join(folder.path, 'cache'), ffmpeg: 'no-such-program-for-wiretune');
      expect(await transcoder.isAvailable, isFalse);
      expect(await transcoder.convert(track('x'), TranscodeRequest.parse('opus', '64')!), isNull);
    });

    test('are made a few at a time, and all of them are made', () async {
      final transcoder = Transcoder(p.join(folder.path, 'cache'), concurrency: 1);
      final request = TranscodeRequest.parse('opus', '64')!;
      final files = await Future.wait([
        for (final name in ['p', 'q', 'r']) transcoder.convert(track(name), request),
      ]);
      expect(files, everyElement(isNotNull));
      expect(files.map((f) => f!.path).toSet(), hasLength(3));
    });
  });
}
