// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/src/metadata/id3.dart' show inflateFrame;
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The pure-Dart tag reader against files encoded by ffmpeg (skipped without it) and files built byte by byte for the
/// formats ffmpeg cannot write (DSF, Monkey's Audio).
void main() {
  late Directory dir;
  final ffmpeg = hasTool('ffmpeg');

  setUpAll(() {
    useTempDataDirectory();
    dir = Directory.systemTemp.createTempSync('wiretune_tags_');
    if (!ffmpeg) return;

    void run(List<String> args) {
      final result = Process.runSync('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        ...args,
      ], workingDirectory: dir.path);
      if (result.exitCode != 0) throw StateError('ffmpeg failed: ${result.stderr}');
    }

    const meta = [
      '-metadata',
      'title=Tést Title',
      '-metadata',
      'artist=Ärtist',
      '-metadata',
      'album_artist=Album Ärtist',
      '-metadata',
      'album=Albüm',
      '-metadata',
      'track=3/12',
      '-metadata',
      'disc=1/2',
      '-metadata',
      'date=2001-05-02',
      '-metadata',
      'genre=Rock',
      '-metadata',
      'lyrics=la la la',
    ];
    List<String> sine(int rate) => [
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=2.5:sample_rate=$rate',
      '-ac',
      '2',
    ];

    run(['-f', 'lavfi', '-i', 'color=c=red:s=32x32', '-frames:v', '1', 'cover.png']);
    run([...sine(96000), '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', ...meta, 'plain.flac']);
    run([
      '-i',
      'plain.flac',
      '-i',
      'cover.png',
      '-map',
      '0:a',
      '-map',
      '1',
      '-c',
      'copy',
      '-disposition:v',
      'attached_pic',
      ...meta,
      't.flac',
    ]);
    run([...sine(44100), '-c:a', 'libmp3lame', '-b:a', '320k', ...meta, '-id3v2_version', '3', 'plain.mp3']);
    run([
      '-i',
      'plain.mp3',
      '-i',
      'cover.png',
      '-map',
      '0:a',
      '-map',
      '1',
      '-c',
      'copy',
      '-id3v2_version',
      '4',
      '-disposition:v',
      'attached_pic',
      't.mp3',
    ]);
    run([...sine(48000), '-c:a', 'aac', '-b:a', '256k', ...meta, 'plain.m4a']);
    run([
      '-i',
      'plain.m4a',
      '-i',
      'cover.png',
      '-map',
      '0:a',
      '-map',
      '1',
      '-c',
      'copy',
      '-disposition:v',
      'attached_pic',
      't.m4a',
    ]);
    run([...sine(44100), '-c:a', 'alac', '-sample_fmt', 's32p', ...meta, 'alac.m4a']);
    run([...sine(44100), '-c:a', 'libvorbis', '-b:a', '192k', ...meta, 't.ogg']);
    run([...sine(48000), '-c:a', 'libopus', '-b:a', '128k', ...meta, 't.opus']);
    run([...sine(44100), '-c:a', 'wavpack', ...meta, 't.wv']);
    run([...sine(88200), '-c:a', 'pcm_s24le', ...meta, 't.wav']);
    run([...sine(44100), '-c:a', 'pcm_s16be', '-write_id3v2', '1', ...meta, 't.aiff']);
    run([...sine(44100), '-c:a', 'aac', '-b:a', '128k', '-f', 'adts', 't.aac']);
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  String path(String name) => p.join(dir.path, name);

  void expectTags(AudioTags? tags, {bool albumArtist = true, bool disc = true, bool lyrics = true}) {
    expect(tags, isNotNull);
    expect(tags!.title, 'Tést Title');
    expect(tags.artist, 'Ärtist');
    if (albumArtist) expect(tags.albumArtist, 'Album Ärtist');
    expect(tags.album, 'Albüm');
    expect(tags.track, 3);
    expect(tags.trackCount, 12);
    if (disc) expect(tags.disc, 1);
    expect(tags.year, 2001);
    expect(tags.genre, 'Rock');
    if (lyrics) expect(tags.lyrics, 'la la la');
  }

  void expectLength(AudioTags tags, [double seconds = 2.5]) =>
      expect(tags.duration.inMilliseconds / 1000, closeTo(seconds, 0.1));

  group('encoded by ffmpeg', skip: ffmpeg ? false : 'ffmpeg is not installed', () {
    test('FLAC: Vorbis comment, STREAMINFO and the PICTURE block', () {
      final tags = TagReader.read(path('t.flac'), wantLyrics: true)!;
      expectTags(tags);
      expectLength(tags);
      expect((tags.sampleRate, tags.bitsPerSample, tags.channels), (96000, 24, 2));
      expect(tags.hasPicture, isTrue);
      expect(TagReader.readPicture(path('t.flac')), File(path('cover.png')).readAsBytesSync());
      expect(TagReader.read(path('plain.flac'))!.hasPicture, isFalse);
    });

    test('MP3: ID3v2.3 text frames, the Info header and an ID3v2.4 picture', () {
      final tags = TagReader.read(path('plain.mp3'))!;
      expectTags(tags, lyrics: false); // ffmpeg writes "lyrics" as TXXX, not as a lyrics frame
      expectLength(tags);
      expect((tags.sampleRate, tags.channels), (44100, 2));
      expect(tags.bitrateKbps, closeTo(320, 5));
      expect(TagReader.readPicture(path('t.mp3')), File(path('cover.png')).readAsBytesSync());
    });

    test('M4A: AAC sample entry, ilst atoms and covr', () {
      final tags = TagReader.read(path('t.m4a'), wantLyrics: true)!;
      expectTags(tags);
      expectLength(tags);
      expect(tags.codecDescription, 'mp4a');
      expect(tags.sampleRate, 48000);
      expect(tags.bitrateKbps, inInclusiveRange(200, 270));
      expect(TagReader.readPicture(path('t.m4a')), File(path('cover.png')).readAsBytesSync());
    });

    test('M4A: ALAC is recognised as lossless with its bit depth', () {
      final tags = TagReader.read(path('alac.m4a'))!;
      expect(tags.codecDescription, 'alac');
      expect(AudioFileTypes.describe(path('alac.m4a'), tags.codecDescription), ('ALAC', true));
      expect((tags.sampleRate, tags.bitsPerSample), (44100, 24));
      expectLength(tags);
    });

    test('Ogg Vorbis and Opus: comment packets and the last granule', () {
      final vorbis = TagReader.read(path('t.ogg'), wantLyrics: true)!;
      expectTags(vorbis);
      expectLength(vorbis);
      expect((vorbis.sampleRate, vorbis.bitrateKbps), (44100, 192));

      final opus = TagReader.read(path('t.opus'), wantLyrics: true)!;
      expectTags(opus);
      expectLength(opus);
      expect(opus.sampleRate, 48000);
    });

    test('WavPack: block header and APEv2 tag', () {
      final tags = TagReader.read(path('t.wv'), wantLyrics: true)!;
      expectTags(tags);
      expectLength(tags);
      expect((tags.sampleRate, tags.bitsPerSample, tags.channels), (44100, 16, 2));
    });

    test('WAV: fmt and data chunks, LIST INFO', () {
      final tags = TagReader.read(path('t.wav'))!;
      expectTags(tags, albumArtist: false, disc: false, lyrics: false); // INFO has no such fields
      expectLength(tags);
      expect((tags.sampleRate, tags.bitsPerSample, tags.bitrateKbps), (88200, 24, 4234));
    });

    test('AIFF: COMM with its 80-bit rate, and the ID3 chunk', () {
      final tags = TagReader.read(path('t.aiff'))!;
      expectTags(tags, lyrics: false);
      expectLength(tags);
      expect((tags.sampleRate, tags.bitsPerSample, tags.bitrateKbps), (44100, 16, 1411));
    });

    test('AAC in ADTS: no tags, but rate and length', () {
      final tags = TagReader.read(path('t.aac'))!;
      expect(tags.title, isNull);
      expect(tags.sampleRate, 44100);
      expectLength(tags);
    });

    test('the scanner turns a tagged file into a track', () async {
      final covers = p.join(dir.path, 'covers');
      final track = (await MetadataScanner().readTrackMetadata(path('t.flac'), coverCacheDirectory: covers))!;
      expect(track.title, 'Tést Title');
      expect(track.albumArtist, 'Album Ärtist');
      expect(track.format.codec, 'FLAC');
      expect(track.format.isHiRes, isTrue);
      expect(track.hasCoverArt, isTrue);
      expect(File(track.coverArtPath!).readAsBytesSync(), File(path('cover.png')).readAsBytesSync());
      expect(p.basename(track.coverArtPath!), endsWith('.png'));
      expect(track.id, MetadataScanner.computeTrackId(path('t.flac')));

      final mp3 = (await MetadataScanner().readTrackMetadata(path('plain.mp3')))!;
      expect((mp3.format.codec, mp3.format.isLossless, mp3.format.bitsPerSample), ('MP3', false, 0));

      expect(await MetadataScanner.readLyrics(path('t.flac')), 'la la la');
      expect(await MetadataScanner().extractCoverArt(path('t.m4a')), File(path('cover.png')).readAsBytesSync());
    });
  });

  test(
    'FLAC: STREAMINFO, and of two Vorbis comment fields for one tag the one that ranks first, whatever the order',
    () {
      final file = path('built.flac');
      File(file).writeAsBytesSync(
        _buildFlac(['TRACKTOTAL=20', 'ENSEMBLE=The Orchestra', 'TRACKNUMBER=3/12', 'ALBUMARTIST=The Conductor']),
      );
      final tags = TagReader.read(file)!;
      expect(tags.albumArtist, 'The Conductor'); // ALBUMARTIST outranks ENSEMBLE
      expect((tags.track, tags.trackCount), (3, 12)); // TRACKNUMBER's own total outranks TRACKTOTAL
      expect((tags.sampleRate, tags.bitsPerSample, tags.channels), (44100, 16, 2));
      expect(tags.duration, const Duration(seconds: 2));
    },
  );

  test('DSF: the DSD and fmt chunks and the ID3 tag at the metadata offset', () {
    final file = path('built.dsf');
    File(file).writeAsBytesSync(_buildDsf());
    final tags = TagReader.read(file)!;
    expect(tags.title, 'DSD Song');
    expect(tags.artist, 'DSD Artist');
    expect((tags.sampleRate, tags.bitsPerSample, tags.channels), (2822400, 1, 2));
    expect(tags.duration, const Duration(seconds: 3));
    expect(
      AudioFormat(codec: 'DSD', sampleRate: tags.sampleRate, bitsPerSample: tags.bitsPerSample).tier,
      QualityTier.gold,
    );
  });

  test("Monkey's Audio: the descriptor, the header and the APEv2 tag (with a cover)", () {
    final file = path('built.ape');
    File(file).writeAsBytesSync(_buildApe());
    final tags = TagReader.read(file, wantLyrics: true)!;
    expect(tags.title, 'APE Song');
    expect(tags.artist, 'APE Artist');
    expect(tags.album, 'APE Album');
    expect(tags.track, 7);
    expect(tags.trackCount, 9);
    expect(tags.year, 1999);
    expect(tags.lyrics, 'words');
    expect((tags.sampleRate, tags.bitsPerSample, tags.channels), (44100, 16, 2));
    expect(tags.duration.inMicroseconds / 1e6, closeTo((294912 + 100000) / 44100, 0.001));
    expect(TagReader.readPicture(file), [1, 2, 3, 4]);
  });

  test('a compressed ID3 frame is inflated, but never beyond what a tag can need', () {
    final text = utf8.encode('\u0000A compressed title');
    expect(inflateFrame(Uint8List.fromList(zlib.encode(text))), text);
    // 64 MB of zeros squeezes into about 64 KB: read as it inflates, it is given up on, not held in memory.
    final bomb = Uint8List.fromList(zlib.encode(Uint8List(64 * 1024 * 1024)));
    expect(bomb.length, lessThan(1024 * 1024));
    expect(inflateFrame(bomb), isNull);
    expect(inflateFrame(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('a file that is not audio is not read, and a file with a wrong extension is sniffed', () {
    final garbage = path('garbage.flac');
    File(garbage).writeAsBytesSync(List.filled(4096, 7));
    expect(TagReader.read(garbage), isNull);

    final wav = path('really-a-wav.mp3');
    writeWav(wav, 44100, seconds: 0.5);
    final tags = TagReader.read(wav)!;
    expect(tags.sampleRate, 44100);
    expect(tags.duration, const Duration(milliseconds: 500));
  });

  test('a truncated file does not throw', () {
    final file = path('truncated.flac');
    File(file).writeAsBytesSync([...ascii.encode('fLaC'), 0x00, 0x00, 0x00, 0x22, 1, 2, 3]);
    expect(() => TagReader.read(file), returnsNormally);
  });
}

List<int> _id3v23(Map<String, String> frames) {
  final body = BytesBuilder();
  frames.forEach((id, text) {
    final data = [3, ...utf8.encode(text)]; // UTF-8
    body
      ..add(ascii.encode(id))
      ..add(_u32be(data.length))
      ..add([0, 0])
      ..add(data);
  });
  final size = body.length;
  return [
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...body.takeBytes(),
  ];
}

List<int> _u32be(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// A FLAC file: STREAMINFO (44.1 kHz, 16 bit, stereo, two seconds), a Vorbis comment with [comments], and some "audio".
Uint8List _buildFlac(List<String> comments) {
  const sampleRate = 44100, channels = 2, bits = 16, samples = 2 * sampleRate;
  const packed = sampleRate << 44 | (channels - 1) << 41 | (bits - 1) << 36 | samples;
  final info = [...List.filled(10, 0), ..._u32be(packed >> 32), ..._u32be(packed & 0xFFFFFFFF), ...List.filled(16, 0)];
  final vendor = utf8.encode('wiretune test');
  final comment = BytesBuilder()
    ..add(_u32le(vendor.length))
    ..add(vendor)
    ..add(_u32le(comments.length));
  for (final entry in comments.map(utf8.encode)) {
    comment
      ..add(_u32le(entry.length))
      ..add(entry);
  }
  List<int> header(int type, int length, {bool last = false}) => [(last ? 0x80 : 0) | type, ..._u32be(length).skip(1)];
  return (BytesBuilder()
        ..add(ascii.encode('fLaC'))
        ..add(header(0, info.length))
        ..add(info)
        ..add(header(4, comment.length, last: true))
        ..add(comment.takeBytes())
        ..add(List.filled(4096, 0)))
      .takeBytes();
}

List<int> _u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> _u64le(int v) => [..._u32le(v & 0xFFFFFFFF), ..._u32le(v >> 32)];

Uint8List _buildDsf() {
  const audio = 4096 * 2;
  final metadataOffset = 28 + 52 + 12 + audio;
  final tag = _id3v23({'TIT2': 'DSD Song', 'TPE1': 'DSD Artist'});
  final total = metadataOffset + tag.length;
  return Uint8List.fromList([
    ...ascii.encode('DSD '),
    ..._u64le(28),
    ..._u64le(total),
    ..._u64le(metadataOffset),
    ...ascii.encode('fmt '),
    ..._u64le(52),
    ..._u32le(1),
    ..._u32le(0),
    ..._u32le(2),
    ..._u32le(2),
    ..._u32le(2822400),
    ..._u32le(1),
    ..._u64le(2822400 * 3),
    ..._u32le(4096),
    ..._u32le(0),
    ...ascii.encode('data'),
    ..._u64le(12 + audio),
    ...List.filled(audio, 0x69),
    ...tag,
  ]);
}

Uint8List _buildApe() {
  List<int> item(String key, List<int> value, {bool binary = false}) => [
    ..._u32le(value.length),
    ..._u32le(binary ? 2 : 0),
    ...ascii.encode(key),
    0,
    ...value,
  ];
  final items = [
    ...item('Title', utf8.encode('APE Song')),
    ...item('Artist', utf8.encode('APE Artist')),
    ...item('Album', utf8.encode('APE Album')),
    ...item('Track', utf8.encode('7/9')),
    ...item('Year', utf8.encode('1999')),
    ...item('Lyrics', utf8.encode('words')),
    ...item('Cover Art (Front)', [...ascii.encode('cover.jpg'), 0, 1, 2, 3, 4], binary: true),
  ];
  const count = 7;
  final size = items.length + 32;
  List<int> headerOrFooter(int flags) => [
    ...ascii.encode('APETAGEX'),
    ..._u32le(2000),
    ..._u32le(size),
    ..._u32le(count),
    ..._u32le(flags),
    ...List.filled(8, 0),
  ];

  final descriptor = [
    ...ascii.encode('MAC '),
    ..._u16le(3990),
    0,
    0,
    ..._u32le(52),
    ..._u32le(24),
    ..._u32le(0),
    ..._u32le(0),
    ..._u32le(1000),
    ..._u32le(0),
    ..._u32le(0),
    ...List.filled(16, 0),
  ];
  final header = [
    ..._u16le(2000),
    ..._u16le(0),
    ..._u32le(294912),
    ..._u32le(100000),
    ..._u32le(2),
    ..._u16le(16),
    ..._u16le(2),
    ..._u32le(44100),
  ];
  return Uint8List.fromList([
    ...descriptor,
    ...header,
    ...List.filled(1000, 0x42),
    ...headerOrFooter(0xA0000000),
    ...items,
    ...headerOrFooter(0x80000000),
  ]);
}
