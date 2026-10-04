import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ape_tag.dart';
import 'audio_tags.dart';
import 'byte_source.dart';
import 'id3.dart';

Duration _seconds(double seconds) => Duration(microseconds: (seconds * 1000000).round());

int _kbps(int bytes, Duration duration) =>
    duration.inMicroseconds <= 0 ? 0 : (bytes * 8 / (duration.inMicroseconds / 1e6) / 1000).round();

// ── MPEG audio (MP3) ────────────────────────────────────────────────────────────────────────────────

const List<List<int>> _mpeg1Bitrates = [
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // layer I
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // layer II
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // layer III
];
const List<List<int>> _mpeg2Bitrates = [
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // layer I
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // layer II
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // layer III
];

class _MpegFrame {
  _MpegFrame(this.version, this.layer, this.bitrate, this.sampleRate, this.channels, this.length, this.samples);

  /// 1 for MPEG-1, 2 for MPEG-2, 25 for MPEG-2.5.
  final int version;
  final int layer;
  final int bitrate;
  final int sampleRate;
  final int channels;
  final int length;
  final int samples;
}

_MpegFrame? _parseMpegHeader(Uint8List b, int o) {
  if (o + 4 > b.length || b[o] != 0xFF || (b[o + 1] & 0xE0) != 0xE0) return null;
  final versionBits = (b[o + 1] >> 3) & 3;
  final layerBits = (b[o + 1] >> 1) & 3;
  final bitrateIndex = b[o + 2] >> 4;
  final rateIndex = (b[o + 2] >> 2) & 3;
  if (versionBits == 1 || layerBits == 0 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;

  final version = versionBits == 3 ? 1 : (versionBits == 2 ? 2 : 25);
  final layer = 4 - layerBits;
  final bitrate = (version == 1 ? _mpeg1Bitrates : _mpeg2Bitrates)[layer - 1][bitrateIndex];
  const rates = {
    1: [44100, 48000, 32000],
    2: [22050, 24000, 16000],
    25: [11025, 12000, 8000],
  };
  final sampleRate = rates[version]![rateIndex];
  final padding = (b[o + 2] >> 1) & 1;
  final channels = (b[o + 3] >> 6) == 3 ? 1 : 2;
  final samples = layer == 1 ? 384 : (layer == 2 || version == 1 ? 1152 : 576);
  final length = layer == 1
      ? (12 * bitrate * 1000 ~/ sampleRate + padding) * 4
      : (samples ~/ 8) * bitrate * 1000 ~/ sampleRate + padding;
  if (length < 4) return null;
  return _MpegFrame(version, layer, bitrate, sampleRate, channels, length, samples);
}

/// MP3 (and MP2): the first frame and its Xing/Info or VBRI header for length and bitrate; ID3v2, APE and ID3v1 tags.
AudioTags? readMpeg(ByteSource source, {bool wantLyrics = true}) {
  final audioStart = skipLeadingId3v2(source);
  final tags = readId3v2(source, 0, wantLyrics: wantLyrics) ?? AudioTags();
  final ape = readApeTag(source, wantLyrics: wantLyrics);
  if (ape != null) tags.mergeFrom(ape);
  final v1 = readId3v1(source);
  if (v1 != null) tags.mergeFrom(v1);

  // Find the first frame whose successor is also a frame (a lone 0xFFE pattern in garbage is not enough).
  const window = 256 * 1024;
  final data = source.read(audioStart, window);
  _MpegFrame? frame;
  var frameOffset = -1;
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] != 0xFF) continue;
    final candidate = _parseMpegHeader(data, i);
    if (candidate == null) continue;
    final next = i + candidate.length;
    if (next + 4 <= data.length) {
      final following = _parseMpegHeader(data, next);
      if (following == null || following.sampleRate != candidate.sampleRate) continue;
    }
    frame = candidate;
    frameOffset = i;
    break;
  }
  if (frame == null) return tags;

  tags.sampleRate = frame.sampleRate;
  tags.channels = frame.channels;
  final audioBytes = source.length - audioStart - frameOffset - trailingTagBytes(source);

  // Xing / Info (VBR, or LAME's CBR marker) sits after the side information.
  final sideInfo = frame.version == 1 ? (frame.channels == 1 ? 17 : 32) : (frame.channels == 1 ? 9 : 17);
  final xing = frameOffset + 4 + sideInfo;
  int? frames;
  int? bytes;
  if (data.matches(xing, 'Xing') || data.matches(xing, 'Info')) {
    final flags = data.u32be(xing + 4);
    var p = xing + 8;
    if ((flags & 1) != 0) {
      frames = data.u32be(p);
      p += 4;
    }
    if ((flags & 2) != 0) bytes = data.u32be(p);
  } else if (data.matches(frameOffset + 36, 'VBRI')) {
    bytes = data.u32be(frameOffset + 36 + 10);
    frames = data.u32be(frameOffset + 36 + 14);
  }

  if (frames != null && frames > 0) {
    tags.duration = _seconds(frames * frame.samples / frame.sampleRate);
    tags.bitrateKbps = _kbps(bytes != null && bytes > 0 ? bytes : audioBytes, tags.duration);
  } else {
    tags.bitrateKbps = frame.bitrate;
    if (frame.bitrate > 0) tags.duration = _seconds(audioBytes * 8 / (frame.bitrate * 1000));
  }
  return tags;
}

