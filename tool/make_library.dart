// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

// Makes a made-up library of the size you ask for, to see how the server and the player cope with a big one:
//
//   dart tool/make_library.dart /tmp/library 50000
//
// Every track is a tagged MP3 file whose audio is empty: it has three real frame headers and is then stretched to its
// length (a sparse file), so 100,000 tracks take next to no disk space. The tags are made from a seed, so the same
// count and seed make the same library. Artists have four albums of twelve tracks, some of two discs, some with a
// featured artist, and the names and genres have accents and mixed case, like a real collection.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const String _usage = '''
Makes a made-up library of tagged MP3 files (with empty audio, so they take next to no disk space).

Usage: dart tool/make_library.dart <folder> <tracks> [seed]

  folder   where the Artist/Album/NN - Title.mp3 files go (made when missing, nothing is deleted)
  tracks   how many tracks to make
  seed     a whole number; the same tracks and seed make the same library (default 1)''';

const int _albumsPerArtist = 4;
const int _tracksPerAlbum = 12;

const List<String> _words = [
  'Silver',
  'Night',
  'Éclat',
  'River',
  'Glass',
  'Hold',
  'Ember',
  'Nova',
  'Tides',
  'Álom',
  'Orbit',
  'Velvet',
  'Stone',
  'Fénykép',
  'Harbor',
  'Static',
  'Winter',
  'Lumière',
  'Echo',
  'Paper',
  'Garden',
  'Zenit',
  'Copper',
  'Mirror',
  'Kék',
  'Ghost',
  'Summer',
  'Ocean',
  'Fire',
  'Dust',
  'Moon',
  'Wild',
  'Hollow',
  'Neon',
  'Árvíz',
  'Cobalt',
  'Lantern',
  'Drift',
];

const List<String> _genres = [
  'Rock',
  'Pop',
  'Jazz',
  'Electronic',
  'Classical',
  'Hip-Hop',
  'Metal',
  'Folk',
  'Blues',
  'Soul',
  'Ambient',
  'Techno',
  'House',
  'Punk',
  'Reggae',
  'Country',
  'Funk',
  'Indie',
  'Soundtrack',
  'Disco',
];

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(_usage);
    exit(64);
  }
  final root = Directory(args[0]);
  final count = int.tryParse(args[1]);
  final seed = args.length == 3 ? int.tryParse(args[2]) : 1;
  if (count == null || count < 1 || seed == null) {
    stderr.writeln(_usage);
    exit(64);
  }

  final random = Random(seed);
  final watch = Stopwatch()..start();
  var made = 0;
  var artistIndex = 0;
  while (made < count) {
    final artist = _name(random, artistIndex++, 2);
    final albumCount = min(_albumsPerArtist, (count - made + _tracksPerAlbum - 1) ~/ _tracksPerAlbum);
    for (var a = 0; a < albumCount && made < count; a++) {
      final album = _name(random, artistIndex * 7 + a, 3);
      final genre = _genres[random.nextInt(_genres.length)];
      final year = 1970 + random.nextInt(57);
      final discs = random.nextInt(8) == 0 ? 2 : 1;
      final folder = Directory('${root.path}/${_safe(artist)}/${_safe(album)}')..createSync(recursive: true);
      final tracks = min(_tracksPerAlbum, count - made);
      for (var t = 0; t < tracks; t++) {
        final title = _name(random, made, 2 + random.nextInt(3));
        final disc = discs == 1 ? 1 : (t < tracks ~/ 2 ? 1 : 2);
        final number = discs == 1 ? t + 1 : (disc == 1 ? t + 1 : t - tracks ~/ 2 + 1);
        final featured = random.nextInt(10) == 0 ? ' feat. ${_name(random, made + 3, 2)}' : '';
        final seconds = 90 + random.nextInt(360);
        final tag = _id3({
          'TIT2': title,
          'TPE1': '$artist$featured',
          'TPE2': artist,
          'TALB': album,
          'TRCK': '$number/${discs == 1 ? tracks : tracks ~/ 2}',
          if (discs == 2) 'TPOS': '$disc/2',
          'TCON': genre,
          'TDRC': '$year',
          'TBPM': '${70 + random.nextInt(110)}',
        });
        _write(File('${folder.path}/${number.toString().padLeft(2, '0')} - ${_safe(title)}.mp3'), tag, seconds);
        made++;
      }
    }
    if (made % 5000 < _albumsPerArtist * _tracksPerAlbum) {
      stdout.writeln('$made / $count tracks (${watch.elapsed.inSeconds} s)');
    }
  }
  stdout.writeln('Made $made tracks in ${root.path} in ${watch.elapsed.inSeconds} s.');
}

/// [words] of [_words] joined by spaces; [salt] varies the choice.
String _name(Random random, int salt, int words) =>
    [for (var i = 0; i < words; i++) _words[(random.nextInt(_words.length) + salt * (i + 1)) % _words.length]]
        .join(' ');

/// [name] as a file name: what Windows and Linux both allow.
String _safe(String name) => name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

/// An ID3v2.4 tag with the text frames [fields] (UTF-8), padded to a round size.
Uint8List _id3(Map<String, String> fields) {
  final body = BytesBuilder();
  fields.forEach((id, text) {
    final data = utf8.encode(text);
    body.add(ascii.encode(id));
    body.add(_syncsafe(data.length + 1));
    body.add([0, 0, 3]); // no flags; encoding 3 is UTF-8
    body.add(data);
  });
  final bytes = body.takeBytes();
  return (BytesBuilder()
        ..add(ascii.encode('ID3'))
        ..add([4, 0, 0])
        ..add(_syncsafe(bytes.length))
        ..add(bytes))
      .takeBytes();
}

Uint8List _syncsafe(int value) =>
    Uint8List.fromList([(value >> 21) & 0x7F, (value >> 14) & 0x7F, (value >> 7) & 0x7F, value & 0x7F]);

/// The file: [tag], then three MPEG-1 layer 3 frame headers (128 kbit/s, 44.1 kHz), then empty audio up to [seconds].
void _write(File file, Uint8List tag, int seconds) {
  const frame = 417; // 144 × 128000 / 44100 bytes, without padding
  final audio = BytesBuilder();
  for (var i = 0; i < 3; i++) {
    audio.add([0xFF, 0xFB, 0x90, 0x00]);
    audio.add(Uint8List(frame - 4));
  }
  final output = file.openSync(mode: FileMode.write);
  try {
    output.writeFromSync(tag);
    output.writeFromSync(audio.takeBytes());
    output.truncateSync(tag.length + seconds * 16000);
  } finally {
    output.closeSync();
  }
}
