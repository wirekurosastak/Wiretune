// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';
import 'dart:typed_data';

import 'audio_tags.dart';
import 'byte_source.dart';

/// The genres an ID3v1 byte (and an ID3v2 "(17)" reference, and MP4's `gnre`) can name.
const List<String> id3Genres = [
  'Blues',
  'Classic Rock',
  'Country',
  'Dance',
  'Disco',
  'Funk',
  'Grunge',
  'Hip-Hop',
  'Jazz',
  'Metal',
  'New Age',
  'Oldies',
  'Other',
  'Pop',
  'R&B',
  'Rap',
  'Reggae',
  'Rock',
  'Techno',
  'Industrial',
  'Alternative',
  'Ska',
  'Death Metal',
  'Pranks',
  'Soundtrack',
  'Euro-Techno',
  'Ambient',
  'Trip-Hop',
  'Vocal',
  'Jazz+Funk',
  'Fusion',
  'Trance',
  'Classical',
  'Instrumental',
  'Acid',
  'House',
  'Game',
  'Sound Clip',
  'Gospel',
  'Noise',
  'Alternative Rock',
  'Bass',
  'Soul',
  'Punk',
  'Space',
  'Meditative',
  'Instrumental Pop',
  'Instrumental Rock',
  'Ethnic',
  'Gothic',
  'Darkwave',
  'Techno-Industrial',
  'Electronic',
  'Pop-Folk',
  'Eurodance',
  'Dream',
  'Southern Rock',
  'Comedy',
  'Cult',
  'Gangsta',
  'Top 40',
  'Christian Rap',
  'Pop/Funk',
  'Jungle',
  'Native American',
  'Cabaret',
  'New Wave',
  'Psychedelic',
  'Rave',
  'Showtunes',
  'Trailer',
  'Lo-Fi',
  'Tribal',
  'Acid Punk',
  'Acid Jazz',
  'Polka',
  'Retro',
  'Musical',
  'Rock & Roll',
  'Hard Rock',
  'Folk',
  'Folk-Rock',
  'National Folk',
  'Swing',
  'Fast Fusion',
  'Bebop',
  'Latin',
  'Revival',
  'Celtic',
  'Bluegrass',
  'Avantgarde',
  'Gothic Rock',
  'Progressive Rock',
  'Psychedelic Rock',
  'Symphonic Rock',
  'Slow Rock',
  'Big Band',
  'Chorus',
  'Easy Listening',
  'Acoustic',
  'Humour',
  'Speech',
  'Chanson',
  'Opera',
  'Chamber Music',
  'Sonata',
  'Symphony',
  'Booty Bass',
  'Primus',
  'Porn Groove',
  'Satire',
  'Slow Jam',
  'Club',
  'Tango',
  'Samba',
  'Folklore',
  'Ballad',
  'Power Ballad',
  'Rhythmic Soul',
  'Freestyle',
  'Duet',
  'Punk Rock',
  'Drum Solo',
  'A Cappella',
  'Euro-House',
  'Dance Hall',
  'Goa',
  'Drum & Bass',
  'Club-House',
  'Hardcore',
  'Terror',
  'Indie',
  'Britpop',
  'Negerpunk',
  'Polsk Punk',
  'Beat',
  'Christian Gangsta Rap',
  'Heavy Metal',
  'Black Metal',
  'Crossover',
  'Contemporary Christian',
  'Christian Rock',
  'Merengue',
  'Salsa',
  'Thrash Metal',
  'Anime',
  'Jpop',
  'Synthpop',
  'Abstract',
  'Art Rock',
  'Baroque',
  'Bhangra',
  'Big Beat',
  'Breakbeat',
  'Chillout',
  'Downtempo',
  'Dub',
  'EBM',
  'Eclectic',
  'Electro',
  'Electroclash',
  'Emo',
  'Experimental',
  'Garage',
  'Global',
  'IDM',
  'Illbient',
  'Industro-Goth',
  'Jam Band',
  'Krautrock',
  'Leftfield',
  'Lounge',
  'Math Rock',
  'New Romantic',
  'Nu-Breakz',
  'Post-Punk',
  'Post-Rock',
  'Psytrance',
  'Shoegaze',
  'Space Rock',
  'Trop Rock',
  'World Music',
  'Neoclassical',
  'Audiobook',
  'Audio Theatre',
  'Neue Deutsche Welle',
  'Podcast',
  'Indie Rock',
  'G-Funk',
  'Dubstep',
  'Garage Rock',
  'Psybient',
];

String? genreByIndex(int index) => index >= 0 && index < id3Genres.length ? id3Genres[index] : null;

