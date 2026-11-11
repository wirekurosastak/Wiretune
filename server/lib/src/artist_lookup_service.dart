// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:wiretune_core/wiretune_core.dart';

import 'online.dart';

/// Looks each artist of the library up on Deezer once, for the artists Deezer's listeners also play: twenty of them,
/// the closest first, made from what millions of people listen to. They tell which artists of the library are alike
/// ([RelatedMusicService]) better than any tag can.
///
/// The artist is found through a release of theirs: an album's barcode or a track's ISRC names a release on Deezer,
/// whose artists include them. Only an artist none of whose files carry a code is found by the name, and then only
/// when Deezer has one artist of exactly that name or one far better known than the others (five times the
/// listeners) (Deezer merges some
/// namesakes). An artist not found is asked again after [retryAfter], one found after [refreshAfter] (the lists
/// change as people's listening does). Only the codes and the names go out. [enabled] is the administrator's switch.
class ArtistLookupService {
  ArtistLookupService(this._db, this._deezer, {required this.enabled}) {
    for (final row in _db.connection.select('SELECT artist_key, related FROM artist_lookups WHERE found = 1')) {
      _related[row['artist_key'] as String] = [for (final name in jsonDecode(row['related'] as String)) '$name'];
    }
  }

  final DatabaseManager _db;
  final Deezer _deezer;
  final bool Function() enabled;

  static const Duration retryAfter = Duration(days: 30);
  static const Duration refreshAfter = Duration(days: 120);

  final Map<String, List<String>> _related = {};
  bool _running = false;
  bool _stop = false;

  /// The artists Deezer relates to the artist named [name] (any case), the closest first; null when not known.
  List<String>? relatedOf(String name) => _related[artistKey(name)];

  /// The key an artist is known by here: the name in lower case.
  static String artistKey(String name) => name.trim().toLowerCase();

  /// Looks up the [artists] not asked about yet (or not found [retryAfter] ago, or found [refreshAfter] ago), one after
  /// another, while [enabled]; [onLearned] hears of what was found, every few artists and at the end. A run already
  /// going on goes on instead; a network failure ends the run (the next scan starts another).
  Future<void> run(List<Artist> artists, {required void Function() onLearned}) async {
    if (_running || !enabled()) return;
    _running = true;
    _stop = false;
    var learned = 0;
    try {
      final asked = {
        for (final row in _db.connection.select('SELECT artist_key, found, looked_up_at FROM artist_lookups'))
          row['artist_key'] as String: (found: row['found'] == 1, at: fromDbTime(row['looked_up_at'])),
      };
      final now = DateTime.now().toUtc();
      for (final artist in artists) {
        if (_stop || !enabled()) break;
        if (Track.isUnknownArtist(artist.name)) continue;
        final key = artistKey(artist.name);
        final before = asked[key];
        if (before != null && now.difference(before.at ?? now) < (before.found ? refreshAfter : retryAfter)) continue;
        final related = await _lookUp(artist);
        _remember(key, related);
        if (related != null && ++learned % 20 == 0) onLearned();
      }
    } on Exception catch (e) {
      WiretuneLog.info('ArtistLookup', 'Stopped looking artists up for now: $e');
    } finally {
      _running = false;
      if (learned % 20 != 0) onLearned();
    }
  }

  void _remember(String key, List<String>? related) {
    _db.connection.execute(
      'INSERT INTO artist_lookups (artist_key, looked_up_at, found, related) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(artist_key) DO UPDATE SET looked_up_at = excluded.looked_up_at, found = excluded.found, '
      'related = excluded.related',
      [key, toDbTime(DateTime.now().toUtc()), related == null ? 0 : 1, related == null ? null : jsonEncode(related)],
    );
    if (related != null) {
      _related[key] = related;
    } else {
      _related.remove(key);
    }
  }

  /// The artists Deezer relates to [artist]; null when Deezer doesn't know the artist. Throws when it can't be reached.
  Future<List<String>?> _lookUp(Artist artist) async {
    final id = await _idOf(artist);
    if (id == null) return null;
    final answer = await _deezer.get('/artist/$id/related');
    final related = [
      for (final other in (answer?['data'] as List?) ?? const [])
        if (other case {'name': final String name} when name.trim().isNotEmpty) name.trim(),
    ];
    return related.isEmpty ? null : related;
  }

  /// [artist]'s ID on Deezer: through the barcode of one of their albums, the ISRC of one of their tracks, or else the
  /// name.
  Future<int?> _idOf(Artist artist) async {
    int? named(Object? people) {
      for (final person in people is List ? people : [people]) {
        if (person case {'id': final int id, 'name': final String name} when sameName(name, artist.name)) return id;
      }
      return null;
    }

    // Two releases at most: the artist may be a guest on another's album, which then names them only on its tracks.
    var tried = 0;
    for (final album in artist.albums) {
      final barcode = album.tracks.map((t) => t.details.barcode).nonNulls.firstOrNull;
      if (barcode == null) continue;
      if (++tried > 2) break;
      for (final code in Deezer.barcodeForms(barcode)) {
        final found = await _deezer.get('/album/upc:$code');
        if (found == null) continue;
        if (named(found['contributors']) ?? named(found['artist']) case final id?) return id;
        break;
      }
    }
    final isrcs = [
      for (final track in artist.tracks)
        if (track.details.isrc case final isrc? when track.artistNames.any((n) => sameName(n, artist.name))) isrc,
    ];
    for (final isrc in isrcs.take(2)) {
      final track = await _deezer.get('/track/isrc:${Uri.encodeComponent(isrc)}');
      if (named(track?['contributors']) ?? named(track?['artist']) case final id?) return id;
    }
    // By the name: the one artist of that name, or one with five times the listeners of the next. A plain search: the
    // `artist:"…"` form misses some well-known artists.
    final results = await _deezer.get('/search/artist?q=${Uri.encodeQueryComponent(artist.name)}&limit=25');
    final namesakes = [
      for (final hit in (results?['data'] as List?) ?? const [])
        if (hit case {'id': final int id, 'name': final String name} when sameName(name, artist.name))
          (id: id, fans: (hit['nb_fan'] as num?)?.toInt() ?? 0),
    ]..sort((a, b) => b.fans.compareTo(a.fans));
    if (namesakes.isEmpty) return null;
    if (namesakes.length == 1 || namesakes.first.fans >= 5 * namesakes[1].fans) return namesakes.first.id;
    return null;
  }

  void close() => _stop = true;
}
