// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:wiretune_core/wiretune_core.dart';

/// What the accounts recommend to each other: an artist, an album or a track, with a note. Each account keeps its
/// newest [RecommendationRules.maxKept]; one more pushes out the oldest, so nobody can fill another's.
class RecommendationService {
  RecommendationService(this._db);

  final DatabaseManager _db;

  /// What [userId] was recommended, the newest first, with who sent it.
  List<Recommendation> received(String userId) => [
    for (final row in _db.connection.select(
      'SELECT r.id, r.from_user_id, u.username, r.item_type, r.item_id, r.note, r.sent_at, r.seen '
      'FROM recommendations r JOIN users u ON u.id = r.from_user_id '
      'WHERE r.to_user_id = ? ORDER BY r.sent_at DESC, r.id',
      [userId],
    ))
      if (RecommendationKind.parse(row['item_type']) case final kind?)
        Recommendation(
          row['id'] as String,
          AccountInfo(row['from_user_id'] as String, row['username'] as String),
          kind,
          row['item_id'] as String,
          row['note'] as String,
          fromDbTime(row['sent_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          seen: row['seen'] == 1,
        ),
  ];

  /// Recommends [itemId] from [fromUserId] to each of [toUserIds] (accounts that exist, not the sender); returns the
  /// IDs of what was sent, one per recipient, in their order.
  List<String> send(String fromUserId, List<String> toUserIds, RecommendationKind kind, String itemId, String note) =>
      _db.transaction((db) {
        final sentAt = toDbTime(DateTime.now().toUtc());
        final insert = db.prepare(
          'INSERT INTO recommendations (id, from_user_id, to_user_id, item_type, item_id, note, sent_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        final ids = <String>[];
        try {
          for (final to in toUserIds) {
            final id = newId();
            insert.execute([id, fromUserId, to, kind.name, itemId, note, sentAt]);
            ids.add(id);
            db.execute(
              'DELETE FROM recommendations WHERE to_user_id = ?1 AND id NOT IN '
              '(SELECT id FROM recommendations WHERE to_user_id = ?1 ORDER BY sent_at DESC, id LIMIT ?2)',
              [to, RecommendationRules.maxKept],
            );
          }
        } finally {
          insert.close();
        }
        return ids;
      });

  /// Removes the recommendation [id] that [userId] got or sent (a sender's Undo). Returns who got it, or null when
  /// there is none of [userId]'s.
  String? remove(String userId, String id) => _db.transaction((db) {
    final row = db.select(
      'SELECT to_user_id FROM recommendations WHERE id = ?1 AND (to_user_id = ?2 OR from_user_id = ?2)',
      [id, userId],
    ).firstOrNull;
    if (row == null) return null;
    db.execute('DELETE FROM recommendations WHERE id = ?', [id]);
    return row['to_user_id'] as String;
  });

  /// [userId] has seen what it was recommended so far.
  void markSeen(String userId) =>
      _db.connection.execute('UPDATE recommendations SET seen = 1 WHERE to_user_id = ? AND seen = 0', [userId]);
}