/// Resolves the genre references ID3v2 allows: "(17)", "(17)Rock", "17", "RX", "CR".
String? resolveId3Genre(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final reference = RegExp(r'^\((\d+)\)(.*)$').firstMatch(text);
  if (reference != null) {
    final refined = reference.group(2)!.trim();
    return refined.isNotEmpty ? refined : genreByIndex(int.parse(reference.group(1)!));
  }
  if (RegExp(r'^\d+$').hasMatch(text)) return genreByIndex(int.parse(text)) ?? text;
  if (text == 'RX' || text == '(RX)') return 'Remix';
  if (text == 'CR' || text == '(CR)') return 'Cover';
  return text;
}

/// The size of an ID3v2 tag that starts at [offset] (header, frames and footer), or 0 when there is none.
int id3v2SizeAt(ByteSource source, int offset) {
  final header = source.readExact(offset, 10);
  if (header == null || !header.matches(0, 'ID3') || header[3] > 4 || header[3] < 2) return 0;
  final hasFooter = header[3] == 4 && (header[5] & 0x10) != 0;
  return 10 + header.syncsafe32(6) + (hasFooter ? 10 : 0);
}

/// The end of all ID3v2 tags at the start of the file (some files carry more than one).
int skipLeadingId3v2(ByteSource source) {
  var offset = 0;
  for (var i = 0; i < 4; i++) {
    final size = id3v2SizeAt(source, offset);
    if (size == 0) break;
    offset += size;
    // Padding between tags and audio is not unusual.
    final probe = source.read(offset, 4096);
    var skip = 0;
    while (skip < probe.length && probe[skip] == 0) {
      skip++;
    }
    if (skip < probe.length) offset += skip;
  }
  return offset;
}

const Map<String, TagField> _v23Frames = {
  'TIT2': TagField.title,
  'TPE1': TagField.artist,
  'TPE2': TagField.albumArtist,
  'TALB': TagField.album,
  'TCON': TagField.genre,
  'TRCK': TagField.track,
  'TPOS': TagField.disc,
  'TYER': TagField.year,
  'TDRC': TagField.year,
  'TORY': TagField.year,
  'TDOR': TagField.year,
  'TBPM': TagField.bpm,
};

const Map<String, TagField> _v22Frames = {
  'TT2': TagField.title,
  'TP1': TagField.artist,
  'TP2': TagField.albumArtist,
  'TAL': TagField.album,
  'TCO': TagField.genre,
  'TRK': TagField.track,
  'TPA': TagField.disc,
  'TYE': TagField.year,
  'TOR': TagField.year,
  'TBP': TagField.bpm,
};

/// Reads the ID3v2 tag at [offset]; null when there is none or it cannot be read.
AudioTags? readId3v2(ByteSource source, int offset, {bool wantLyrics = true}) {
  final header = source.readExact(offset, 10);
  if (header == null || !header.matches(0, 'ID3')) return null;
  final major = header[3];
  if (major < 2 || major > 4) return null;
  final flags = header[5];
  final size = header.syncsafe32(6);
  if (size <= 0 || offset + 10 + size > source.length + 10) return null;

  final tags = AudioTags();
  final unsynchronised = (flags & 0x80) != 0;

  // An unsynchronised tag (rare) must be decoded as a whole; otherwise frames are read one by one and big frames
  // (pictures) are only located.
  if (unsynchronised && major < 4) {
    if (size > 64 * 1024 * 1024) return null;
    final raw = source.read(offset + 10, size);
    final data = _removeUnsynchronisation(raw);
    _readFramesInMemory(data, major, flags, tags, wantLyrics);
    return tags;
  }

  var position = offset + 10;
  final end = offset + 10 + size;

  if ((flags & 0x40) != 0) {
    // Extended header: v2.3 counts its size without the size field, v2.4 with it (and synchsafe).
    final ext = source.readExact(position, 4);
    if (ext == null) return tags;
    position += major == 4 ? ext.syncsafe32(0) : ext.u32be(0) + 4;
  }

  final headerSize = major == 2 ? 6 : 10;
  while (position + headerSize <= end) {
    final frameHeader = source.readExact(position, headerSize);
    if (frameHeader == null || frameHeader[0] == 0) break; // padding

    final String id;
    final int frameSize;
    var formatFlags = 0;
    if (major == 2) {
      id = frameHeader.ascii(0, 3);
      frameSize = frameHeader.u24be(3);
    } else {
      id = frameHeader.ascii(0, 4);
      frameSize = major == 4 ? frameHeader.syncsafe32(4) : frameHeader.u32be(4);
      formatFlags = frameHeader[9];
    }
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id) || frameSize <= 0 || position + headerSize + frameSize > end) break;

    final bodyOffset = position + headerSize;
    position = bodyOffset + frameSize;

    final wantsFrame = _isWanted(id, major, wantLyrics);
    if (!wantsFrame) continue;

    final isPicture = id == 'APIC' || id == 'PIC';
    final frameUnsync = major == 4 && ((formatFlags & 0x02) != 0 || unsynchronised);
    final compressed = major == 3 ? (formatFlags & 0x80) != 0 : major == 4 && (formatFlags & 0x08) != 0;
    final encrypted = major == 3 ? (formatFlags & 0x40) != 0 : major == 4 && (formatFlags & 0x04) != 0;
    if (encrypted) continue;

    // A picture frame that needs no decoding is only located: its header fields are read, its data is not.
    if (isPicture && !frameUnsync && !compressed) {
      _locatePicture(source, bodyOffset, frameSize, major, formatFlags, tags);
      continue;
    }

    if (frameSize > 32 * 1024 * 1024) continue;
    var body = source.read(bodyOffset, frameSize);
    var start = 0;
    if (major == 3 && (formatFlags & 0x20) != 0) start += 1; // grouping identity
    if (major == 4 && (formatFlags & 0x40) != 0) start += 1; // grouping identity
    if (major == 3 && compressed) start += 4; // decompressed size
    if (major == 4 && (formatFlags & 0x01) != 0) start += 4; // data length indicator
    if (start > body.length) continue;
    body = Uint8List.sublistView(body, start);
    if (frameUnsync) body = _removeUnsynchronisation(body);
    if (compressed) {
      try {
        body = Uint8List.fromList(ZLibCodec().decode(body));
      } catch (_) {
        continue;
      }
    }
    _readFrame(id, body, major, tags);
  }
  return tags;
}

