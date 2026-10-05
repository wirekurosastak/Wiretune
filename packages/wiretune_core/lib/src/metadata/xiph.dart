// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:typed_data';

import 'audio_tags.dart';
import 'byte_source.dart';
import 'id3.dart';

/// The Vorbis comment fields Wiretune reads. The order matters: of two fields for one tag, the one listed first wins.
const Map<String, TagField> _vorbisFields = {
  'TITLE': TagField.title,
  'ARTIST': TagField.artist,
  'ALBUMARTIST': TagField.albumArtist,
  'ALBUM ARTIST': TagField.albumArtist,
  'ALBUM_ARTIST': TagField.albumArtist,
  'ENSEMBLE': TagField.albumArtist,
  'ALBUM': TagField.album,
  'GENRE': TagField.genre,
  'TRACKNUMBER': TagField.track,
  'TRACKTOTAL': TagField.trackCount,
  'TOTALTRACKS': TagField.trackCount,
  'DISCNUMBER': TagField.disc,
  'DATE': TagField.year,
  'YEAR': TagField.year,
  'ORIGINALDATE': TagField.year,
  'LYRICS': TagField.lyrics,
  'UNSYNCEDLYRICS': TagField.lyrics,
  'UNSYNCED LYRICS': TagField.lyrics,
};

/// Reads a Vorbis comment block (FLAC's VORBIS_COMMENT, the comment packet of Ogg Vorbis and Opus) into [tags].
void readVorbisComment(Uint8List data, int offset, AudioTags tags, {bool wantLyrics = true}) {
  try {
    var position = offset;
    final vendorLength = data.u32le(position);
    position += 4 + vendorLength;
    final count = data.u32le(position);
    position += 4;
    // ALBUMARTIST outranks ENSEMBLE whatever their order, and TRACKNUMBER's own total outranks TRACKTOTAL.
    final values = <String, String>{};
    for (var i = 0; i < count && position + 4 <= data.length; i++) {
      final length = data.u32le(position);
      position += 4;
      if (length < 0 || position + length > data.length) break;
      final entry = decodeUtf8(Uint8List.sublistView(data, position, position + length));
      position += length;
      final equals = entry.indexOf('=');
      if (equals <= 0) continue;
      final key = entry.substring(0, equals).toUpperCase();
      final value = entry.substring(equals + 1);

      if (key == 'METADATA_BLOCK_PICTURE') {
        try {
          final picture = parseFlacPicture(base64.decode(value.trim()));
          if (picture != null) tags.offerPicture(data: picture.$1, type: picture.$2);
        } on FormatException {
          // Not base64: ignore.
        }
        continue;
      }
      if (key == 'COVERART') {
        try {
          tags.offerPicture(data: base64.decode(value.trim()), type: 3);
        } on FormatException {
          // ignore
        }
        continue;
      }
      values.putIfAbsent(key, () => value);
    }

    for (final MapEntry(:key, value: field) in _vorbisFields.entries) {
      final value = values[key];
      if (value == null || (field == TagField.lyrics && !wantLyrics)) continue;
      tags.setText(field, field == TagField.genre ? resolveId3Genre(value) : value);
    }
  } on RangeError {
    // A truncated comment block: keep what was read.
  }
}

/// (data, picture type) of a FLAC PICTURE block (also the payload of METADATA_BLOCK_PICTURE).
(Uint8List, int)? parseFlacPicture(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  try {
    var position = 0;
    final type = data.u32be(position);
    position += 4;
    final mimeLength = data.u32be(position);
    position += 4 + mimeLength;
    final descriptionLength = data.u32be(position);
    position += 4 + descriptionLength;
    position += 16; // width, height, depth, colours
    final length = data.u32be(position);
    position += 4;
    if (position + length > data.length || length == 0) return null;
    return (Uint8List.fromList(Uint8List.sublistView(data, position, position + length)), type);
  } on RangeError {
    return null;
  }
}

