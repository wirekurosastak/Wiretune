// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:wiretune_core/wiretune_core.dart';

/// The accounts each account blocked. A blocked account can't recommend it anything (what it sent before goes too) or
/// invite it to listen together; it isn't told, and sending still looks as if it went.
class BlockService {
  BlockService(this._db);

  final DatabaseManager _db;

  /// The accounts [userId] blocked, by name.
  List<AccountInfo> blocked(String userId) => [
    for (final row in _db.connection.select(
      'SELECT u.id, u.username FROM user_blocks b JOIN users u ON u.id = b.blocked_user_id '
      'WHERE b.user_id = ? ORDER BY u.username COLLATE NOCASE',
      [userId],
    ))
      AccountInfo(row['id'] as String, row['username'] as String),
  ];

  /// Whether [userId] blocked [otherId].
  bool blocks(String userId, String otherId) => _db.connection.select(
    'SELECT 1 FROM user_blocks WHERE user_id = ? AND blocked_user_id = ?',
    [userId, otherId],
  ).isNotEmpty;

  /// [userId] blocks [otherId], an account of the server other than itself, and what [otherId] recommended to it goes.
  /// False when there is no such other account; blocking again changes nothing.
  bool block(String userId, String otherId) => _db.transaction((db) {
    if (otherId == userId || db.select('SELECT 1 FROM users WHERE id = ?', [otherId]).isEmpty) return false;
    db.execute('INSERT OR IGNORE INTO user_blocks (user_id, blocked_user_id, blocked_at) VALUES (?, ?, ?)', [
      userId,
      otherId,
      toDbTime(DateTime.now().toUtc()),
    ]);
    db.execute('DELETE FROM recommendations WHERE to_user_id = ? AND from_user_id = ?', [userId, otherId]);
    return true;
  });

  /// [userId] unblocks [otherId]; what it had recommended before the block doesn't come back.
  void unblock(String userId, String otherId) =>
      _db.connection.execute('DELETE FROM user_blocks WHERE user_id = ? AND blocked_user_id = ?', [userId, otherId]);
}
