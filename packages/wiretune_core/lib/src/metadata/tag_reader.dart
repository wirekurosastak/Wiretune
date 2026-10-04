import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio_tags.dart';
import 'byte_source.dart';
import 'containers.dart';
import 'id3.dart';
import 'xiph.dart';

export 'audio_tags.dart' show AudioTags, PictureLocation;

/// Reads the tags and stream properties of the audio files Wiretune indexes, in pure Dart (so the server and every
/// player read files the same way). It reads by random access: headers and text fields, never the audio, and an
/// embedded picture is only located until [readPicture] asks for it.
abstract final class TagReader {
  /// Reads [path]; null when the file is not a readable audio file of a supported type. Throws on I/O errors.
  static AudioTags? read(String path, {bool wantLyrics = false}) {
    final source = ByteSource.open(path);
    try {
      return readFrom(source, path, wantLyrics: wantLyrics);
    } finally {
      source.close();
    }
  }

  /// Reads the file behind [source]; [path] decides the format by its extension, the content confirms it.
  static AudioTags? readFrom(ByteSource source, String path, {bool wantLyrics = false}) {
    final AudioTags? tags = switch (p.extension(path).toLowerCase()) {
      '.flac' => readFlac(source, wantLyrics: wantLyrics),
      '.ogg' || '.opus' || '.oga' => readOgg(source, wantLyrics: wantLyrics),
      '.mp3' || '.mp2' => readMpeg(source, wantLyrics: wantLyrics),
      '.m4a' || '.mp4' || '.m4b' || '.alac' => readMp4(source, wantLyrics: wantLyrics),
      '.aac' => readAdts(source, wantLyrics: wantLyrics),
      '.wav' => readWav(source, wantLyrics: wantLyrics),
      '.aiff' || '.aif' || '.aifc' => readAiff(source, wantLyrics: wantLyrics),
      '.dsf' => readDsf(source, wantLyrics: wantLyrics),
      '.wv' => readWavPack(source, wantLyrics: wantLyrics),
      '.ape' => readMonkeysAudio(source, wantLyrics: wantLyrics),
      _ => null,
    };
    if (tags != null && (tags.sampleRate > 0 || tags.duration > Duration.zero)) return tags;
    // Nothing (or no audio stream) where the extension said: the content may be another format.
    final sniffed = _sniff(source, wantLyrics);
    return sniffed != null && (sniffed.sampleRate > 0 || tags == null) ? sniffed : tags;
  }

  /// A file whose content does not match its extension: try the formats by their magic bytes.
  static AudioTags? _sniff(ByteSource source, bool wantLyrics) {
    final head = source.read(0, 12);
    if (head.length < 4) return null;
    if (head.matches(0, 'fLaC')) return readFlac(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'OggS')) return readOgg(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'RIFF')) return readWav(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'FORM')) return readAiff(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'DSD ')) return readDsf(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'wvpk')) return readWavPack(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'MAC ')) return readMonkeysAudio(source, wantLyrics: wantLyrics);
    if (head.length >= 8 && head.matches(4, 'ftyp')) return readMp4(source, wantLyrics: wantLyrics);
    if (head.matches(0, 'ID3')) {
      final start = skipLeadingId3v2(source);
      final after = source.read(start, 4);
      if (after.length == 4 && after.matches(0, 'fLaC')) return readFlac(source, wantLyrics: wantLyrics);
      return readMpeg(source, wantLyrics: wantLyrics);
    }
    if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return readMpeg(source, wantLyrics: wantLyrics);
    return null;
  }

  /// The first embedded picture of [path] (a front cover when there is one), or null.
  static Uint8List? readPicture(String path) {
    final source = ByteSource.open(path);
    try {
      return readFrom(source, path)?.readPicture(source);
    } finally {
      source.close();
    }
  }

  /// The lyrics stored in the file's tag, or null.
  static String? readLyrics(String path) => read(path, wantLyrics: true)?.lyrics;
}