/// Reads a FLAC STREAMINFO block (at least 18 bytes) into [tags] and returns the stream's length in samples.
int _readStreamInfo(Uint8List info, AudioTags tags) {
  tags.sampleRate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
  tags.channels = ((info[12] >> 1) & 0x07) + 1;
  tags.bitsPerSample = (((info[12] & 0x01) << 4) | (info[13] >> 4)) + 1;
  return ((info[13] & 0x0F) << 32) | info.u32be(14);
}

/// FLAC: STREAMINFO for the properties, VORBIS_COMMENT for the tags, PICTURE blocks located for later.
AudioTags? readFlac(ByteSource source, {bool wantLyrics = true}) {
  final start = skipLeadingId3v2(source);
  final marker = source.readExact(start, 4);
  if (marker == null || !marker.matches(0, 'fLaC')) return null;

  final tags = AudioTags();
  var position = start + 4;
  var last = false;
  var totalSamples = 0;
  while (!last) {
    final header = source.readExact(position, 4);
    if (header == null) break;
    last = (header[0] & 0x80) != 0;
    final type = header[0] & 0x7F;
    final length = header.u24be(1);
    final body = position + 4;
    position = body + length;
    if (position > source.length) break;

    switch (type) {
      case 0: // STREAMINFO
        final info = source.readExact(body, 18);
        if (info != null) totalSamples = _readStreamInfo(info, tags);
      case 4: // VORBIS_COMMENT
        if (length > 64 * 1024 * 1024) break;
        readVorbisComment(source.read(body, length), 0, tags, wantLyrics: wantLyrics);
      case 6: // PICTURE
        final head = source.read(body, length < 4096 ? length : 4096);
        try {
          final pictureType = head.u32be(0);
          var p = 4;
          p += 4 + head.u32be(p);
          p += 4 + head.u32be(p);
          p += 16;
          final dataLength = head.u32be(p);
          p += 4;
          if (dataLength > 0 && p + dataLength <= length) {
            tags.offerPicture(location: PictureLocation(body + p, dataLength), type: pictureType);
          }
        } on RangeError {
          // A picture block whose header does not fit what was read: ignore it.
        }
    }
  }

  if (tags.sampleRate > 0 && totalSamples > 0) {
    tags.duration = Duration(microseconds: (totalSamples * 1000000) ~/ tags.sampleRate);
    final audioBytes = source.length - position;
    final seconds = totalSamples / tags.sampleRate;
    if (seconds > 0 && audioBytes > 0) tags.bitrateKbps = (audioBytes * 8 / seconds / 1000).round();
  }

  // Tags in the wrong place (an ID3v2 tag before fLaC, ID3v1 at the end) fill what the Vorbis comment lacks.
  if (start > 0) {
    final id3 = readId3v2(source, 0, wantLyrics: wantLyrics);
    if (id3 != null) tags.mergeFrom(id3);
  }
  final v1 = readId3v1(source);
  if (v1 != null) tags.mergeFrom(v1);
  return tags;
}

/// Reads the first [count] packets of the first logical stream of an Ogg file, stopping at [maxBytes].
List<Uint8List> readOggPackets(ByteSource source, int count, {int maxBytes = 32 * 1024 * 1024}) {
  final packets = <Uint8List>[];
  var current = BytesBuilder(copy: false);
  var position = 0;
  int? serial;
  var total = 0;
  while (packets.length < count && position + 27 <= source.length) {
    final header = source.readExact(position, 27);
    if (header == null || !header.matches(0, 'OggS')) break;
    final pageSerial = header.u32le(14);
    final segments = header[26];
    final table = source.readExact(position + 27, segments);
    if (table == null) break;
    var bodyLength = 0;
    for (final s in table) {
      bodyLength += s;
    }
    final bodyOffset = position + 27 + segments;
    position = bodyOffset + bodyLength;
    serial ??= pageSerial;
    if (pageSerial != serial) continue;

    final body = source.read(bodyOffset, bodyLength);
    var p = 0;
    for (final s in table) {
      if (p + s > body.length) break;
      current.add(Uint8List.sublistView(body, p, p + s));
      p += s;
      total += s;
      if (s < 255) {
        packets.add(current.takeBytes());
        current = BytesBuilder(copy: false);
        if (packets.length >= count) break;
      }
    }
    if (total > maxBytes) break;
  }
  return packets;
}