// ── AAC in ADTS ─────────────────────────────────────────────────────────────────────────────────────

const List<int> _aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/// A raw AAC (ADTS) stream: the first frames give the format, their average size the bitrate and the length.
AudioTags? readAdts(ByteSource source, {bool wantLyrics = true}) {
  final start = skipLeadingId3v2(source);
  final tags = readId3v2(source, 0, wantLyrics: wantLyrics) ?? AudioTags();
  final ape = readApeTag(source, wantLyrics: wantLyrics);
  if (ape != null) tags.mergeFrom(ape);

  final data = source.read(start, 512 * 1024);
  var p = 0;
  while (p + 7 <= data.length && !(data[p] == 0xFF && (data[p + 1] & 0xF6) == 0xF0)) {
    p++;
  }
  if (p + 7 > data.length) return tags;
  final rateIndex = (data[p + 2] >> 2) & 0x0F;
  tags.sampleRate = rateIndex < _aacRates.length ? _aacRates[rateIndex] : 44100;
  final channelConfig = ((data[p + 2] & 1) << 2) | (data[p + 3] >> 6);
  tags.channels = channelConfig == 0 ? 2 : (channelConfig == 7 ? 8 : channelConfig);

  var frames = 0;
  var frameBytes = 0;
  while (p + 7 <= data.length && frames < 2000) {
    if (!(data[p] == 0xFF && (data[p + 1] & 0xF6) == 0xF0)) break;
    final length = ((data[p + 3] & 0x03) << 11) | (data[p + 4] << 3) | (data[p + 5] >> 5);
    if (length < 7) break;
    frames++;
    frameBytes += length;
    p += length;
  }
  if (frames == 0) return tags;
  final averageFrame = frameBytes / frames;
  final audioBytes = source.length - start - trailingTagBytes(source);
  final totalFrames = audioBytes / averageFrame;
  tags.duration = _seconds(totalFrames * 1024 / tags.sampleRate);
  tags.bitrateKbps = (averageFrame * 8 * tags.sampleRate / 1024 / 1000).round();
  return tags;
}

// ── MP4 / M4A ───────────────────────────────────────────────────────────────────────────────────────

class _Box {
  _Box(this.type, this.offset, this.headerSize, this.size);

  final String type;
  final int offset;
  final int headerSize;
  final int size;

  int get bodyOffset => offset + headerSize;
  int get bodySize => size - headerSize;
  int get end => offset + size;
}