bool _isWanted(String id, int major, bool wantLyrics) {
  if (major == 2) return _v22Frames.containsKey(id) || id == 'PIC' || (wantLyrics && id == 'ULT');
  return _v23Frames.containsKey(id) || id == 'APIC' || (wantLyrics && id == 'USLT');
}

void _readFramesInMemory(Uint8List data, int major, int flags, AudioTags tags, bool wantLyrics) {
  var position = 0;
  if ((flags & 0x40) != 0 && data.length >= 4) position += data.u32be(0) + 4;
  final headerSize = major == 2 ? 6 : 10;
  while (position + headerSize <= data.length) {
    if (data[position] == 0) break;
    final id = data.ascii(position, major == 2 ? 3 : 4);
    final size = major == 2 ? data.u24be(position + 3) : data.u32be(position + 4);
    final formatFlags = major == 2 ? 0 : data[position + 9];
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id) || size <= 0 || position + headerSize + size > data.length) break;
    var body = Uint8List.sublistView(data, position + headerSize, position + headerSize + size);
    position += headerSize + size;
    if (!_isWanted(id, major, wantLyrics)) continue;
    if (major == 3 && (formatFlags & 0x40) != 0) continue;
    var start = 0;
    if (major == 3 && (formatFlags & 0x20) != 0) start += 1;
    if (major == 3 && (formatFlags & 0x80) != 0) start += 4;
    if (start > body.length) continue;
    body = Uint8List.sublistView(body, start);
    if (major == 3 && (formatFlags & 0x80) != 0) {
      try {
        body = Uint8List.fromList(ZLibCodec().decode(body));
      } catch (_) {
        continue;
      }
    }
    _readFrame(id, body, major, tags);
  }
}

void _readFrame(String id, Uint8List body, int major, AudioTags tags) {
  if (body.isEmpty) return;
  if (id == 'APIC' || id == 'PIC') {
    final picture = _parsePicture(body, major);
    if (picture != null) tags.offerPicture(data: picture.$1, type: picture.$2);
    return;
  }
  if (id == 'USLT' || id == 'ULT') {
    if (body.length < 4) return;
    final encoding = body[0];
    final rest = Uint8List.sublistView(body, 4);
    final descriptionEnd = _terminatorEnd(rest, 0, encoding);
    tags.setText(TagField.lyrics, _decodeText(Uint8List.sublistView(rest, descriptionEnd), encoding));
    return;
  }

  final field = major == 2 ? _v22Frames[id] : _v23Frames[id];
  if (field == null) return;
  final values = _decodeTextFrame(body);
  for (final value in values) {
    final text = field == TagField.genre ? resolveId3Genre(value) : value;
    if (text != null && text.trim().isNotEmpty) {
      tags.setText(field, text);
      break;
    }
  }
}

