// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wiretune_core/wiretune_core.dart';

/// The server could not reach ListenBrainz (or it answered with a failure of its own).
class ScrobbleUnreachableException implements Exception {
  const ScrobbleUnreachableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The token ListenBrainz does not accept.
class ScrobbleTokenInvalidException implements Exception {
  const ScrobbleTokenInvalidException();
}

/// Every play of every account is kept (what the statistics are made of). For an account that connected
/// [ListenBrainz](https://listenbrainz.org), each is also sent there, so that every player of the account scrobbles once,
/// from the one place that hears them all. What can't be sent now (ListenBrainz or the network is down) waits and is
/// tried again, later each time, until it goes. Nothing is sent for an account that has not connected, and what was
/// played before it connected is never sent.
class Scrobbler {
  Scrobbler(this._db, this._trackOf, {Uri? endpoint, Duration firstRetry = const Duration(seconds: 30)})
    : _endpoint = endpoint ?? Uri.parse('https://api.listenbrainz.org'),
      _firstRetry = firstRetry;

  final DatabaseManager _db;
  final Track? Function(String trackId) _trackOf;
  final Uri _endpoint;
  final Duration _firstRetry;

  static const Duration _lastRetry = Duration(minutes: 30);
  static const Duration _timeout = Duration(seconds: 20);

  /// How many listens go in one request (ListenBrainz takes up to 1000, but keeps requests small for slow links).
  static const int _batch = 50;

  /// Listens older than this are not sent any more: a week of ListenBrainz being out of reach is long enough.
  static const Duration _stale = Duration(days: 7);

  Timer? _retry;
  Duration _nextRetry = Duration.zero;
  Future<void>? _draining;
  bool _closed = false;

  // ── The connection ─────────────────────────────────────────────────────────────────────────────

  /// The name [userId] has on ListenBrainz; null when the account has not connected.
  String? connectedName(String userId) =>
      _db.connection.select('SELECT user_name FROM user_listenbrainz WHERE user_id = ?', [
            userId,
          ]).firstOrNull?['user_name']
          as String?;

  /// Connects [userId] with the user token from ListenBrainz's settings. Throws [ScrobbleTokenInvalidException] for a
  /// token it does not accept and [ScrobbleUnreachableException] when it can't ask. Returns the name on ListenBrainz.
  Future<String> connect(String userId, String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty || trimmed.length > 200 || RegExp(r'\s').hasMatch(trimmed)) {
      throw const ScrobbleTokenInvalidException();
    }
    final answer = await _request('GET', '/1/validate-token', trimmed);
    final body = answer.json;
    if (answer.status != 200 || body is! Map || body['valid'] != true || body['user_name'] is! String) {
      if (answer.status >= 500 || answer.status == 429) {
        throw ScrobbleUnreachableException('ListenBrainz answered ${answer.status}.');
      }
      throw const ScrobbleTokenInvalidException();
    }
    final name = body['user_name'] as String;
    _db.connection.execute(
      'INSERT INTO user_listenbrainz (user_id, token, user_name) VALUES (?1, ?2, ?3) '
      'ON CONFLICT (user_id) DO UPDATE SET token = ?2, user_name = ?3',
      [userId, trimmed, name],
    );
    return name;
  }

  /// Stops sending for [userId]; what was waiting is dropped.
  void disconnect(String userId) => _db.transaction((db) {
    db.execute('DELETE FROM user_listenbrainz WHERE user_id = ?', [userId]);
    db.execute('UPDATE user_listens SET sent = 2 WHERE user_id = ? AND sent = 0', [userId]);
  });

  // ── The listens ────────────────────────────────────────────────────────────────────────────────

  /// [userId] listened to [trackId] just now: it is kept, and sent when the account is connected.
  void listened(String userId, String trackId) {
    if (_closed) return;
    final connected = connectedName(userId) != null;
    _db.connection.execute('INSERT INTO user_listens (user_id, track_id, listened_at, sent) VALUES (?, ?, ?, ?)', [
      userId,
      trackId,
      toDbTime(DateTime.now().toUtc()),
      connected ? 0 : 2,
    ]);
    if (connected) unawaited(flush());
  }

  /// How many listens wait to be sent.
  int get waiting => _db.connection.select('SELECT COUNT(*) AS n FROM user_listens WHERE sent = 0').first['n'] as int;

  /// Sends what waits, now; one run at a time. Completes when the waiting listens were sent or tried (a failure puts
  /// the next try off).
  Future<void> flush() => _draining ??= _drain().whenComplete(() {
    _draining = null;
  });