List<_Box> _children(ByteSource source, int start, int end) {
  final boxes = <_Box>[];
  var position = start;
  while (position + 8 <= end) {
    final header = source.readExact(position, 16);
    final h = header ?? source.readExact(position, 8);
    if (h == null) break;
    var size = h.u32be(0);
    final type = latin1.decode(Uint8List.sublistView(h, 4, 8), allowInvalid: true);
    var headerSize = 8;
    if (size == 1 && header != null) {
      size = header.u64be(8);
      headerSize = 16;
    } else if (size == 0) {
      size = end - position;
    }
    if (size < headerSize || position + size > end) break;
    boxes.add(_Box(type, position, headerSize, size));
    position += size;
  }
  return boxes;
}

_Box? _child(ByteSource source, _Box parent, String type, {int skip = 0}) {
  for (final box in _children(source, parent.bodyOffset + skip, parent.end)) {
    if (box.type == type) return box;
  }
  return null;
}

const Map<String, TagField> _mp4Fields = {
  '©nam': TagField.title,
  '©ART': TagField.artist,
  'aART': TagField.albumArtist,
  '©alb': TagField.album,
  '©gen': TagField.genre,
  '©day': TagField.year,
  '©lyr': TagField.lyrics,
};

/// MP4 audio (`.m4a`): the audio track's sample entry (AAC or ALAC), its length, and the iTunes-style `ilst` tags.
AudioTags? readMp4(ByteSource source, {bool wantLyrics = true}) {
  final top = _children(source, 0, source.length);
  if (top.isEmpty || !top.any((b) => b.type == 'ftyp' || b.type == 'moov')) return null;
  final moov = top.where((b) => b.type == 'moov').firstOrNull;
  if (moov == null) return null;
  final mdatBytes = top.where((b) => b.type == 'mdat').fold<int>(0, (sum, b) => sum + b.bodySize);

  final tags = AudioTags();
  Duration? movieDuration;

  for (final box in _children(source, moov.bodyOffset, moov.end)) {
    if (box.type == 'mvhd') {
      final body = source.read(box.bodyOffset, 32);
      if (body.length >= 20) {
        final version = body[0];
        final timescale = version == 1 ? body.u32be(20) : body.u32be(12);
        final duration = version == 1 ? (body.length >= 32 ? body.u64be(24) : 0) : body.u32be(16);
        if (timescale > 0) movieDuration = _seconds(duration / timescale);
      }
    } else if (box.type == 'trak') {
      _readTrak(source, box, tags);
    } else if (box.type == 'udta') {
      final meta = _child(source, box, 'meta');
      if (meta == null) continue;
      // 'meta' is a full box (version and flags first) in ISO files, a plain box in some QuickTime files.
      final probe = source.read(meta.bodyOffset, 8);
      final skip = probe.length == 8 && probe.u32be(0) == 0 ? 4 : 0;
      final ilst = _child(source, meta, 'ilst', skip: skip);
      if (ilst != null) _readIlst(source, ilst, tags, wantLyrics);
    }
  }

  if (tags.duration == Duration.zero && movieDuration != null) tags.duration = movieDuration;
  if (tags.bitrateKbps == 0 && mdatBytes > 0) tags.bitrateKbps = _kbps(mdatBytes, tags.duration);
  return tags;
}

