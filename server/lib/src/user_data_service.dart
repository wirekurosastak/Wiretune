// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:wiretune_core/wiretune_core.dart';

/// Favourites, play statistics and playlists of each account. They live in the server's database, next to the account
/// itself, so they follow the person to every device and survive a restart of the server and a sign-out of a player.
/// Every method takes the account ID from the validated token; nothing here can reach another account's rows, but the
/// tracks of a playlist its owner shares with that account ([sharePlaylist]). The limits are part of each insert's SQL,
/// so parallel requests cannot go past them.
class UserDataService {
  UserDataService(this._db);

  final DatabaseManager _db;

  /// Whether the first account blocks the second: an invitation to a playlist from an account it blocks doesn't show.
  bool Function(String userId, String otherId) blocks = (_, _) => false;

  static const String _favoriteInsertSql = '''
    INSERT OR IGNORE INTO user_favorites (user_id, track_id, favorited_at)
    SELECT ?1, ?2, ?3
    WHERE (SELECT COUNT(*) FROM user_favorites WHERE user_id = ?1) < ?4''';

  static const String _playUpdateSql = '''
    UPDATE user_plays
    SET play_count = CASE WHEN play_count < 2147483647 THEN play_count + 1 ELSE play_count END,
        last_played_at = MAX(COALESCE(last_played_at, ?3), ?3)
    WHERE user_id = ?1 AND track_id = ?2''';

  static const String _playlistUpdateSql = '''
    UPDATE user_playlists
    SET name = ?3, description = ?4, track_ids_json = ?5, modified_at = ?6
    WHERE user_id = ?1 AND id = ?2''';

  static const String _hiddenInsertSql = '''
    INSERT OR IGNORE INTO user_hidden (user_id, item_type, item_id, hidden_at)
    SELECT ?1, ?2, ?3, ?4
    WHERE (SELECT COUNT(*) FROM user_hidden WHERE user_id = ?1) < ?5''';