  Future<void> _drain() async {
    if (_closed) return;
    var failed = false;
    try {
      // Too old to send any more.
      _db.connection.execute('UPDATE user_listens SET sent = 2 WHERE sent = 0 AND listened_at < ?', [
        toDbTime(DateTime.now().toUtc().subtract(_stale)),
      ]);

      final users = [
        for (final row in _db.connection.select('SELECT DISTINCT user_id FROM user_listens WHERE sent = 0'))
          row['user_id'] as String,
      ];
      for (final userId in users) {
        if (_closed) return;
        if (!await _drainUser(userId)) failed = true;
      }
    } on Object catch (e, s) {
      WiretuneLog.error('Scrobbler', 'Sending listens failed: $e', e, s);
      failed = true;
    }
    if (_closed) return;
    if (failed) {
      _nextRetry = _nextRetry == Duration.zero ? _firstRetry : _min(_nextRetry * 2, _lastRetry);
      _retry?.cancel();
      _retry = Timer(_nextRetry, () => unawaited(flush()));
    } else {
      _nextRetry = Duration.zero;
    }
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  /// Sends the waiting listens of [userId], a batch at a time; false when something has to be tried again.
  Future<bool> _drainUser(String userId) async {
    final token =
        _db.connection.select('SELECT token FROM user_listenbrainz WHERE user_id = ?', [userId]).firstOrNull?['token']
            as String?;
    if (token == null) {
      _db.connection.execute('UPDATE user_listens SET sent = 2 WHERE user_id = ? AND sent = 0', [userId]);
      return true;
    }
    while (!_closed) {
      final rows = _db.connection.select(
        'SELECT id, track_id, listened_at FROM user_listens WHERE user_id = ? AND sent = 0 ORDER BY id LIMIT $_batch',
        [userId],
      );
      if (rows.isEmpty) return true;

      final payload = <Map<String, Object?>>[];
      final withoutTrack = <int>[];
      final included = <int>[];
      for (final row in rows) {
        final track = _trackOf(row['track_id'] as String);
        final id = row['id'] as int;
        if (track == null) {
          withoutTrack.add(id); // gone from the library: nothing to say about it
          continue;
        }
        included.add(id);
        payload.add(_listen(track, fromDbTime(row['listened_at']) ?? DateTime.now().toUtc()));
      }
      if (withoutTrack.isNotEmpty) _mark(withoutTrack, 2);
      if (payload.isEmpty) continue;

      final ({int status, Object? json, String text}) answer;
      try {
        answer = await _request(
          'POST',
          '/1/submit-listens',
          token,
          body: {'listen_type': payload.length == 1 ? 'single' : 'import', 'payload': payload},
        );
      } on ScrobbleUnreachableException catch (e) {
        WiretuneLog.info('Scrobbler', 'ListenBrainz is out of reach (${e.message}); trying again later.');
        return false;
      }
      switch (answer.status) {
        case 200:
          _mark(included, 1);
        case 401:
          // The token was taken back: no use trying with it.
          WiretuneLog.warn('Scrobbler', 'ListenBrainz does not accept the token of an account any more; disconnected.');
          disconnect(userId);
          return true;
        case 429:
        case >= 500:
          WiretuneLog.warn('Scrobbler', 'ListenBrainz answered ${answer.status}; trying again later.');
          return false;
        default:
          // It refused these listens themselves (a 400): sending them again would only be refused again.
          WiretuneLog.warn(
            'Scrobbler',
            'ListenBrainz refused ${included.length} listens (${answer.status}): ${answer.text}',
          );
          _mark(included, 2);
      }
    }
    return true;
  }

  void _mark(List<int> ids, int state) {
    if (ids.isEmpty) return;
    _db.connection.execute('UPDATE user_listens SET sent = ? WHERE id IN (${List.filled(ids.length, '?').join(',')})', [
      state,
      ...ids,
    ]);
  }

  static Map<String, Object?> _listen(Track track, DateTime at) => {
    'listened_at': at.millisecondsSinceEpoch ~/ 1000,
    'track_metadata': {
      'artist_name': track.artist,
      'track_name': track.title,
      if (track.album.isNotEmpty && track.album != Track.unknownAlbum) 'release_name': track.album,
      'additional_info': {
        'media_player': 'Wiretune',
        'media_player_version': WiretuneInfo.version,
        'submission_client': 'Wiretune',
        'submission_client_version': WiretuneInfo.version,
        if (track.duration > Duration.zero) 'duration_ms': track.duration.inMilliseconds,
        if (track.trackNumber != null) 'tracknumber': track.trackNumber,
      },
    },
  };

  // ── The network ────────────────────────────────────────────────────────────────────────────────

  Future<({int status, Object? json, String text})> _request(
    String method,
    String path,
    String token, {
    Object? body,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      // A server behind a path (https://example.org/lb) keeps it in front of the API's.
      final base = _endpoint.path.endsWith('/')
          ? _endpoint.path.substring(0, _endpoint.path.length - 1)
          : _endpoint.path;
      final request = await client.openUrl(method, _endpoint.replace(path: '$base$path')).timeout(_timeout);
      request.headers
        ..set('Authorization', 'Token $token')
        ..set('User-Agent', 'Wiretune/${WiretuneInfo.version} (${WiretuneInfo.sourceUrl})');
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join().timeout(_timeout);
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        // Not JSON: the status says enough.
      }
      return (status: response.statusCode, json: json, text: text.length > 300 ? text.substring(0, 300) : text);
    } on TimeoutException {
      throw const ScrobbleUnreachableException('ListenBrainz did not answer in time.');
    } on SocketException catch (e) {
      throw ScrobbleUnreachableException(e.message);
    } on HttpException catch (e) {
      throw ScrobbleUnreachableException(e.message);
    } on HandshakeException catch (e) {
      throw ScrobbleUnreachableException(e.message);
    } finally {
      client.close(force: true);
    }
  }

  void close() {
    _closed = true;
    _retry?.cancel();
  }
}