void _readTrak(ByteSource source, _Box trak, AudioTags tags) {
  final mdia = _child(source, trak, 'mdia');
  if (mdia == null) return;
  final hdlr = _child(source, mdia, 'hdlr');
  if (hdlr != null) {
    final body = source.read(hdlr.bodyOffset, 12);
    if (body.length >= 12 && !body.matches(8, 'soun')) return; // not the audio track
  }
  if (tags.codecDescription != null) return; // the first audio track wins

  final mdhd = _child(source, mdia, 'mdhd');
  if (mdhd != null) {
    final body = source.read(mdhd.bodyOffset, 32);
    if (body.length >= 20) {
      final version = body[0];
      final timescale = version == 1 ? body.u32be(20) : body.u32be(12);
      final duration = version == 1 ? (body.length >= 32 ? body.u64be(24) : 0) : body.u32be(16);
      if (timescale > 0) tags.duration = _seconds(duration / timescale);
    }
  }

  final minf = _child(source, mdia, 'minf');
  final stbl = minf == null ? null : _child(source, minf, 'stbl');
  final stsd = stbl == null ? null : _child(source, stbl, 'stsd');
  if (stsd == null) return;
  final entries = _children(source, stsd.bodyOffset + 8, stsd.end);
  if (entries.isEmpty) return;
  final entry = entries.first;
  tags.codecDescription = entry.type;

  final body = source.read(entry.bodyOffset, entry.bodySize < 4096 ? entry.bodySize : 4096);
  if (body.length < 28) return;
  final soundVersion = body.u16be(8);
  tags.channels = body.u16be(16);
  tags.bitsPerSample = body.u16be(18);
  tags.sampleRate = body.u32be(24) >> 16;
  final childStart = 28 + (soundVersion == 1 ? 16 : (soundVersion == 2 ? 36 : 0));
  if (soundVersion == 2 && body.length >= 48) {
    // Version 2 keeps the rate as a 64-bit float.
    final rate = ByteData.sublistView(body, 32, 40).getFloat64(0);
    if (rate > 0) tags.sampleRate = rate.round();
    tags.channels = body.u32be(40);
  }

  var p = childStart;
  while (p + 8 <= body.length) {
    final size = body.u32be(p);
    final type = body.ascii(p + 4, 4);
    if (size < 8 || p + size > body.length) break;
    if (type == 'alac' && size >= 36) {
      // ALACSpecificConfig after the full-box header.
      final c = p + 12;
      tags.bitsPerSample = body[c + 5];
      tags.channels = body[c + 9];
      final average = body.u32be(c + 16);
      final rate = body.u32be(c + 20);
      if (rate > 0) tags.sampleRate = rate;
      if (average > 0) tags.bitrateKbps = (average / 1000).round();
    } else if (type == 'esds') {
      final average = _esdsAverageBitrate(Uint8List.sublistView(body, p + 12, p + size));
      if (average > 0) tags.bitrateKbps = (average / 1000).round();
    }
    p += size;
  }
}

int _esdsAverageBitrate(Uint8List d) {
  var p = 0;
  int readLength() {
    var length = 0;
    for (var i = 0; i < 4 && p < d.length; i++) {
      final b = d[p++];
      length = (length << 7) | (b & 0x7F);
      if ((b & 0x80) == 0) break;
    }
    return length;
  }

  try {
    if (d[p++] != 0x03) return 0;
    readLength();
    p += 2; // ES_ID
    final flags = d[p++];
    if ((flags & 0x80) != 0) p += 2;
    if ((flags & 0x40) != 0) p += 1 + d[p];
    if ((flags & 0x20) != 0) p += 2;
    if (d[p++] != 0x04) return 0;
    readLength();
    p += 1 + 1 + 3 + 4; // object type, stream type, buffer size, max bitrate
    return d.u32be(p);
  } on RangeError {
    return 0;
  }
}

void _readIlst(ByteSource source, _Box ilst, AudioTags tags, bool wantLyrics) {
  for (final item in _children(source, ilst.bodyOffset, ilst.end)) {
    final data = _child(source, item, 'data');
    if (data == null || data.bodySize < 8) continue;
    final payloadOffset = data.bodyOffset + 8;
    final payloadLength = data.bodySize - 8;

    if (item.type == 'covr') {
      final head = source.read(data.bodyOffset, 4);
      final kind = head.length == 4 ? head.u32be(0) & 0xFFFFFF : 0;
      if (kind == 13 || kind == 14 || kind == 27 || kind == 0) {
        tags.offerPicture(location: PictureLocation(payloadOffset, payloadLength), type: 3);
      }
      continue;
    }
    if (item.type == 'trkn' || item.type == 'disk') {
      final payload = source.read(payloadOffset, 6);
      if (payload.length < 6) continue;
      final number = payload.u16be(2);
      final total = payload.u16be(4);
      if (item.type == 'trkn') {
        if (number > 0) tags.track ??= number;
        if (total > 0) tags.trackCount ??= total;
      } else if (number > 0) {
        tags.disc ??= number;
      }
      continue;
    }
    if (item.type == 'gnre') {
      final payload = source.read(payloadOffset, 2);
      if (payload.length == 2) tags.genre ??= genreByIndex(payload.u16be(0) - 1);
      continue;
    }

    final field = _mp4Fields[item.type];
    if (field == null || (field == TagField.lyrics && !wantLyrics) || payloadLength > 4 * 1024 * 1024) continue;
    tags.setText(field, decodeUtf8(source.read(payloadOffset, payloadLength)));
  }
}

