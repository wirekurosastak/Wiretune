import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../services/app_paths.dart';

/// Opens the SQLite database and keeps its schema current. The player and the server create every table through this
/// class (each uses the ones it needs), so a database written by either is readable by both.
///
/// The connection is synchronous and shared: Dart runs one piece of code at a time per isolate, so a transaction made
/// of synchronous calls ([transaction]) can never interleave with another.
class DatabaseManager {
  DatabaseManager([String? customDbPath])
    : databasePath = AppPaths.fullPath(customDbPath ?? p.join(AppPaths.getDataDirectory(), 'wiretune.db')) {
    Directory(p.dirname(databasePath)).createSync(recursive: true);
  }

  /// The version written by this build; see [initializeSchema] for what each step added.
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

  /// Creates or migrates the schema. Safe to call repeatedly.
  void initializeSchema() {
    if (_schemaReady) return;

    final db = connection;
    db.execute('PRAGMA journal_mode = WAL;');
    final version = db.userVersion;

    transaction((db) {
      if (version < 1) {
        db.execute('''
          CREATE TABLE IF NOT EXISTS tracks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              album TEXT NOT NULL,
              album_artist TEXT,
              track_number INTEGER,
              track_count INTEGER,
              disc_number INTEGER,
              year INTEGER,
              genre TEXT,
              duration_seconds REAL NOT NULL,
              file_size_bytes INTEGER NOT NULL,
              file_path TEXT NOT NULL UNIQUE,
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
              last_played TEXT,
              date_added TEXT NOT NULL
          );

          CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
          CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
          CREATE INDEX IF NOT EXISTS idx_tracks_favorite ON tracks(is_favorite);

          CREATE TABLE IF NOT EXISTS playlists (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              description TEXT,
              track_ids_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY,
              username TEXT NOT NULL UNIQUE COLLATE NOCASE,
              password_hash TEXT NOT NULL,
              is_admin INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              last_login TEXT
          );
          ''');
      }

      if (version < 2 && !_columnExists(db, 'tracks', 'file_modified_utc')) {
        db.execute('ALTER TABLE tracks ADD COLUMN file_modified_utc TEXT;');
      }

      if (version < 3) {
        // Per-account data kept by the server (the player never writes these tables), and the flag that marks a
        // playlist in the player's database as a cached copy of a server playlist.
        if (!_columnExists(db, 'playlists', 'is_server')) {
          db.execute('ALTER TABLE playlists ADD COLUMN is_server INTEGER NOT NULL DEFAULT 0;');
        }

        db.execute('''
          CREATE TABLE IF NOT EXISTS user_favorites (
              user_id TEXT NOT NULL,
              track_id TEXT NOT NULL,
              added_at TEXT NOT NULL,
              PRIMARY KEY (user_id, track_id)
          );

          CREATE TABLE IF NOT EXISTS user_plays (
              user_id TEXT NOT NULL,
              track_id TEXT NOT NULL,
              play_count INTEGER NOT NULL DEFAULT 0,
              last_played TEXT,
              PRIMARY KEY (user_id, track_id)
          );

          -- Keyed by (user, id): two accounts may hand over the same local playlist without colliding.
          CREATE TABLE IF NOT EXISTS user_playlists (
              user_id TEXT NOT NULL,
              id TEXT NOT NULL,
              name TEXT NOT NULL,
              description TEXT,
              track_ids_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL,
              PRIMARY KEY (user_id, id)
          );
          ''');
      }

      if (version < 4) {
        // Album artists that the library inferred used to be stored as if the files' tags said so. Forget the
        // modification times of the tracks found on disk: the next scan reads their tags again instead of reusing the
        // stored values. Tracks downloaded from a server are replaced on every refresh anyway.
        db.execute('UPDATE tracks SET file_modified_utc = NULL WHERE stream_url IS NULL;');
      }

      db.userVersion = schemaVersion;
    });
    _schemaReady = true;
  }

  static bool _columnExists(Database db, String table, String column) {
    for (final row in db.select('PRAGMA table_info($table);')) {
      if ((row['name'] as String).toLowerCase() == column.toLowerCase()) return true;
    }
    return false;
  }

  /// Closes the connection; the next use opens it again.
  void close() {
    _db?.close();
    _db = null;
    _schemaReady = false;
  }
}
