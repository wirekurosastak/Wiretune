// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import '../models/library_models.dart';
import '../util/text.dart';

/// Handles track deduplication and merging between local files and remote server tracks. When the same song exists in
/// both libraries, the local track is preferred, so it plays without the network.
abstract final class TrackDeduplication {
  /// Merges [localTracks] and [serverTracks] into one list. A server track that duplicates a local one is dropped, and
  /// its cover goes to the local track when the file has none. [aliasedTrackIds] receives server track ID -> the local
  /// track ID it was folded into (the library moves its favourite and play statistics along).
  static List<Track> mergeTracks(
    Iterable<Track> localTracks,
    Iterable<Track> serverTracks,
    Map<String, String> aliasedTrackIds,
  ) {
    aliasedTrackIds.clear();
    final locals = localTracks.toList();
    final servers = serverTracks.toList();
    if (locals.isEmpty) return servers;
    if (servers.isEmpty) return locals;

    final result = List<Track>.of(locals);

    // Local tracks grouped by normalised title and main artist for a fast candidate lookup (a player or server that
    // predates featured artists knows only the first).
    final localByTitleArtist = <String, List<Track>>{};
    for (final t in locals) {
      localByTitleArtist.putIfAbsent('${cleanTitle(t.title)}|${cleanArtist(t.primaryArtist)}', () => []).add(t);
    }

    for (final serverTrack in servers) {
      final candidates =
          localByTitleArtist['${cleanTitle(serverTrack.title)}|${cleanArtist(serverTrack.primaryArtist)}'];
      final duplicateLocal = candidates?.where((l) => isDuplicate(l, serverTrack)).firstOrNull;
      if (duplicateLocal != null) {
        if (!duplicateLocal.hasCoverArt && serverTrack.hasCoverArt && !isBlank(serverTrack.coverArtPath)) {
          duplicateLocal
            ..hasCoverArt = true
            ..coverArtPath = serverTrack.coverArtPath;
        }
        aliasedTrackIds[serverTrack.id] = duplicateLocal.id;
      } else {
        result.add(serverTrack);
      }
    }
    return result;
  }

  /// Whether a local track and a server track are the same song.
  static bool isDuplicate(Track? local, Track? server) {
    if (local == null || server == null) return false;

    final localTitle = cleanTitle(local.title);
    final serverTitle = cleanTitle(server.title);
    if (localTitle.isEmpty || serverTitle.isEmpty || localTitle != serverTitle) return false;

    final localArtist = cleanArtist(local.primaryArtist);
    final serverArtist = cleanArtist(server.primaryArtist);
    if (localArtist.isEmpty || serverArtist.isEmpty || localArtist != serverArtist) return false;

    final hasLocalDuration = local.duration > Duration.zero;
    final hasServerDuration = server.duration > Duration.zero;
    if (hasLocalDuration && hasServerDuration) {
      final diff = (local.duration - server.duration).inMicroseconds.abs() / 1e6;
      // Same album: up to 5 seconds apart. Different albums (a compilation and the studio album): 3.5 seconds.
      return albumsMatch(local.album, server.album) ? diff <= 5.0 : diff <= 3.5;
    }

    // A length is missing: rely on the album.
    return albumsMatch(local.album, server.album);
  }

  static bool albumsMatch(String? a, String? b) {
    if (isBlank(a) || isBlank(b)) return true;
    final cleanA = cleanAlbum(a);
    final cleanB = cleanAlbum(b);
    if (cleanA.isEmpty || cleanB.isEmpty) return true;
    if (cleanA == 'unknownalbum' || cleanB == 'unknownalbum') return true;
    if (cleanA == cleanB) return true;

    // "Discovery" vs "Discovery Live 2001" is close enough, but a one- or two-letter album name inside a long one is not.
    final (shorter, longer) = cleanA.length <= cleanB.length ? (cleanA, cleanB) : (cleanB, cleanA);
    return shorter.length >= 4 && longer.contains(shorter);
  }

  // Trailing "(2011 Remaster)" style notes that do not make a different recording. "Live", "Acoustic", "Demo",
  // "Instrumental" ... are deliberately not listed: those are different recordings of the same song.
  static final RegExp _titleNote = RegExp(
    r'\b(remaster(ed)?|bonus|deluxe|anniversary|stereo|mono|(single|album|radio)\s+(version|edit))\b',
    caseSensitive: false,
  );

  static final RegExp _albumNote = RegExp(
    r'\b(remaster(ed)?|bonus|deluxe|edition|anniversary)\b',
    caseSensitive: false,
  );

  static String cleanTitle(String? title) => _normalize(_stripTrailingNotes(title, _titleNote));

  static String cleanArtist(String? artist) => _normalize(artist);

  static String cleanAlbum(String? album) => _normalize(_stripTrailingNotes(album, _albumNote));

  /// Removes trailing "(...)" or "[...]" groups whose text matches [note], repeatedly.
  static String _stripTrailingNotes(String? text, RegExp note) {
    if (isBlank(text)) return '';
    var s = text!.trim();
    while (s.length > 2 && (s.endsWith(')') || s.endsWith(']'))) {
      final open = s.lastIndexOf(s.endsWith(')') ? '(' : '[');
      if (open <= 0 || !note.hasMatch(s.substring(open + 1, s.length - 1))) break;
      s = s.substring(0, open).trimRight();
    }
    return s;
  }

  static String _normalize(String? s) => isBlank(s) ? '' : lettersAndDigits(s!.trim()).toLowerCase();
}
