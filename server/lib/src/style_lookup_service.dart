// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:wiretune_core/wiretune_core.dart';

import 'artist_lookup_service.dart' show ArtistLookupService;
import 'online.dart';

/// A style and how strongly it is said of an album or an artist: how many MusicBrainz editors gave it.
typedef Style = (String name, int weight);

/// Looks each album of the library and its artists up on MusicBrainz once, for their genres ("synthwave", "art rock",
/// "hungarian hip hop", each with how many editors gave it): far finer than the one broad genre of a tag or of Deezer,
/// they tell which albums and artists sound alike ([RelatedMusicService]).
///
/// The album is found as a release group: by its barcode, else by a track's MusicBrainz recording ID or ISRC, else by
/// its title and artist. Its credited artists come with it, matched to the album's by name. Only codes and names go
/// out; MusicBrainz allows a request a second, so a big library takes a while, in the background. Not found is asked
/// again after [retryAfter], found after [refreshAfter]. [enabled] is the administrator's switch.
class StyleLookupService {
  StyleLookupService(this._db, this._musicBrainz, {required this.enabled}) {
    for (final row in _db.connection.select('SELECT subject, styles FROM style_lookups WHERE found = 1')) {
      _styles[row['subject'] as String] = [
        for (final style in jsonDecode(row['styles'] as String) as List)
          if (style case [final String name, final int weight]) (name, weight),
      ];
    }
  }

  final DatabaseManager _db;
  final MusicBrainz _musicBrainz;
  final bool Function() enabled;

  static const Duration retryAfter = Duration(days: 30);
  static const Duration refreshAfter = Duration(days: 180);

  /// The most styles kept of one album or artist: the strongest.
  static const int kept = 12;

  final Map<String, List<Style>> _styles = {};
  bool _running = false;
  bool _stop = false;

  /// The styles of the album [albumId], the strongest first; null when not known.
  List<Style>? ofAlbum(String albumId) => _styles['album:$albumId'];

  /// The styles of the artist named [name] (any case), the strongest first; null when not known.
  List<Style>? ofArtist(String name) => _styles['artist:${ArtistLookupService.artistKey(name)}'];

  /// Looks up the [albums] not asked about yet (or due again), with their artists, one request at a time, while
  /// [enabled]; [onLearned] hears of what was found, every few albums and at the end. A run already going on goes on
  /// instead; a network failure ends the run (the next scan starts another).
  Future<void> run(List<Album> albums, {required void Function() onLearned}) async {
    if (_running || !enabled()) return;
    _running = true;
    _stop = false;
    var learned = 0;
    try {
      final asked = {
        for (final row in _db.connection.select('SELECT subject, found, looked_up_at FROM style_lookups'))
          row['subject'] as String: (found: row['found'] == 1, at: fromDbTime(row['looked_up_at'])),
      };
      final now = DateTime.now().toUtc();
      bool due(String subject) {
        final before = asked[subject];
        return before == null || now.difference(before.at ?? now) >= (before.found ? refreshAfter : retryAfter);
      }

      for (final album in albums) {
        if (_stop || !enabled()) break;
        if (!due('album:${album.id}')) continue;
        final group = await _releaseGroupOf(album);
        final styles = group == null ? null : await _genres('/release-group/${group.id}?inc=genres');
        _remember(asked, 'album:${album.id}', styles);
        // Its artists, each once, as MusicBrainz credits them on the release.
        for (final credited in group?.artists ?? const <(String, String)>[]) {
          final (id, name) = credited;
          final ours = album.artistNames.where((n) => sameName(n, name)).firstOrNull;
          final subject = 'artist:${ArtistLookupService.artistKey(ours ?? name)}';
          if (ours == null || !due(subject) || _stop) continue;
          _remember(asked, subject, await _genres('/artist/${Uri.encodeComponent(id)}?inc=genres'));
        }
        if (styles != null && ++learned % 10 == 0) onLearned();
      }
    } on Exception catch (e) {
      WiretuneLog.info('StyleLookup', 'Stopped looking styles up for now: $e');
    } finally {
      _running = false;
      if (learned % 10 != 0) onLearned();
    }
  }

