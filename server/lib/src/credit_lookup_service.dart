// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:wiretune_core/wiretune_core.dart';

/// Who did what on a track: the composer its tags name, and what MusicBrainz knows (producers, mixing, the players and
/// their instruments, the writers of the song). Looked up only when a player asks (someone opened the track's credits),
/// by the file's MusicBrainz recording ID, else by its ISRC, and kept in the database; one MusicBrainz didn't know is
/// asked again after [retryAfter]. Only those codes go out. [enabled] is the administrator's switch for the lookups.
class CreditLookupService {
  CreditLookupService(
    this._db, {
    required this.enabled,
    http.Client? client,
    this.pause = const Duration(milliseconds: 1100),
  }) : _client = client ?? http.Client();

  final DatabaseManager _db;
  final http.Client _client;
  final bool Function() enabled;

  /// Between two requests: MusicBrainz allows one a second.
  final Duration pause;

  static const Duration retryAfter = Duration(days: 30);
  static const String _api = 'https://musicbrainz.org/ws/2';

  /// The requests in flight, one after another.
  Future<void> _queue = Future.value();

  /// [track]'s credits: its tags' composer, and what MusicBrainz knows when it may be asked; in [CreditRoles] order.
  Future<List<Credit>> creditsOf(Track track) async {
    final online = await _online(track);
    final composer = track.details.composer;
    return _ordered({
      if (composer != null && !(online ?? const []).any((c) => c.role == CreditRoles.composer))
        for (final name in composer.split(RegExp(r'\s*[;/]\s*')))
          if (name.isNotEmpty) Credit(CreditRoles.composer, name),
      ...?online,
    });
  }

  static List<Credit> _ordered(Set<Credit> credits) =>
      credits.toList()..sort((a, b) => CreditRoles.all.indexOf(a.role).compareTo(CreditRoles.all.indexOf(b.role)));

  /// What MusicBrainz knows about [track], from the database or asked now; null when nothing (or it may not be asked).
  Future<List<Credit>?> _online(Track track) async {
    final row = _db.connection.select('SELECT found, looked_up_at, credits FROM credit_lookups WHERE track_id = ?', [
      track.id,
    ]).firstOrNull;
    if (row != null && row['found'] == 1) {
      return [for (final c in jsonDecode(row['credits'] as String) as List) Credit.fromJson(c)];
    }
    final at = row == null ? null : fromDbTime(row['looked_up_at']);
    if (at != null && DateTime.now().toUtc().difference(at) < retryAfter) return null;
    final details = track.details;
    if (!enabled() || (details.musicBrainzTrackId == null && details.isrc == null)) return null;
    try {
      final credits = await _lookUp(details);
      _db.connection.execute(
        'INSERT INTO credit_lookups (track_id, looked_up_at, found, credits) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(track_id) DO UPDATE SET looked_up_at = excluded.looked_up_at, found = excluded.found, '
        'credits = excluded.credits',
        [
          track.id,
          toDbTime(DateTime.now().toUtc()),
          credits == null ? 0 : 1,
          credits == null ? null : jsonEncode([for (final c in credits) c.toJson()]),
        ],
      );
      return credits;
    } on Exception catch (e) {
      WiretuneLog.info('CreditLookup', 'Could not ask MusicBrainz for credits: $e');
      return null;
    }
  }

  Future<List<Credit>?> _lookUp(TrackDetails details) async {
    var id = details.musicBrainzTrackId;
    if (id == null) {
      final found = await _get('/isrc/${Uri.encodeComponent(details.isrc!)}');
      id = switch (found?['recordings']) {
        [{'id': final String first}, ...] => first,
        _ => null,
      };
      if (id == null) return null;
    }
    final recording = await _get('/recording/${Uri.encodeComponent(id)}?inc=artist-rels+work-rels+work-level-rels');
    if (recording == null) return null;
    final credits = parse(recording);
    return credits.isEmpty ? null : credits;
  }

  /// The credits in a MusicBrainz recording (with its artist and work relationships, and the works' own).
  static List<Credit> parse(Map<String, Object?> recording) {
    final credits = <Credit>{};
    for (final relation in (recording['relations'] as List?) ?? const []) {
      if (relation case {'type': final String type, 'artist': {'name': final String name}}) {
        final attributes = [for (final a in (relation['attributes'] as List?) ?? const []) ?a as String?];
        final role = switch (type) {
          'producer' => CreditRoles.producer,
          'arranger' || 'orchestrator' => CreditRoles.arranger,
          'vocal' => CreditRoles.vocal,
          'instrument' => CreditRoles.instrument,
          'performer' => CreditRoles.performer,
          'programming' => CreditRoles.programming,
          'remixer' => CreditRoles.remixer,
          'mix' => CreditRoles.mix,
          'engineer' || 'audio' || 'mastering' => CreditRoles.engineer,
          'recording' => CreditRoles.recording,
          _ => null,
        };
        if (role == null) continue;
        if (role == CreditRoles.instrument && attributes.isNotEmpty) {
          for (final instrument in attributes) {
            credits.add(Credit(role, name, detail: _capitalized(instrument)));
          }
        } else {
          credits.add(Credit(role, name));
        }
      } else if (relation case {'type': 'performance', 'work': {'relations': final List work}}) {
        for (final writer in work) {
          if (writer case {'type': final String type, 'artist': {'name': final String name}}) {
            final role = switch (type) {
              'composer' => CreditRoles.composer,
              'lyricist' || 'librettist' => CreditRoles.lyricist,
              'writer' => CreditRoles.writer,
              _ => null,
            };
            if (role != null) credits.add(Credit(role, name));
          }
        }
      }
    }
    return _ordered(credits);
  }

  static String _capitalized(String text) => text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

  /// MusicBrainz's answer at [path], or null when it has nothing there; one request at a time, [pause] apart. Throws
  /// when it can't be reached or answers something else.
  Future<Map<String, Object?>?> _get(String path) {
    final answer = _queue.then((_) async {
      await Future<void>.delayed(pause);
      final separator = path.contains('?') ? '&' : '?';
      final response = await _client
          .get(
            Uri.parse('$_api$path${separator}fmt=json'),
            // MusicBrainz asks every client to say what it is and where to find it.
            headers: {'user-agent': 'Wiretune/${WiretuneInfo.version} ( ${WiretuneInfo.sourceUrl} )'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 404 || response.statusCode == 400) return null;
      if (response.statusCode != 200) throw http.ClientException('MusicBrainz answered ${response.statusCode}');
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, Object?>) throw const FormatException('MusicBrainz answered something else.');
      return body;
    });
    _queue = answer.then((_) {}, onError: (Object _) {});
    return answer;
  }

  void close() => _client.close();
}
