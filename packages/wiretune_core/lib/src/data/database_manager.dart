// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../services/app_paths.dart';

/// The database file belongs to another version of Wiretune: reading it with this schema would misread it.
class IncompatibleDatabaseException implements Exception {
  const IncompatibleDatabaseException(this.message, [this.path]);

  final String message;

  /// The database file.
  final String? path;

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

  /// The schema this build creates and reads. A change to the tables raises it, together with a step in [_upgrades]
  /// that upgrades a database of the previous version in place.
  static const int schemaVersion = 8;

  /// The step from version `i + 1` to `i + 2` is `_upgrades[i]`; a database of any older version runs every step after
  /// its own, in one transaction.
  static const List<String> _upgrades = [
    // 1 -> 2: when each favourite was marked.
    'ALTER TABLE tracks ADD COLUMN favorited_at INTEGER;',
    // 2 -> 3: the tempo tag.
    'ALTER TABLE tracks ADD COLUMN bpm INTEGER;',
    // 3 -> 4: each account's hidden artists, albums and tracks.
    _userHiddenTable,
    // 4 -> 5: a password change ends the sessions that signed in with the old one; the player's record of its
    // downloaded copies.
    'ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0; $_downloadsTable',
    // 5 -> 6: every artist of a track (featured ones too). Forgetting the files' modification times makes the next scan
    // read each file again, as only then are the artists known.
    'ALTER TABLE tracks ADD COLUMN artists TEXT; UPDATE tracks SET file_modified = NULL;',
    // 6 -> 7: the names the interface uses: a track's release year, when it was added, and the times as "..._at"; the
    // music folder's settings.
    '''
    ALTER TABLE tracks RENAME COLUMN year TO release_year;
    ALTER TABLE tracks RENAME COLUMN date_added TO added_at;
    ALTER TABLE tracks RENAME COLUMN file_modified TO file_modified_at;
    ALTER TABLE tracks RENAME COLUMN last_played TO last_played_at;
    ALTER TABLE user_favorites RENAME COLUMN added_at TO favorited_at;
    ALTER TABLE user_plays RENAME COLUMN last_played TO last_played_at;
    ALTER TABLE users RENAME COLUMN last_login TO last_login_at;
    UPDATE settings SET key = 'music_folder' WHERE key = 'library_path';
    UPDATE settings SET key = 'chosen_music_folder' WHERE key = 'chosen_library_path';
    DELETE FROM settings WHERE key = 'library_source';
    ''',
    // 7 -> 8: every album artist of a track (an album of two acts). As for 5 -> 6, the next scan reads each file again.
    'ALTER TABLE tracks ADD COLUMN album_artists TEXT; UPDATE tracks SET file_modified_at = NULL;',
  ];

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

  /// Creates the tables of a new database, or upgrades one of an earlier schema version in place. Safe to call
  /// repeatedly. Throws [IncompatibleDatabaseException] for a database of a newer version, or tables of unknown origin.
  void initializeSchema() {
    if (_schemaReady) return;
    assert(_upgrades.length + 1 == schemaVersion, 'Every schema version needs its upgrade step.');

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
      } else if (version >= 1 && version < schemaVersion) {
        transaction((db) {
          for (final step in _upgrades.skip(version - 1)) {
            db.execute(step);
          }
          db.userVersion = schemaVersion;
        });
      } else {
        throw IncompatibleDatabaseException(
          "'$databasePath' was made by another version of Wiretune (schema $version, this one reads $schemaVersion). "
          'Move it out of the way to start with an empty one.',
          databasePath,
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

const String _schema =
    '''
  -- The library index. A server keeps its own files here; a player keeps its local files and a cache of its server's
  -- tracks (no file path, a stream URL), with the favourite flag and play statistics it shows for each.
  CREATE TABLE tracks (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      artist TEXT NOT NULL,
      artists TEXT,
      album TEXT NOT NULL,
      album_artist TEXT,
      album_artists TEXT,
      track_number INTEGER,
      track_count INTEGER,
      disc_number INTEGER,
      release_year INTEGER,
      bpm INTEGER,
      genre TEXT,
      duration_ms INTEGER NOT NULL,
      file_size_bytes INTEGER NOT NULL,
      file_modified_at INTEGER,
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
      last_played_at INTEGER,
      added_at INTEGER NOT NULL,
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
      last_login_at INTEGER,
      -- Raised by a password change; a token signed for an older value is refused.
      token_version INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE user_favorites (
      user_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      favorited_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, track_id)
  );

  CREATE TABLE user_plays (
      user_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      play_count INTEGER NOT NULL DEFAULT 0,
      last_played_at INTEGER,
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

  $_downloadsTable
''';

/// The player's downloaded copies of server tracks: which file (relative to the downloads folder) is the copy of which
/// track, and of which version of the server's file ('' while it is being moved into place).
const String _downloadsTable = '''
  CREATE TABLE downloads (
      track_id TEXT PRIMARY KEY,
      version TEXT NOT NULL,
      path TEXT NOT NULL
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