  void _remember(Map<String, ({bool found, DateTime? at})> asked, String subject, List<Style>? styles) {
    final found = styles != null && styles.isNotEmpty;
    final now = DateTime.now().toUtc();
    _db.connection.execute(
      'INSERT INTO style_lookups (subject, looked_up_at, found, styles) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(subject) DO UPDATE SET looked_up_at = excluded.looked_up_at, found = excluded.found, '
      'styles = excluded.styles',
      [
        subject,
        toDbTime(now),
        found ? 1 : 0,
        found
            ? jsonEncode([
                for (final (name, weight) in styles) [name, weight],
              ])
            : null,
      ],
    );
    asked[subject] = (found: found, at: now);
    if (found) {
      _styles[subject] = styles;
    } else {
      _styles.remove(subject);
    }
  }

  /// The genres MusicBrainz gives at [path], the strongest first; null when it has none.
  Future<List<Style>?> _genres(String path) async {
    final answer = await _musicBrainz.get(path);
    final styles = [
      for (final genre in (answer?['genres'] as List?) ?? const [])
        if (genre case {'name': final String name, 'count': final int count} when count > 0 && name.trim().isNotEmpty)
          (name.trim().toLowerCase(), count),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return styles.isEmpty ? null : styles.take(kept).toList();
  }

  /// [album]'s release group on MusicBrainz, with its credited artists (ID, name); null when not found.
  Future<({String id, List<(String, String)> artists})?> _releaseGroupOf(Album album) async {
    final details = [for (final track in album.tracks) track.details];
    for (final barcode in {for (final d in details) ?d.barcode}.take(1)) {
      for (final code in Deezer.barcodeForms(barcode)) {
        final answer = await _musicBrainz.get('/release?query=${Uri.encodeQueryComponent('barcode:$code')}&limit=5');
        if (_fromReleases(answer?['releases'], album, (release) => release['artist-credit']) case final found?) {
          return found;
        }
      }
    }
    final recordings = [
      for (final d in details)
        if (d.musicBrainzTrackId case final id?) 'rid:$id' else if (d.isrc case final isrc?) 'isrc:$isrc',
    ];
    for (final query in recordings.toSet().take(2)) {
      final answer = await _musicBrainz.get('/recording?query=${Uri.encodeQueryComponent(query)}&limit=1');
      if (answer?['recordings'] case [final Map<String, Object?> recording, ...]) {
        if (_fromReleases(recording['releases'], album, (_) => recording['artist-credit']) case final found?) {
          return found;
        }
      }
    }
    // Untagged files gather under a made-up album and artist, which name nothing to look for.
    if (album.title == Track.unknownAlbum || Track.isUnknownArtist(album.artist)) return null;
    final query =
        'releasegroup:${MusicBrainz.phrase(album.title)} AND artist:${MusicBrainz.phrase(album.artistNames.first)}';
    final answer = await _musicBrainz.get('/release-group?query=${Uri.encodeQueryComponent(query)}&limit=5');
    for (final group in (answer?['release-groups'] as List?) ?? const []) {
      if (group case {'id': final String id, 'title': final String title} when sameName(title, album.title)) {
        final artists = _credited(group['artist-credit']);
        if (artists.any((a) => album.artistNames.any((n) => sameName(n, a.$2)))) return (id: id, artists: artists);
      }
    }
    return null;
  }

  /// The release group of the release among [releases] titled as [album] (else the first), with the artists
  /// [creditOf] gives for it.
  static ({String id, List<(String, String)> artists})? _fromReleases(
    Object? releases,
    Album album,
    Object? Function(Map<String, Object?> release) creditOf,
  ) {
    final list = [
      for (final release in releases is List ? releases : const [])
        if (release case {'release-group': {'id': final String _}}) release as Map<String, Object?>,
    ];
    if (list.isEmpty) return null;
    final release = list.where((r) => r['title'] is String && sameName(r['title'] as String, album.title)).firstOrNull;
    final chosen = release ?? list.first;
    return (id: (chosen['release-group'] as Map)['id'] as String, artists: _credited(creditOf(chosen)));
  }

  /// The artists (ID, name) of a MusicBrainz artist credit.
  static List<(String, String)> _credited(Object? credit) => [
    for (final part in credit is List ? credit : const [])
      if (part case {'artist': {'id': final String id, 'name': final String name}}) (id, name),
  ];

  void close() => _stop = true;
}