// ── RIFF WAVE ───────────────────────────────────────────────────────────────────────────────────────

const Map<String, TagField> _infoFields = {
  'INAM': TagField.title,
  'IART': TagField.artist,
  'IPRD': TagField.album,
  'ICRD': TagField.year,
  'IGNR': TagField.genre,
  'ITRK': TagField.track,
  'IPRT': TagField.track,
};

AudioTags? readWav(ByteSource source, {bool wantLyrics = true}) {
  final header = source.readExact(0, 12);
  if (header == null || !(header.matches(0, 'RIFF') || header.matches(0, 'RF64')) || !header.matches(8, 'WAVE')) {
    return null;
  }

  final tags = AudioTags();
  AudioTags? info;
  AudioTags? id3;
  var byteRate = 0;
  var dataSize = 0;
  var position = 12;
  while (position + 8 <= source.length) {
    final chunk = source.readExact(position, 8);
    if (chunk == null) break;
    final id = chunk.ascii(0, 4);
    var size = chunk.u32le(4);
    final body = position + 8;
    if (id == 'data' && (size == 0xFFFFFFFF || body + size > source.length)) size = source.length - body;

    switch (id) {
      case 'fmt ':
        final fmt = source.read(body, size < 40 ? size : 40);
        if (fmt.length >= 16) {
          tags.channels = fmt.u16le(2);
          tags.sampleRate = fmt.u32le(4);
          byteRate = fmt.u32le(8);
          tags.bitsPerSample = fmt.u16le(14);
          if (fmt.u16le(0) == 0xFFFE && fmt.length >= 20) {
            final valid = fmt.u16le(18);
            if (valid > 0) tags.bitsPerSample = valid;
          }
        }
      case 'data':
        dataSize = size;
      case 'LIST':
        final list = source.read(body, size < 1024 * 1024 ? size : 1024 * 1024);
        if (list.length >= 4 && list.matches(0, 'INFO')) {
          info = AudioTags();
          var p = 4;
          while (p + 8 <= list.length) {
            final subId = list.ascii(p, 4);
            final subSize = list.u32le(p + 4);
            if (p + 8 + subSize > list.length) break;
            final field = _infoFields[subId];
            if (field != null) info.setText(field, decodeUtf8(Uint8List.sublistView(list, p + 8, p + 8 + subSize)));
            p += 8 + subSize + (subSize & 1);
          }
        }
      case 'id3 ' || 'ID3 ':
        id3 = readId3v2(source, body, wantLyrics: wantLyrics);
    }
    position = body + size + (size & 1);
  }

  // TagLib's order: the ID3v2 chunk first, then the INFO list.
  if (id3 != null) tags.mergeFrom(id3);
  if (info != null) tags.mergeFrom(info);

  if (byteRate > 0) {
    tags.duration = _seconds(dataSize / byteRate);
    tags.bitrateKbps = (byteRate * 8 / 1000).round();
  }
  return tags;
}

// ── AIFF ────────────────────────────────────────────────────────────────────────────────────────────