/// The granule position of the last page of the stream [serial] (the stream's length in samples), or 0.
int lastOggGranule(ByteSource source, int serial) {
  const chunk = 65536;
  var end = source.length;
  while (end > 0) {
    final start = end - chunk < 0 ? 0 : end - chunk;
    // Overlap the next chunk by a page header, so a header split by the chunk boundary is still found.
    final readEnd = end + 27 > source.length ? source.length : end + 27;
    final data = source.read(start, readEnd - start);
    for (var i = data.length - 27; i >= 0; i--) {
      if (data[i] == 0x4F && data.matches(i, 'OggS') && data.u32le(i + 14) == serial) {
        final granule = data.u64le(i + 6);
        if (granule >= 0) return granule;
      }
    }
    if (start == 0) break;
    end = start;
  }
  return 0;
}

/// Ogg Vorbis and Opus.
AudioTags? readOgg(ByteSource source, {bool wantLyrics = true}) {
  final first = source.readExact(0, 4);
  if (first == null || !first.matches(0, 'OggS')) return null;
  final serialBytes = source.readExact(14, 4);
  if (serialBytes == null) return null;
  final serial = serialBytes.u32le(0);

  final packets = readOggPackets(source, 2);
  if (packets.isEmpty) return null;
  final id = packets[0];
  final tags = AudioTags();

  if (id.length >= 30 && id[0] == 1 && id.matches(1, 'vorbis')) {
    tags.channels = id[11];
    tags.sampleRate = id.u32le(12);
    final nominal = id.u32le(20);
    if (packets.length > 1 && packets[1].length > 7 && packets[1][0] == 3 && packets[1].matches(1, 'vorbis')) {
      readVorbisComment(packets[1], 7, tags, wantLyrics: wantLyrics);
    }
    final samples = lastOggGranule(source, serial);
    if (tags.sampleRate > 0 && samples > 0) {
      tags.duration = Duration(microseconds: samples * 1000000 ~/ tags.sampleRate);
    }
    if (nominal > 0 && nominal < 0x7FFFFFFF) {
      tags.bitrateKbps = (nominal / 1000).round();
    } else if (tags.duration > Duration.zero) {
      tags.bitrateKbps = (source.length * 8 / (tags.duration.inMicroseconds / 1e6) / 1000).round();
    }
    return tags;
  }

  if (id.length >= 19 && id.matches(0, 'OpusHead')) {
    tags.channels = id[9];
    final preSkip = id.u16le(10);
    final inputRate = id.u32le(12);
    tags.sampleRate = inputRate > 0 ? inputRate : 48000;
    if (packets.length > 1 && packets[1].length > 8 && packets[1].matches(0, 'OpusTags')) {
      readVorbisComment(packets[1], 8, tags, wantLyrics: wantLyrics);
    }
    final granule = lastOggGranule(source, serial);
    final samples = granule - preSkip;
    if (samples > 0) {
      tags.duration = Duration(microseconds: samples * 1000000 ~/ 48000);
      tags.bitrateKbps = (source.length * 8 / (samples / 48000) / 1000).round();
    }
    return tags;
  }

  if (id.length >= 13 && id[0] == 0x7F && id.matches(1, 'FLAC')) {
    // Ogg FLAC: STREAMINFO follows the 13-byte mapping header and the "fLaC" marker.
    if (id.length >= 13 + 4 + 4 + 18) _readStreamInfo(Uint8List.sublistView(id, 13 + 4 + 4), tags);
    if (packets.length > 1 && packets[1].length > 4) readVorbisComment(packets[1], 4, tags, wantLyrics: wantLyrics);
    final samples = lastOggGranule(source, serial);
    if (tags.sampleRate > 0 && samples > 0) {
      tags.duration = Duration(microseconds: samples * 1000000 ~/ tags.sampleRate);
    }
    return tags;
  }
  return null;
}