/// The strings of a text frame (v2.4 separates several values with NUL).
List<String> _decodeTextFrame(Uint8List body) {
  final encoding = body[0];
  final data = Uint8List.sublistView(body, 1);
  final values = <String>[];
  var start = 0;
  while (start < data.length) {
    final end = _terminatorStart(data, start, encoding);
    values.add(_decodeText(Uint8List.sublistView(data, start, end), encoding));
    start = end + (encoding == 1 || encoding == 2 ? 2 : 1);
  }
  return values.map(trimNul).where((v) => v.isNotEmpty).toList();
}

String _decodeText(Uint8List bytes, int encoding) => trimNul(switch (encoding) {
  1 => decodeUtf16(bytes, littleEndian: true),
  2 => decodeUtf16(bytes),
  3 => decodeUtf8(bytes),
  _ => decodeLatin1(bytes),
});

/// Index of the NUL terminator at or after [start] (the end of [data] when there is none).
int _terminatorStart(Uint8List data, int start, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = start; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i;
    }
    return data.length;
  }
  for (var i = start; i < data.length; i++) {
    if (data[i] == 0) return i;
  }
  return data.length;
}

/// Index just past the NUL terminator at or after [start].
int _terminatorEnd(Uint8List data, int start, int encoding) {
  final end = _terminatorStart(data, start, encoding);
  final width = encoding == 1 || encoding == 2 ? 2 : 1;
  return end + width > data.length ? data.length : end + width;
}

/// (picture bytes, picture type) of an APIC/PIC frame body.
(Uint8List, int)? _parsePicture(Uint8List body, int major) {
  final header = _pictureHeaderLength(body, major);
  if (header == null || header.$1 >= body.length) return null;
  return (Uint8List.fromList(Uint8List.sublistView(body, header.$1)), header.$2);
}

/// (length of the fields before the picture data, picture type), from the start of an APIC/PIC body.
(int, int)? _pictureHeaderLength(Uint8List body, int major) {
  if (body.length < 4) return null;
  final encoding = body[0];
  int position;
  if (major == 2) {
    position = 4; // encoding, 3-letter image format
  } else {
    position = _terminatorEnd(body, 1, 0); // MIME type, Latin-1
  }
  if (position >= body.length) return null;
  final type = body[position];
  position = _terminatorEnd(body, position + 1, encoding); // description
  return (position, type);
}

void _locatePicture(ByteSource source, int bodyOffset, int frameSize, int major, int formatFlags, AudioTags tags) {
  var skip = 0;
  if (major == 3 && (formatFlags & 0x20) != 0) skip += 1;
  if (major == 4 && (formatFlags & 0x40) != 0) skip += 1;
  if (major == 4 && (formatFlags & 0x01) != 0) skip += 4;
  // The fields before the data (MIME type, description) are short; read enough of them to find where the data starts.
  final head = source.read(bodyOffset + skip, frameSize - skip < 2048 ? frameSize - skip : 2048);
  final header = _pictureHeaderLength(head, major);
  if (header == null || header.$1 >= head.length && head.length < frameSize - skip) return;
  final dataOffset = bodyOffset + skip + header.$1;
  final dataLength = bodyOffset + frameSize - dataOffset;
  if (dataLength <= 0) return;
  tags.offerPicture(location: PictureLocation(dataOffset, dataLength), type: header.$2);
}

Uint8List _removeUnsynchronisation(Uint8List data) {
  final buffer = Uint8List(data.length);
  var n = 0;
  for (var i = 0; i < data.length; i++) {
    buffer[n++] = data[i];
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) i++;
  }
  return Uint8List.sublistView(buffer, 0, n);
}

/// Reads the 128-byte ID3v1 tag at the end of the file; null when there is none.
AudioTags? readId3v1(ByteSource source) {
  if (source.length < 128) return null;
  final data = source.readExact(source.length - 128, 128);
  if (data == null || !data.matches(0, 'TAG')) return null;
  final tags = AudioTags();
  String field(int offset, int length) => trimNul(decodeLatin1(Uint8List.sublistView(data, offset, offset + length)));
  tags.setText(TagField.title, field(3, 30));
  tags.setText(TagField.artist, field(33, 30));
  tags.setText(TagField.album, field(63, 30));
  tags.setText(TagField.year, field(93, 4));
  if (data[125] == 0 && data[126] != 0) tags.track = data[126];
  final genre = genreByIndex(data[127]);
  if (genre != null) tags.genre = genre;
  return tags;
}

/// True when the file ends with an ID3v1 tag (the APE tag, if any, is in front of it).
bool hasId3v1(ByteSource source) {
  if (source.length < 128) return false;
  final data = source.readExact(source.length - 128, 3);
  return data != null && data.matches(0, 'TAG');
}