/// The 80-bit IEEE extended float AIFF stores its sample rate in.
double _extended80(Uint8List b, int o) {
  final exponent = ((b[o] & 0x7F) << 8) | b[o + 1];
  // The 64-bit mantissa is read as two halves: as one Dart int its top bit would make it negative.
  final mantissa = b.u32be(o + 2) * 4294967296.0 + b.u32be(o + 6);
  if (exponent == 0 && mantissa == 0) return 0;
  final value = mantissa * math.pow(2, exponent - 16383 - 63);
  return (b[o] & 0x80) != 0 ? -value : value;
}

AudioTags? readAiff(ByteSource source, {bool wantLyrics = true}) {
  final header = source.readExact(0, 12);
  if (header == null || !header.matches(0, 'FORM') || !(header.matches(8, 'AIFF') || header.matches(8, 'AIFC'))) {
    return null;
  }

  final tags = AudioTags();
  var frames = 0;
  var position = 12;
  while (position + 8 <= source.length) {
    final chunk = source.readExact(position, 8);
    if (chunk == null) break;
    final id = chunk.ascii(0, 4);
    final size = chunk.u32be(4);
    final body = position + 8;
    if (id == 'COMM') {
      final comm = source.read(body, 18);
      if (comm.length >= 18) {
        tags.channels = comm.u16be(0);
        frames = comm.u32be(2);
        tags.bitsPerSample = comm.u16be(6);
        tags.sampleRate = _extended80(comm, 8).round();
      }
    } else if (id == 'ID3 ' || id == 'id3 ') {
      final id3 = readId3v2(source, body, wantLyrics: wantLyrics);
      if (id3 != null) tags.mergeFrom(id3);
    }
    position = body + size + (size & 1);
  }

  if (tags.sampleRate > 0) {
    tags.duration = _seconds(frames / tags.sampleRate);
    tags.bitrateKbps = (tags.sampleRate * tags.channels * tags.bitsPerSample / 1000).round();
  }
  return tags;
}

// ── DSF (DSD stream file) ───────────────────────────────────────────────────────────────────────────

AudioTags? readDsf(ByteSource source, {bool wantLyrics = true}) {
  final header = source.readExact(0, 28 + 52);
  if (header == null || !header.matches(0, 'DSD ') || !header.matches(28, 'fmt ')) return null;
  final metadataOffset = header.u64le(20);
  final fmt = 28 + 12;
  final channels = header.u32le(fmt + 12);
  final rate = header.u32le(fmt + 16);
  final bits = header.u32le(fmt + 20);
  final samples = header.u64le(fmt + 24);

  final tags = metadataOffset > 0
      ? (readId3v2(source, metadataOffset, wantLyrics: wantLyrics) ?? AudioTags())
      : AudioTags();
  tags.channels = channels;
  tags.sampleRate = rate;
  tags.bitsPerSample = bits;
  if (rate > 0) {
    tags.duration = _seconds(samples / rate);
    tags.bitrateKbps = (rate * channels / 1000).round();
  }
  return tags;
}

// ── WavPack ─────────────────────────────────────────────────────────────────────────────────────────

const List<int> _wavPackRates = [
  6000,
  8000,
  9600,
  11025,
  12000,
  16000,
  22050,
  24000,
  32000,
  44100,
  48000,
  64000,
  88200,
  96000,
  192000,
  0,
];

