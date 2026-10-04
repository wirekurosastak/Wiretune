import 'audio_tags.dart';
import 'byte_source.dart';
import 'id3.dart';

const Map<String, TagField> _apeFields = {
  'title': TagField.title,
  'artist': TagField.artist,
  'album artist': TagField.albumArtist,
  'albumartist': TagField.albumArtist,
  'album_artist': TagField.albumArtist,
  'album': TagField.album,
  'genre': TagField.genre,
  'track': TagField.track,
  'disc': TagField.disc,
  'discnumber': TagField.disc,
  'year': TagField.year,
  'date': TagField.year,
  'lyrics': TagField.lyrics,
  'unsyncedlyrics': TagField.lyrics,
};

/// The byte range an APEv2 tag occupies at the end of the file (header included), or null when there is none.
(int start, int end)? apeTagRange(ByteSource source) {
  for (final footerEnd in [source.length, if (hasId3v1(source)) source.length - 128]) {
    final footer = source.readExact(footerEnd - 32, 32);
    if (footer == null || !footer.matches(0, 'APETAGEX')) continue;
    final size = footer.u32le(12); // items and footer, without the header
    final flags = footer.u32le(20);
    final hasHeader = (flags & 0x80000000) != 0;
    final start = footerEnd - size - (hasHeader ? 32 : 0);
    if (start < 0) return null;
    return (start, footerEnd);
  }
  return null;
}

/// Reads the APEv2 tag at the end of the file (before an ID3v1 tag, if there is one); null when there is none.
AudioTags? readApeTag(ByteSource source, {bool wantLyrics = true}) {
  for (final footerEnd in [source.length, if (hasId3v1(source)) source.length - 128]) {
    final footer = source.readExact(footerEnd - 32, 32);
    if (footer == null || !footer.matches(0, 'APETAGEX')) continue;
    final size = footer.u32le(12);
    final count = footer.u32le(16);
    final itemsStart = footerEnd - size;
    final itemsEnd = footerEnd - 32;
    if (itemsStart < 0 || size < 32) return null;

    final tags = AudioTags();
    var position = itemsStart;
    for (var i = 0; i < count && position + 8 < itemsEnd; i++) {
      final head = source.readExact(position, 8);
      if (head == null) break;
      final valueLength = head.u32le(0);
      final itemFlags = head.u32le(4);
      final keyBytes = source.read(position + 8, 256 < itemsEnd - position - 8 ? 256 : itemsEnd - position - 8);
      final nul = keyBytes.indexOf(0);
      if (nul <= 0) break;
      final key = keyBytes.ascii(0, nul);
      final valueOffset = position + 8 + nul + 1;
      position = valueOffset + valueLength;
      if (position > itemsEnd) break;

      final lowerKey = key.toLowerCase();
      final isBinary = ((itemFlags >> 1) & 0x03) == 1;
      if (lowerKey.startsWith('cover art')) {
        if (!isBinary) continue;
        // The value is a file name, NUL, then the picture.
        final nameBytes = source.read(valueOffset, valueLength < 512 ? valueLength : 512);
        final nameEnd = nameBytes.indexOf(0);
        if (nameEnd < 0) continue;
        final type = lowerKey == 'cover art (front)' ? 3 : 0;
        tags.offerPicture(
          location: PictureLocation(valueOffset + nameEnd + 1, valueLength - nameEnd - 1, type: type),
          type: type,
        );
        continue;
      }

      final field = _apeFields[lowerKey];
      if (field == null || isBinary || (field == TagField.lyrics && !wantLyrics)) continue;
      if (valueLength > 4 * 1024 * 1024) continue;
      final value = decodeUtf8(source.read(valueOffset, valueLength));
      final first = value.split('\u0000').firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
      tags.setText(field, field == TagField.genre ? resolveId3Genre(first) : first);
    }
    return tags;
  }
  return null;
}

/// The size of the tags at the end of a file (APEv2 and ID3v1), which is not audio.
int trailingTagBytes(ByteSource source) {
  final range = apeTagRange(source);
  if (range != null) return source.length - range.$1;
  return hasId3v1(source) ? 128 : 0;
}
