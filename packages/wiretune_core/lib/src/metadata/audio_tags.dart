import 'dart:typed_data';

import 'byte_source.dart';

/// Where an embedded picture lies in its file, so that it can be read only when it is needed.
class PictureLocation {
  const PictureLocation(this.offset, this.length, {this.type = 3});

  final int offset;
  final int length;

  /// The ID3/FLAC picture type; 3 is the front cover.
  final int type;
}

/// What the tag reader found in one file: the tags, the stream properties and the first embedded picture.
class AudioTags {
  String? title;
  String? artist;
  String? albumArtist;
  String? album;
  String? genre;
  String? lyrics;
  int? track;
  int? trackCount;
  int? disc;
  int? year;

  Duration duration = Duration.zero;
  int sampleRate = 0;
  int bitsPerSample = 0;
  int channels = 0;
  int bitrateKbps = 0;

  /// For MP4 files, the sample entry of the audio track (`alac` or `mp4a`).
  String? codecDescription;

  /// The picture's bytes when they were read along with the tag (pictures in Ogg comments, unsynchronised ID3 tags).
  Uint8List? pictureData;

  /// Where the picture is, when it was only located.
  PictureLocation? pictureLocation;

  bool get hasPicture => pictureData != null || pictureLocation != null;

  /// Records a picture found in a tag. A front cover replaces a picture of another type found before it; otherwise the
  /// first picture wins.
  void offerPicture({Uint8List? data, PictureLocation? location, int type = 3}) {
    if (data == null && location == null) return;
    if (hasPicture && !(type == 3 && _pictureType != 3)) return;
    pictureData = data;
    pictureLocation = data == null ? location : null;
    _pictureType = type;
  }

  int? _pictureType;

  /// The picture's bytes, read from [source] if they were only located.
  Uint8List? readPicture(ByteSource source) {
    if (pictureData != null) return pictureData;
    final location = pictureLocation;
    if (location == null || location.length <= 0) return null;
    return source.readExact(location.offset, location.length);
  }

  /// Fills every field that is still empty from [other] (a tag of lower priority in the same file).
  void mergeFrom(AudioTags other) {
    title ??= other.title;
    artist ??= other.artist;
    albumArtist ??= other.albumArtist;
    album ??= other.album;
    genre ??= other.genre;
    lyrics ??= other.lyrics;
    track ??= other.track;
    trackCount ??= other.trackCount;
    disc ??= other.disc;
    year ??= other.year;
    if (!hasPicture && other.hasPicture) {
      pictureData = other.pictureData;
      pictureLocation = other.pictureLocation;
      _pictureType = other._pictureType;
    }
  }

  /// Sets a text field by its common name, keeping the first non-empty value.
  void setText(TagField field, String? value) {
    final text = value == null ? null : trimNul(value);
    if (text == null || text.isEmpty) return;
    switch (field) {
      case TagField.title:
        title ??= text;
      case TagField.artist:
        artist ??= text;
      case TagField.albumArtist:
        albumArtist ??= text;
      case TagField.album:
        album ??= text;
      case TagField.genre:
        genre ??= text;
      case TagField.lyrics:
        lyrics ??= text;
      case TagField.track:
        final (n, total) = parseNumberPair(text);
        track ??= n;
        trackCount ??= total;
      case TagField.trackCount:
        trackCount ??= parseLeadingInt(text);
      case TagField.disc:
        disc ??= parseNumberPair(text).$1;
      case TagField.year:
        year ??= parseYear(text);
    }
  }
}

enum TagField { title, artist, albumArtist, album, genre, lyrics, track, trackCount, disc, year }

/// "3/12" -> (3, 12), "3" -> (3, null); zero or garbage -> null.
(int?, int?) parseNumberPair(String text) {
  final parts = text.split('/');
  final first = parseLeadingInt(parts[0]);
  final second = parts.length > 1 ? parseLeadingInt(parts[1]) : null;
  return (first == null || first <= 0 ? null : first, second == null || second <= 0 ? null : second);
}

int? parseLeadingInt(String text) {
  final match = RegExp(r'^\s*(\d+)').firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The year of a date such as "2001", "2001-05-02" or "2001-05-02T10:00:00Z"; null for zero or garbage.
int? parseYear(String text) {
  final match = RegExp(r'(\d{4})').firstMatch(text);
  final year = match == null ? null : int.tryParse(match.group(1)!);
  return year == null || year <= 0 ? null : year;
}