  UserDataSnapshot get(String userId) {
    final db = _db.connection;
    final favoriteRows = db.select(
      'SELECT track_id, favorited_at FROM user_favorites WHERE user_id = ? ORDER BY favorited_at, track_id',
      [userId],
    );
    final favorites = [for (final r in favoriteRows) r['track_id'] as String];
    final favoritedAt = {for (final r in favoriteRows) r['track_id'] as String: ?fromDbTime(r['favorited_at'])};
    final plays = db
        .select('SELECT track_id, play_count, last_played_at FROM user_plays WHERE user_id = ?', [userId])
        .map(_toStats)
        .toList();
    final playlists = playlistsOf(userId);
    final hiddenRows = db.select('SELECT item_type, item_id FROM user_hidden WHERE user_id = ? ORDER BY hidden_at', [
      userId,
    ]);
    final hidden = {for (final kind in HiddenKind.values) kind: <String>[]};
    for (final r in hiddenRows) {
      hidden[HiddenKind.parse(r['item_type'])]?.add(r['item_id'] as String);
    }
    return UserDataSnapshot(
      favorites,
      plays,
      playlists,
      favoritedAt,
      hidden[HiddenKind.artist]!,
      hidden[HiddenKind.album]!,
      hidden[HiddenKind.track]!,
    );
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

  /// Sets whether an artist, album or track is hidden for [userId]. False when the account is at its hidden limit.
  bool setHidden(String userId, HiddenKind kind, String itemId, bool hidden) {
    final db = _db.connection;
    if (!hidden) {
      db.execute('DELETE FROM user_hidden WHERE user_id = ? AND item_type = ? AND item_id = ?', [
        userId,
        kind.name,
        itemId,
      ]);
      return true;
    }
    db.execute(_hiddenInsertSql, [userId, kind.name, itemId, toDbTime(DateTime.now()), UserDataRules.maxHidden]);
    return db.select('SELECT 1 FROM user_hidden WHERE user_id = ? AND item_type = ? AND item_id = ?', [
      userId,
      kind.name,
      itemId,
    ]).isNotEmpty;
  }

  /// Counts one more play of a track, made [at] that time (a player tells of a play later when it couldn't reach the
  /// server): now without it, or when it lies in the future. Null when the account is at its statistics limit.
  TrackPlayStats? recordPlay(String userId, String trackId, [DateTime? at]) {
    final db = _db.connection;
    final now = toDbTime(at != null && at.isBefore(DateTime.now()) ? at : DateTime.now());

    // Update first: the common case is a track that already has a row, and it needs no count.
    db.execute(_playUpdateSql, [userId, trackId, now]);
    if (db.updatedRows == 0) {
      db.execute(
        'INSERT OR IGNORE INTO user_plays (user_id, track_id, play_count, last_played_at) '
        'SELECT ?1, ?2, 1, ?3 WHERE (SELECT COUNT(*) FROM user_plays WHERE user_id = ?1) < ?4',
        [userId, trackId, now, UserDataRules.maxTrackStats],
      );
      if (db.updatedRows == 0) return null; // at the limit
    }

    // The log for the summaries: the oldest go once an account has played more than it keeps.
    db.execute('INSERT INTO user_play_log (user_id, track_id, played_at) VALUES (?, ?, ?)', [userId, trackId, now]);
    if ((db.select('SELECT COUNT(*) AS n FROM user_play_log WHERE user_id = ?', [userId]).first['n'] as int) >
        UserDataRules.maxPlayLog) {
      db.execute(
        'DELETE FROM user_play_log WHERE rowid IN '
        '(SELECT rowid FROM user_play_log WHERE user_id = ? ORDER BY played_at LIMIT 1000)',
        [userId],
      );
    }

    final rows = db.select(
      'SELECT track_id, play_count, last_played_at FROM user_plays WHERE user_id = ? AND track_id = ?',
      [userId, trackId],
    );
    return rows.isEmpty ? null : _toStats(rows.first);
  }

  /// How often [userId] played each track from [from] until [until] (the log's), and when its log begins.
  ({Map<String, int> plays, DateTime? since}) playsBetween(String userId, DateTime from, DateTime until) {
    final db = _db.connection;
    return (
      plays: {
        for (final row in db.select(
          'SELECT track_id, COUNT(*) AS n FROM user_play_log WHERE user_id = ? AND played_at >= ? AND played_at < ? '
          'GROUP BY track_id',
          [userId, toDbTime(from), toDbTime(until)],
        ))
          row['track_id'] as String: row['n'] as int,
      },
      since: fromDbTime(
        db.select('SELECT MIN(played_at) AS first FROM user_play_log WHERE user_id = ?', [userId]).first['first'],
      ),
    );
  }

  /// The playlists [userId] has, by name: its own, with whom it shares each, and the ones others share with it that it
  /// joined, with their owner and its other members.
  List<PlaylistData> playlistsOf(String userId) {
    final db = _db.connection;
    // Who has each playlist, by its owner and ID: the accounts that joined it and the ones invited.
    final members = <(String, String), ({List<AccountInfo> joined, List<AccountInfo> invited})>{};
    for (final row in db.select(
      'SELECT m.owner_id, m.playlist_id, m.user_id, m.joined_at, u.username FROM playlist_members m '
      'JOIN users u ON u.id = m.user_id '
      'WHERE m.owner_id = ?1 OR (m.owner_id, m.playlist_id) IN '
      '(SELECT owner_id, playlist_id FROM playlist_members WHERE user_id = ?1 AND joined_at IS NOT NULL) '
      'ORDER BY u.username COLLATE NOCASE',
      [userId],
    )) {
      final entry = members[(row['owner_id'] as String, row['playlist_id'] as String)] ??= (joined: [], invited: []);
      final account = AccountInfo(row['user_id'] as String, row['username'] as String);
      (row['joined_at'] == null ? entry.invited : entry.joined).add(account);
    }
    final rows = db.select(
      'SELECT p.user_id, u.username, p.id, p.name, p.description, p.track_ids_json, p.created_at, p.modified_at '
      'FROM user_playlists p JOIN users u ON u.id = p.user_id '
      'WHERE p.user_id = ?1 OR (p.user_id, p.id) IN '
      '(SELECT owner_id, playlist_id FROM playlist_members WHERE user_id = ?1 AND joined_at IS NOT NULL) '
      'ORDER BY p.name COLLATE NOCASE, p.id',
      [userId],
    );
    return [
      for (final row in rows)
        if (row['user_id'] as String case final owner)
          _toPlaylist(row, switch (members[(owner, row['id'] as String)]) {
            null => PlaylistSharing.none,
            final m when owner == userId => PlaylistSharing(members: m.joined, invited: m.invited),
            final m => PlaylistSharing(
              owner: AccountInfo(owner, row['username'] as String),
              members: [
                for (final account in m.joined)
                  if (account.id != userId) account,
              ],
            ),
          }),
    ];
  }

  /// The owner of the playlist [playlistId] that another account shares with [userId], who joined it; null for none.
  String? _sharedOwner(String userId, String playlistId) =>
      _db.connection.select(
            'SELECT owner_id FROM playlist_members WHERE user_id = ? AND playlist_id = ? AND joined_at IS NOT NULL '
            'ORDER BY joined_at LIMIT 1',
            [userId, playlistId],
          ).firstOrNull?['owner_id']
          as String?;

  /// Everyone else who has the playlist [playlistId] as [userId] sees it: the members of its own, or the owner and the
  /// other members of one shared with it. To tell of a change.
  Set<String> playlistAccounts(String userId, String playlistId) {
    final own = _db.connection.select('SELECT 1 FROM user_playlists WHERE user_id = ? AND id = ?', [
      userId,
      playlistId,
    ]).isNotEmpty;
    final owner = own ? userId : _sharedOwner(userId, playlistId);
    if (owner == null) return const {};
    return {
      owner,
      for (final row in _db.connection.select(
        'SELECT user_id FROM playlist_members WHERE owner_id = ? AND playlist_id = ? AND joined_at IS NOT NULL',
        [owner, playlistId],
      ))
        row['user_id'] as String,
    }..remove(userId);
  }

  /// Creates the playlist or replaces its name, description and tracks; for one another account shares with [userId],
  /// its tracks only. Null when it is new and the account is at its playlist limit. The caller has validated the input
  /// with [validatePlaylist].
  PlaylistData? savePlaylist(String userId, String playlistId, PlaylistUpdate update) {
    final db = _db.connection;
    final now = toDbTime(DateTime.now());
    final name = update.name!.trim();
    final description = isBlank(update.description) ? null : update.description!.trim();
    final tracks = jsonEncode(update.trackIds ?? const <String>[]);

    db.execute(_playlistUpdateSql, [userId, playlistId, name, description, tracks, now]);
    final updated = db.updatedRows > 0;
    final sharedBy = updated ? null : _sharedOwner(userId, playlistId);
    if (sharedBy != null) {
      db.execute('UPDATE user_playlists SET track_ids_json = ?3, modified_at = ?4 WHERE user_id = ?1 AND id = ?2', [
        sharedBy,
        playlistId,
        tracks,
        now,
      ]);
    } else if (!updated) {
      db.execute(
        'INSERT OR IGNORE INTO user_playlists (user_id, id, name, description, track_ids_json, created_at, modified_at) '
        'SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?6 WHERE (SELECT COUNT(*) FROM user_playlists WHERE user_id = ?1) < ?7',
        [userId, playlistId, name, description, tracks, now, UserDataRules.maxPlaylists],
      );
      if (db.updatedRows == 0) return null;
    }

    return playlistsOf(userId).where((p) => p.id == playlistId).firstOrNull;
  }

  /// Deletes [userId]'s playlist, and its sharing; for one another account shares with it, leaves it. False when it
  /// has neither.
  bool deletePlaylist(String userId, String playlistId) => _db.transaction((db) {
    db.execute('DELETE FROM user_playlists WHERE user_id = ? AND id = ?', [userId, playlistId]);
    if (db.updatedRows > 0) {
      db.execute('DELETE FROM playlist_members WHERE owner_id = ? AND playlist_id = ?', [userId, playlistId]);
      return true;
    }
    db.execute('DELETE FROM playlist_members WHERE user_id = ? AND playlist_id = ? AND joined_at IS NOT NULL', [
      userId,
      playlistId,
    ]);
    return db.updatedRows > 0;
  });

  /// [ownerId] shares its playlist [playlistId] with [memberId] (another account of the server): an invitation, which
  /// [joinPlaylist] accepts; sharing again changes nothing. Null when it has no such playlist; false when the playlist
  /// is shared with [UserDataRules.maxPlaylistMembers] already.
  bool? sharePlaylist(String ownerId, String playlistId, String memberId) => _db.transaction((db) {
    if (db.select('SELECT 1 FROM user_playlists WHERE user_id = ? AND id = ?', [ownerId, playlistId]).isEmpty) {
      return null;
    }
    db.execute(
      'INSERT OR IGNORE INTO playlist_members (owner_id, playlist_id, user_id, invited_at) '
      'SELECT ?1, ?2, ?3, ?4 WHERE (SELECT COUNT(*) FROM playlist_members WHERE owner_id = ?1 AND playlist_id = ?2) < ?5',
      [ownerId, playlistId, memberId, toDbTime(DateTime.now()), UserDataRules.maxPlaylistMembers],
    );
    return db.updatedRows > 0 ||
        db.select('SELECT 1 FROM playlist_members WHERE owner_id = ? AND playlist_id = ? AND user_id = ?', [
          ownerId,
          playlistId,
          memberId,
        ]).isNotEmpty;
  });

  /// [ownerId] stops sharing its playlist [playlistId] with [memberId] (a member or an invitation). False when it had
  /// not shared it with [memberId].
  bool unsharePlaylist(String ownerId, String playlistId, String memberId) {
    _db.connection.execute('DELETE FROM playlist_members WHERE owner_id = ? AND playlist_id = ? AND user_id = ?', [
      ownerId,
      playlistId,
      memberId,
    ]);
    return _db.connection.updatedRows > 0;
  }

  /// The invitations to playlists [userId] has, the newest first; none from an account it blocks.
  List<PlaylistInvite> playlistInvites(String userId) => [
    for (final row in _db.connection.select(
      'SELECT p.id, p.name, p.track_ids_json, u.id AS owner_id, u.username FROM playlist_members m '
      'JOIN user_playlists p ON p.user_id = m.owner_id AND p.id = m.playlist_id JOIN users u ON u.id = m.owner_id '
      'WHERE m.user_id = ? AND m.joined_at IS NULL ORDER BY m.invited_at DESC, p.id',
      [userId],
    ))
      if (!blocks(userId, row['owner_id'] as String))
        PlaylistInvite(
          row['id'] as String,
          row['name'] as String,
          AccountInfo(row['owner_id'] as String, row['username'] as String),
          decodeTrackIds(row['track_ids_json']).length,
        ),
  ];

  /// [userId] accepts its invitation to [playlistId]: the playlist, as it has it now; null when it has no such
  /// invitation.
  PlaylistData? joinPlaylist(String userId, String playlistId) {
    final owner = playlistInvites(userId).where((i) => i.playlistId == playlistId).firstOrNull?.owner.id;
    if (owner == null) return null;
    _db.connection.execute(
      'UPDATE playlist_members SET joined_at = ? WHERE owner_id = ? AND playlist_id = ? AND user_id = ?',
      [toDbTime(DateTime.now()), owner, playlistId, userId],
    );
    return playlistsOf(userId).where((p) => p.id == playlistId).firstOrNull;
  }

  /// [userId] turns down its invitation to [playlistId]: the account that invited it, or null when there was none.
  String? declinePlaylist(String userId, String playlistId) => _db.transaction((db) {
    final row = db.select(
      'SELECT owner_id FROM playlist_members WHERE user_id = ? AND playlist_id = ? AND joined_at IS NULL',
      [userId, playlistId],
    ).firstOrNull;
    if (row == null) return null;
    db.execute('DELETE FROM playlist_members WHERE user_id = ? AND playlist_id = ? AND joined_at IS NULL', [
      userId,
      playlistId,
    ]);
    return row['owner_id'] as String;
  });

  /// Ends the sharing of playlists between [userId] and [otherId], either way (one blocked the other). Whether there
  /// was any.
  bool endSharing(String userId, String otherId) {
    _db.connection.execute(
      'DELETE FROM playlist_members WHERE (owner_id = ?1 AND user_id = ?2) OR (owner_id = ?2 AND user_id = ?1)',
      [userId, otherId],
    );
    return _db.connection.updatedRows > 0;
  }

  /// The accounts [userId] shares playlists with or has shared ones from, invitations too.
  Set<String> sharingPartners(String userId) => {
    for (final row in _db.connection.select(
      'SELECT CASE WHEN owner_id = ?1 THEN user_id ELSE owner_id END AS other FROM playlist_members '
      'WHERE owner_id = ?1 OR user_id = ?1',
      [userId],
    ))
      row['other'] as String,
  };

  /// Moves what every account has on tracks to their new IDs ([moved]: old ID -> new ID), for files that were moved or
  /// renamed: favourites, play counts, hidden tracks and playlist entries. All or nothing. Returns the accounts that
  /// had something on a moved track.
  Set<String> moveTracks(Map<String, String> moved) {
    if (moved.isEmpty) return const {};
    return _db.transaction((db) {
      final touched = <String>{};

      // Each row is looked up by its key, not by the track: a whole library can move, and the rows are far fewer.
      for (final (table, column, only) in const [
        ('user_favorites', 'track_id', ''),
        ('user_plays', 'track_id', ''),
        ('user_hidden', 'item_id', " AND item_type = 'track'"),
      ]) {
        final rows = [
          for (final row in db.select('SELECT user_id, $column AS id FROM $table WHERE 1 = 1$only'))
            if (moved.containsKey(row['id'])) (row['user_id'] as String, row['id'] as String),
        ];
        // A row moves unless the account has one on the new ID already; either way the old one goes.
        final move = db.prepare('UPDATE OR IGNORE $table SET $column = ?3 WHERE user_id = ?1 AND $column = ?2$only');
        final leave = db.prepare('DELETE FROM $table WHERE user_id = ?1 AND $column = ?2$only');
        try {
          for (final (user, before) in rows) {
            move.execute([user, before, moved[before]]);
            leave.execute([user, before]);
            touched.add(user);
          }
        } finally {
          move.close();
          leave.close();
        }
      }

      // The log has no row of its own per track: each play of a moved one goes with it.
      final relog = db.prepare('UPDATE user_play_log SET track_id = ?2 WHERE track_id = ?1');
      try {
        for (final MapEntry(key: before, value: after) in moved.entries) {
          relog.execute([before, after]);
        }
      } finally {
        relog.close();
      }

      final update = db.prepare(
        'UPDATE user_playlists SET track_ids_json = ?3, modified_at = ?4 WHERE user_id = ?1 AND id = ?2',
      );
      try {
        final now = toDbTime(DateTime.now());
        for (final row in db.select('SELECT user_id, id, track_ids_json FROM user_playlists')) {
          final ids = decodeTrackIds(row['track_ids_json']);
          if (!ids.any(moved.containsKey)) continue;
          final seen = <String>{};
          final renamed = [
            for (final id in ids)
              if (seen.add(moved[id] ?? id)) moved[id] ?? id,
          ];
          update.execute([row['user_id'], row['id'], jsonEncode(renamed), now]);
          touched.add(row['user_id'] as String);
        }
      } finally {
        update.close();
      }
      return touched;
    });
  }

  /// Null when the playlist may be stored, otherwise the rule it breaks.
  static RuleViolation? validatePlaylist(String playlistId, PlaylistUpdate? update) {
    final idError = UserDataRules.validateId(playlistId);
    if (idError != null) return RuleViolation(ErrorCodes.invalidId, idError);
    if (update == null) return const RuleViolation(ErrorCodes.playlistInvalid, 'The playlist is missing.');
    final PlaylistUpdate(:name, :description, :trackIds) = update;
    if (isBlank(name)) {
      return const RuleViolation(ErrorCodes.playlistNameRequired, 'The playlist name must not be empty.');
    }
    if (name!.trim().length > UserDataRules.maxPlaylistNameLength) {
      return const RuleViolation(
        ErrorCodes.playlistNameTooLong,
        'The playlist name must be at most ${UserDataRules.maxPlaylistNameLength} characters.',
        {'max': UserDataRules.maxPlaylistNameLength},
      );
    }
    if (description != null && description.trim().length > UserDataRules.maxPlaylistDescriptionLength) {
      return const RuleViolation(
        ErrorCodes.playlistDescriptionTooLong,
        'The playlist description must be at most ${UserDataRules.maxPlaylistDescriptionLength} characters.',
        {'max': UserDataRules.maxPlaylistDescriptionLength},
      );
    }
    if (trackIds == null) return null;
    if (trackIds.length > UserDataRules.maxPlaylistTracks) {
      return const RuleViolation(
        ErrorCodes.playlistTooManyTracks,
        'A playlist can hold at most ${UserDataRules.maxPlaylistTracks} tracks.',
        {'max': UserDataRules.maxPlaylistTracks},
      );
    }
    for (final id in trackIds) {
      final error = UserDataRules.validateId(id);
      if (error != null) return RuleViolation(ErrorCodes.invalidId, 'Playlist track: $error');
    }
    return null;
  }

  static TrackPlayStats _toStats(Map<String, Object?> row) {
    final count = row['play_count'] as int;
    return TrackPlayStats(
      row['track_id'] as String,
      count < 0 ? 0 : (count > 0x7FFFFFFF ? 0x7FFFFFFF : count),
      fromDbTime(row['last_played_at']),
    );
  }

  static PlaylistData _toPlaylist(Map<String, Object?> row, [PlaylistSharing sharing = PlaylistSharing.none]) =>
      PlaylistData(
        row['id'] as String,
        row['name'] as String,
        row['description'] as String?,
        decodeTrackIds(row['track_ids_json']),
        fromDbTime(row['created_at']) ?? DateTime.now().toUtc(),
        fromDbTime(row['modified_at']) ?? DateTime.now().toUtc(),
        sharing,
      );
}