AudioTags? readWavPack(ByteSource source, {bool wantLyrics = true}) {
  final start = skipLeadingId3v2(source);
  final tags = readApeTag(source, wantLyrics: wantLyrics) ?? AudioTags();
  final v1 = readId3v1(source);
  if (v1 != null) tags.mergeFrom(v1);

  var position = start;
  for (var blocks = 0; blocks < 64 && position + 32 <= source.length; blocks++) {
    final h = source.readExact(position, 32);
    if (h == null || !h.matches(0, 'wvpk')) return blocks == 0 ? null : tags;
    final blockSize = h.u32le(4) + 8;
    final totalLow = h.u32le(12);
    final totalHigh = h[11];
    final blockSamples = h.u32le(20);
    final flags = h.u32le(24);
    if (blockSamples == 0) {
      position += blockSize;
      continue;
    }

    final bytesStored = (flags & 3) + 1;
    final shift = (flags >> 13) & 0x1F;
    final isDsd = (flags & 0x80000000) != 0;
    tags.bitsPerSample = isDsd ? 1 : bytesStored * 8 - shift;
    tags.channels = (flags & 4) != 0 ? 1 : 2;
    var rate = _wavPackRates[(flags >> 23) & 0x0F];

    // Metadata sub-blocks carry what the flags cannot: a non-standard rate, more than two channels.
    final body = source.read(position + 32, blockSize - 32 < 4096 ? blockSize - 32 : 4096);
    var p = 0;
    while (p + 2 <= body.length) {
      final id = body[p];
      final large = (id & 0x80) != 0;
      var size = large
          ? (p + 4 <= body.length ? body[p + 1] | (body[p + 2] << 8) | (body[p + 3] << 16) : 0)
          : body[p + 1];
      size *= 2;
      final data = p + (large ? 4 : 2);
      final actual = (id & 0x40) != 0 ? size - 1 : size;
      final function = id & 0x3F;
      if (data + actual > body.length) break;
      if (function == 0x0D && actual >= 1) tags.channels = body[data];
      if (function == 0x27 && actual >= 3) rate = body[data] | (body[data + 1] << 8) | (body[data + 2] << 16);
      p = data + size;
    }
    final total = totalLow == 0xFFFFFFFF ? -1 : totalLow + (totalHigh << 32);
    if (rate > 0 && total > 0) tags.duration = _seconds(total / rate);
    // A DSD block counts bytes (eight 1-bit samples each) where PCM counts samples.
    tags.sampleRate = isDsd ? rate * 8 : rate;
    break;
  }

  if (tags.duration > Duration.zero) {
    tags.bitrateKbps = _kbps(source.length - start - trailingTagBytes(source), tags.duration);
  }
  return tags;
}

// ── Monkey's Audio (APE) ────────────────────────────────────────────────────────────────────────────

AudioTags? readMonkeysAudio(ByteSource source, {bool wantLyrics = true}) {
  final start = skipLeadingId3v2(source);
  final h = source.readExact(start, 76);
  if (h == null || !h.matches(0, 'MAC ')) return null;
  final tags = readApeTag(source, wantLyrics: wantLyrics) ?? AudioTags();
  final v1 = readId3v1(source);
  if (v1 != null) tags.mergeFrom(v1);

  final version = h.u16le(4);
  int blocksPerFrame, finalFrameBlocks, totalFrames, bits, channels, rate;
  if (version >= 3980) {
    final descriptorBytes = h.u32le(8);
    final header = source.readExact(start + descriptorBytes, 24);
    if (header == null) return tags;
    blocksPerFrame = header.u32le(4);
    finalFrameBlocks = header.u32le(8);
    totalFrames = header.u32le(12);
    bits = header.u16le(16);
    channels = header.u16le(18);
    rate = header.u32le(20);
  } else {
    final compression = h.u16le(6);
    final formatFlags = h.u16le(8);
    channels = h.u16le(10);
    rate = h.u32le(12);
    totalFrames = h.u32le(24);
    finalFrameBlocks = h.u32le(28);
    bits = (formatFlags & 1) != 0 ? 8 : ((formatFlags & 8) != 0 ? 24 : 16);
    blocksPerFrame = version >= 3950
        ? 73728 * 4
        : (version >= 3900 || (version >= 3800 && compression == 4000) ? 73728 : 9216);
  }

  tags.bitsPerSample = bits;
  tags.channels = channels;
  tags.sampleRate = rate;
  if (rate > 0 && totalFrames > 0) {
    final samples = (totalFrames - 1) * blocksPerFrame + finalFrameBlocks;
    tags.duration = _seconds(samples / rate);
    tags.bitrateKbps = _kbps(source.length - start - trailingTagBytes(source), tags.duration);
  }
  return tags;
}
