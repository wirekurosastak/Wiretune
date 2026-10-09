// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../services/app_paths.dart';

/// The database file belongs to another version of Wiretune: reading it with this schema would misread it.
class IncompatibleDatabaseException implements Exception {
  const IncompatibleDatabaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens the SQLite database and creates its tables. The player and the server share one schema (each uses the tables
/// it needs). Instants are stored as microseconds since the epoch (see `toDbTime`).
///
/// The connection is synchronous and shared: Dart runs one piece of code at a time per isolate, so a transaction made
/// of synchronous calls ([transaction]) can never interleave with another.
class DatabaseManager {
  DatabaseManager([String? customDbPath])
    : databasePath = AppPaths.fullPath(customDbPath ?? p.join(AppPaths.getDataDirectory(), 'wiretune.db')) {
    Directory(p.dirname(databasePath)).createSync(recursive: true);
  }

  /// The schema this build creates and reads. A change to the tables raises it, together with a step in
  /// [initializeSchema] that upgrades a database of the previous version in place.
  static const int schemaVersion = 4;

  final String databasePath;
  Database? _db;
  bool _schemaReady = false;

  /// The shared connection, opened on first use.
  Database get connection {
    final existing = _db;
    if (existing != null) return existing;

    final db = sqlite3.open(databasePath);
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA synchronous = NORMAL;');
    return _db = db;
  }

  /// Runs [action] in one transaction: committed when it returns, rolled back when it throws. [action] must not await.
  T transaction<T>(T Function(Database db) action) {
    final db = connection;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final result = action(db);
      db.execute('COMMIT;');
      return result;
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Creates the tables of a new database, or upgrades one of the previous schema version in place. Safe to call
  /// repeatedly. Throws [IncompatibleDatabaseException] for a database of any other version.
  void initializeSchema() {
    if (_schemaReady) return;

    final db = connection;
    db.execute('PRAGMA journal_mode = WAL;');
    final version = db.userVersion;
    if (version != schemaVersion) {
      final isNew = version == 0 && db.select("SELECT 1 FROM sqlite_master WHERE type = 'table'").isEmpty;
      if (isNew) {
        transaction((db) {
          db.execute(_schema);
          db.userVersion = schemaVersion;
        });
      } else if (version == 1) {
        // 1 -> 4: when each favourite was marked, bpm, and user_hidden table.
        transaction((db) {
          db.execute('ALTER TABLE tracks ADD COLUMN favorited_at INTEGER;');
          db.execute('ALTER TABLE tracks ADD COLUMN bpm INTEGER;');
          db.execute(_userHiddenTable);
          db.userVersion = schemaVersion;
        });
      } else if (version == 2) {
        // 2 -> 4: bpm, and user_hidden table.
        transaction((db) {
          db.execute('ALTER TABLE tracks ADD COLUMN bpm INTEGER;');
          db.execute(_userHiddenTable);
          db.userVersion = schemaVersion;
        });
      } else if (version == 3) {
        // 3 -> 4: user_hidden table.
        transaction((db) {
          db.execute(_userHiddenTable);
          db.userVersion = schemaVersion;
        });
      } else {
        throw IncompatibleDatabaseException(
          "'$databasePath' was made by another version of Wiretune (schema $version, this one reads $schemaVersion). "
          'Move it out of the way to start with an empty one.',
        );
      }
    }
    _schemaReady = true;
  }

  /// Closes the connection; the next use opens it again.
  void close() {
    _db?.close();
    _db = null;
    _schemaReady = false;
  }
}

/// The track IDs held in a `track_ids_json` column (of `playlists` and `user_playlists`); a value that is not a JSON
/// list reads as none, and entries that are not strings are skipped.
List<String> decodeTrackIds(Object? json) {
  if (json is! String) return [];
  try {
    final decoded = jsonDecode(json);
    return decoded is List ? decoded.whereType<String>().toList() : [];
  } on FormatException {
    return [];
  }
}

const String _schema = '''
  -- The library index. A server keeps its own files here; a player keeps its local files and a cache of its server's
  -- tracks (no file path, a stream URL), with the favourite flag and play statistics it shows for each.
  CREATE TABLE tracks (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      artist TEXT NOT NULL,
      album TEXT NOT NULL,
      album_artist TEXT,
      track_number INTEGER,
      track_count INTEGER,
      disc_number INTEGER,
      year INTEGER,
      bpm INTEGER,
      genre TEXT,
      duration_ms INTEGER NOT NULL,
      file_size_bytes INTEGER NOT NULL,
      file_modified INTEGER,
      file_path TEXT NOT NULL,
      stream_url TEXT,
      has_cover_art INTEGER NOT NULL,
      cover_art_path TEXT,
      codec TEXT NOT NULL,
      sample_rate INTEGER NOT NULL,
      bits_per_sample INTEGER NOT NULL,
      channels INTEGER NOT NULL,
      bitrate_kbps INTEGER NOT NULL,
      is_lossless INTEGER NOT NULL,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      play_count INTEGER NOT NULL DEFAULT 0,
      last_played INTEGER,
      date_added INTEGER NOT NULL,
      favorited_at INTEGER
  );

  -- The player's playlists; is_server marks a cached copy of one that belongs to the signed-in server account.
  CREATE TABLE playlists (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      track_ids_json TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL,
      is_server INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
  );

  -- The server's accounts, and each account's favourites, play statistics and playlists.
  CREATE TABLE users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      password_hash TEXT NOT NULL,
      is_admin INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      last_login INTEGER
  );

  CREATE TABLE user_favorites (
      user_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      added_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, track_id)
  );

  CREATE TABLE user_plays (
      user_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      play_count INTEGER NOT NULL DEFAULT 0,
      last_played INTEGER,
      PRIMARY KEY (user_id, track_id)
  );

  CREATE TABLE user_playlists (
      user_id TEXT NOT NULL,
      id TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      track_ids_json TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, id)
  );

  CREATE TABLE user_hidden (
      user_id TEXT NOT NULL,
      item_type TEXT NOT NULL,
      item_id TEXT NOT NULL,
      hidden_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, item_type, item_id)
  );
''';

const String _userHiddenTable = '''
  CREATE TABLE IF NOT EXISTS user_hidden (
      user_id TEXT NOT NULL,
      item_type TEXT NOT NULL,
      item_id TEXT NOT NULL,
      hidden_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, item_type, item_id)
  );
''';

