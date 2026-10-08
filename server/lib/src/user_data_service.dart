// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:wiretune_core/wiretune_core.dart';

/// Favourites, play statistics and playlists of each account. They live in the server's database, next to the account
/// itself, so they follow the person to every device and survive a restart of the server and a sign-out of a player.
/// Every method takes the account ID from the validated token; nothing here can reach another account's rows. The
/// limits are part of each insert's SQL, so parallel requests cannot go past them.
class UserDataService {
  UserDataService(this._db) {
    _db.initializeSchema();
  }

  final DatabaseManager _db;

  static const String _favoriteInsertSql = '''
    INSERT OR IGNORE INTO user_favorites (user_id, track_id, added_at)
    SELECT ?1, ?2, ?3
    WHERE (SELECT COUNT(*) FROM user_favorites WHERE user_id = ?1) < ?4''';

  static const String _playUpdateSql = '''
    UPDATE user_plays
    SET play_count = CASE WHEN play_count < 2147483647 THEN play_count + 1 ELSE play_count END, last_played = ?3
    WHERE user_id = ?1 AND track_id = ?2''';

  static const String _playlistUpdateSql = '''
    UPDATE user_playlists
    SET name = ?3, description = ?4, track_ids_json = ?5, modified_at = ?6
    WHERE user_id = ?1 AND id = ?2''';

  UserDataSnapshot get(String userId) {
    final db = _db.connection;
    final favoriteRows = db.select(
      'SELECT track_id, added_at FROM user_favorites WHERE user_id = ? ORDER BY added_at, track_id',
      [userId],
    );
    final favorites = [for (final r in favoriteRows) r['track_id'] as String];
    final favoritedAt = {for (final r in favoriteRows) r['track_id'] as String: ?fromDbTime(r['added_at'])};
    final plays = db
        .select('SELECT track_id, play_count, last_played FROM user_plays WHERE user_id = ?', [userId])
        .map(_toStats)
        .toList();
    final playlists = db
        .select(
          'SELECT id, name, description, track_ids_json, created_at, modified_at FROM user_playlists '
          'WHERE user_id = ? ORDER BY name COLLATE NOCASE, id',
          [userId],
        )
        .map(_toPlaylist)
        .toList();
    return UserDataSnapshot(favorites, plays, playlists, favoritedAt);
  }

  /// False when the account is at its favourites limit and nothing was added.
  bool setFavorite(String userId, String trackId, bool favorite) {
    final db = _db.connection;
    if (!favorite) {
      db.execute('DELETE FROM user_favorites WHERE user_id = ? AND track_id = ?', [userId, trackId]);
      return true;
    }
    db.execute(_favoriteInsertSql, [userId, trackId, toDbTime(DateTime.now()), UserDataRules.maxFavorites]);
    return db.select('SELECT 1 FROM user_favorites WHERE user_id = ? AND track_id = ?', [userId, trackId]).isNotEmpty;
  }

  /// Counts one more play of a track. Null when the account is at its statistics limit.
  TrackPlayStats? recordPlay(String userId, String trackId) {
    final db = _db.connection;
    final now = toDbTime(DateTime.now());

    // Update first: the common case is a track that already has a row, and it needs no count.
    db.execute(_playUpdateSql, [userId, trackId, now]);
    if (db.updatedRows == 0) {
      db.execute(
        'INSERT OR IGNORE INTO user_plays (user_id, track_id, play_count, last_played) '
        'SELECT ?1, ?2, 1, ?3 WHERE (SELECT COUNT(*) FROM user_plays WHERE user_id = ?1) < ?4',
        [userId, trackId, now, UserDataRules.maxTrackStats],
      );
      if (db.updatedRows == 0) return null; // at the limit
    }

    final row = db.select(
      'SELECT track_id, play_count, last_played FROM user_plays WHERE user_id = ? AND track_id = ?',
      [userId, trackId],
    ).first;
    return _toStats(row);
  }

  /// Creates the playlist or replaces its name, description and tracks. Null when it is new and the account is at its
  /// playlist limit. The caller has validated the input with [validatePlaylist].
  PlaylistData? savePlaylist(String userId, String playlistId, PlaylistUpdate update) {
    final db = _db.connection;
    final now = toDbTime(DateTime.now());
    final name = update.name!.trim();
    final description = isBlank(update.description) ? null : update.description!.trim();
    final tracks = jsonEncode(update.trackIds ?? const <String>[]);

    db.execute(_playlistUpdateSql, [userId, playlistId, name, description, tracks, now]);
    if (db.updatedRows == 0) {
      db.execute(
        'INSERT OR IGNORE INTO user_playlists (user_id, id, name, description, track_ids_json, created_at, modified_at) '
        'SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?6 WHERE (SELECT COUNT(*) FROM user_playlists WHERE user_id = ?1) < ?7',
        [userId, playlistId, name, description, tracks, now, UserDataRules.maxPlaylists],
      );
      if (db.updatedRows == 0) return null;
    }

    final row = db.select(
      'SELECT id, name, description, track_ids_json, created_at, modified_at FROM user_playlists WHERE user_id = ? AND id = ?',
      [userId, playlistId],
    ).first;
    return _toPlaylist(row);
  }

  bool deletePlaylist(String userId, String playlistId) {
    _db.connection.execute('DELETE FROM user_playlists WHERE user_id = ? AND id = ?', [userId, playlistId]);
    return _db.connection.updatedRows > 0;
  }

  /// Null when the playlist may be stored, otherwise the reason it may not.
  static String? validatePlaylist(String playlistId, PlaylistUpdate? update) {
    final idError = UserDataRules.validateId(playlistId);
    if (idError != null) return idError;
    if (update == null) return 'The playlist is missing.';
    final PlaylistUpdate(:name, :description, :trackIds) = update;
    if (isBlank(name)) return 'The playlist name must not be empty.';
    if (name!.trim().length > UserDataRules.maxPlaylistNameLength) {
      return 'The playlist name must be at most ${UserDataRules.maxPlaylistNameLength} characters.';
    }
    if (description != null && description.trim().length > UserDataRules.maxPlaylistDescriptionLength) {
      return 'The playlist description must be at most ${UserDataRules.maxPlaylistDescriptionLength} characters.';
    }
    if (trackIds == null) return null;
    if (trackIds.length > UserDataRules.maxPlaylistTracks) {
      return 'A playlist can hold at most ${UserDataRules.maxPlaylistTracks} tracks.';
    }
    for (final id in trackIds) {
      final error = UserDataRules.validateId(id);
      if (error != null) return 'Playlist track: $error';
    }
    return null;
  }

  static TrackPlayStats _toStats(Map<String, Object?> row) {
    final count = row['play_count'] as int;
    return TrackPlayStats(
      row['track_id'] as String,
      count < 0 ? 0 : (count > 0x7FFFFFFF ? 0x7FFFFFFF : count),
      fromDbTime(row['last_played']),
    );
  }

  static PlaylistData _toPlaylist(Map<String, Object?> row) => PlaylistData(
    row['id'] as String,
    row['name'] as String,
    row['description'] as String?,
    decodeTrackIds(row['track_ids_json']),
    fromDbTime(row['created_at']) ?? DateTime.now().toUtc(),
    fromDbTime(row['modified_at']) ?? DateTime.now().toUtc(),
  );
}
