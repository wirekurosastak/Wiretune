// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:wiretune_core/wiretune_core.dart';

import 'credit_lookup_service.dart' show CreditLookupService;
import 'online.dart';

/// What the server learned online about an album: its genre and its label, either of them null when not known.
typedef AlbumFacts = ({String? genre, String? label});

/// Looks each album of the library up on Deezer once, for its genre and its label, which the track list then gives the
/// tracks whose files don't name them. By the release's barcode when a track has one, else by a track's ISRC, else by
/// the album's title and artist. What it learned is kept in the database; an album it didn't find is asked again after
/// [retryAfter]. Only the codes and the names go out, never anything about the accounts. An administrator can turn it
/// off ([enabled]); what was learned before stays.
class AlbumLookupService {
  AlbumLookupService(this._db, this._deezer) {
    for (final row in _db.connection.select('SELECT album_id, genre, label FROM album_lookups WHERE found = 1')) {
      _known[row['album_id'] as String] = (genre: row['genre'] as String?, label: row['label'] as String?);
    }
  }

  final DatabaseManager _db;
  final Deezer _deezer;

  /// An album that wasn't found is asked again after this long (its release may have come to Deezer since).
  static const Duration retryAfter = Duration(days: 30);

  static const String _enabledKey = 'online_lookups';

  final Map<String, AlbumFacts> _known = {};
  bool _running = false;
  bool _stop = false;

  /// What is known about the album [albumId]; null when nothing was found.
  AlbumFacts? of(String albumId) => _known[albumId];

  /// Whether music is looked up online (albums here, credits by [CreditLookupService], artists and styles by their
  /// lookups); on until an administrator turns it off.
  bool get enabled =>
      _db.connection.select('SELECT value FROM settings WHERE key = ?', [_enabledKey]).firstOrNull?['value'] != '0';

  set enabled(bool on) {
    _db.connection.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [_enabledKey, on ? '1' : '0'],
    );
    if (!on) _stop = true;
  }

  /// Looks up the [albums] not asked about yet (or not found [retryAfter] ago), one after another, while [enabled];
  /// [onLearned] hears of what was found, every few albums and at the end. A run already going on goes on instead; a
  /// network failure ends the run (the next scan starts another).
  Future<void> run(List<Album> albums, {required void Function() onLearned}) async {
    if (_running || !enabled) return;
    _running = true;
    _stop = false;
    var learned = 0;
    try {
      final asked = {
        for (final row in _db.connection.select('SELECT album_id, found, looked_up_at FROM album_lookups'))
          row['album_id'] as String: (found: row['found'] == 1, at: fromDbTime(row['looked_up_at'])),
      };
      final now = DateTime.now().toUtc();
      for (final album in albums) {
        if (_stop) break;
        final before = asked[album.id];
        if (before != null && (before.found || now.difference(before.at ?? now) < retryAfter)) continue;
        final facts = await _lookUp(album);
        _remember(album.id, facts);
        if (facts != null && ++learned % 20 == 0) onLearned();
      }
    } on Exception catch (e) {
      WiretuneLog.info('AlbumLookup', 'Stopped looking albums up for now: $e');
    } finally {
      _running = false;
      if (learned % 20 != 0) onLearned();
    }
  }

  void _remember(String albumId, AlbumFacts? facts) {
    _db.connection.execute(
      'INSERT INTO album_lookups (album_id, looked_up_at, found, genre, label) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(album_id) DO UPDATE SET looked_up_at = excluded.looked_up_at, found = excluded.found, '
      'genre = excluded.genre, label = excluded.label',
      [albumId, toDbTime(DateTime.now().toUtc()), facts == null ? 0 : 1, facts?.genre, facts?.label],
    );
    if (facts != null) _known[albumId] = facts;
  }

  /// The album's genre and label on Deezer; null when Deezer doesn't have it. Throws when Deezer can't be reached.
  Future<AlbumFacts?> _lookUp(Album album) async {
    final details = [for (final track in album.tracks) track.details];
    for (final barcode in {for (final d in details) ?d.barcode}) {
      for (final code in Deezer.barcodeForms(barcode)) {
        if (await _deezer.get('/album/upc:$code') case final found?) return _facts(found);
      }
    }
    for (final isrc in {for (final d in details) ?d.isrc}.take(2)) {
      final track = await _deezer.get('/track/isrc:${Uri.encodeComponent(isrc)}');
      if (track?['album'] case {'id': final int id}) {
        if (await _deezer.get('/album/$id') case final found?) return _facts(found);
      }
    }
    // Untagged files gather under a made-up album and artist, which name nothing to look for.
    if (album.title == Track.unknownAlbum || Track.isUnknownArtist(album.artist)) return null;
    final query = 'artist:"${_quoted(album.artist)}" album:"${_quoted(album.title)}"';
    final results = await _deezer.get('/search/album?q=${Uri.encodeQueryComponent(query)}&limit=5');
    for (final hit in (results?['data'] as List?) ?? const []) {
      if (hit case {
        'id': final int id,
        'title': final String title,
        'artist': {'name': final String artist},
      } when sameName(title, album.title) && sameName(artist, album.artist)) {
        if (await _deezer.get('/album/$id') case final found?) return _facts(found);
      }
    }
    return null;
  }

  static AlbumFacts? _facts(Map<String, Object?> album) {
    // Deezer's first genre is the album's main one.
    final genre = switch (album['genres']) {
      {'data': [{'name': final String name}, ...]} => name,
      _ => null,
    };
    final label = album['label'];
    final facts = (
      genre: genre != null && genre.trim().isNotEmpty ? genre.trim() : null,
      label: label is String && label.trim().isNotEmpty ? label.trim() : null,
    );
    return facts.genre == null && facts.label == null ? null : facts;
  }

  static String _quoted(String text) => text.replaceAll('"', ' ');

  void close() => _stop = true;
}
