// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../util/time.dart';
import 'database_manager.dart';

/// The player's (and the server's) track index, playlists and settings in SQLite. SQLite answers at once, so every
/// method does its work before it returns.
class LibraryRepository {
  LibraryRepository([DatabaseManager? database]) : _db = database ?? DatabaseManager();

  final DatabaseManager _db;

  void initialize() => _db.initializeSchema();

  List<Track> getAllTracks() {
    final rows = _db.connection.select('SELECT * FROM tracks');
    return [
      for (final r in rows)
        Track(
          id: r['id'] as String,
          title: r['title'] as String,
          artist: r['artist'] as String,
          artists: _names(r['artists']),
          album: r['album'] as String,
          albumArtist: r['album_artist'] as String?,
          trackNumber: _int(r['track_number']),
          trackCount: _int(r['track_count']),
          discNumber: _int(r['disc_number']),
          releaseYear: _int(r['release_year']),
          bpm: _int(r['bpm']),
          genre: r['genre'] as String?,
          duration: Duration(milliseconds: _int(r['duration_ms']) ?? 0),
          fileSizeBytes: _int(r['file_size_bytes']) ?? 0,
          fileModifiedAt: fromDbTime(r['file_modified_at']),
          filePath: r['file_path'] as String,
          streamUrl: r['stream_url'] as String?,
          hasCoverArt: _int(r['has_cover_art']) == 1,
          coverArtPath: r['cover_art_path'] as String?,
          format: AudioFormat(
            codec: r['codec'] as String,
            sampleRate: _int(r['sample_rate']) ?? 44100,
            bitsPerSample: _int(r['bits_per_sample']) ?? 16,
            channels: _int(r['channels']) ?? 2,
            bitrateKbps: _int(r['bitrate_kbps']) ?? 0,
            isLossless: _int(r['is_lossless']) == 1,
          ),
          addedAt: fromDbTime(r['added_at']),
        ),
    ];
  }

  /// The favourites (track ID -> when marked, null when that is unknown) and the play statistics kept with the tracks.
  ({Map<String, DateTime?> favorites, Map<String, PlayStats> plays}) getUserData() {
    final favorites = <String, DateTime?>{};
    final plays = <String, PlayStats>{};
    final rows = _db.connection.select(
      'SELECT id, is_favorite, favorited_at, play_count, last_played_at FROM tracks '
      'WHERE is_favorite = 1 OR play_count > 0 OR last_played_at IS NOT NULL',
    );
    for (final r in rows) {
      final id = r['id'] as String;
      if (_int(r['is_favorite']) == 1) favorites[id] = fromDbTime(r['favorited_at']);
      final count = _int(r['play_count']) ?? 0;
      final last = fromDbTime(r['last_played_at']);
      if (count > 0 || last != null) plays[id] = (count: count, lastPlayedAt: last);
    }
    return (favorites: favorites, plays: plays);
  }

  /// Stores the favourite and the play statistics of each of [trackIds] as [favorites] and [plays] have them; rows that
  /// already say so are not written.
  void saveUserData(Iterable<String> trackIds, Map<String, DateTime?> favorites, Map<String, PlayStats> plays) {
    _db.transaction((db) {
      final update = db.prepare(
        'UPDATE tracks SET is_favorite = ?1, favorited_at = ?2, play_count = ?3, last_played_at = ?4 WHERE id = ?5 '
        'AND (is_favorite IS NOT ?1 OR favorited_at IS NOT ?2 OR play_count IS NOT ?3 OR last_played_at IS NOT ?4)',
      );
      try {
        for (final id in trackIds) {
          final stats = plays[id];
          update.execute([
            favorites.containsKey(id) ? 1 : 0,
            toDbTime(favorites[id]),
            stats?.count ?? 0,
            toDbTime(stats?.lastPlayedAt),
            id,
          ]);
        }
      } finally {
        update.close();
      }
    });
  }

  // The favourite and the play statistics of a row are not part of this: [saveUserData] keeps them.
  static const String _upsertSql = '''
    INSERT INTO tracks (
        id, title, artist, album, album_artist, track_number, track_count, disc_number,
        release_year, bpm, genre, duration_ms, file_size_bytes, file_modified_at, file_path, stream_url,
        has_cover_art, cover_art_path, codec, sample_rate, bits_per_sample, channels,
        bitrate_kbps, is_lossless, added_at, artists
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23,
              ?24, ?25, ?26)
    ON CONFLICT(id) DO UPDATE SET
        title = excluded.title, artist = excluded.artist, artists = excluded.artists, album = excluded.album,
        album_artist = excluded.album_artist, track_number = excluded.track_number,
        track_count = excluded.track_count, disc_number = excluded.disc_number, release_year = excluded.release_year,
        bpm = excluded.bpm, genre = excluded.genre, duration_ms = excluded.duration_ms,
        file_size_bytes = excluded.file_size_bytes, file_modified_at = excluded.file_modified_at,
        file_path = excluded.file_path, stream_url = excluded.stream_url, has_cover_art = excluded.has_cover_art,
        cover_art_path = excluded.cover_art_path, codec = excluded.codec, sample_rate = excluded.sample_rate,
        bits_per_sample = excluded.bits_per_sample, channels = excluded.channels,
        bitrate_kbps = excluded.bitrate_kbps, is_lossless = excluded.is_lossless, added_at = excluded.added_at
    WHERE title IS NOT excluded.title OR artist IS NOT excluded.artist OR artists IS NOT excluded.artists
       OR album IS NOT excluded.album
       OR album_artist IS NOT excluded.album_artist OR track_number IS NOT excluded.track_number
       OR track_count IS NOT excluded.track_count OR disc_number IS NOT excluded.disc_number
       OR release_year IS NOT excluded.release_year OR bpm IS NOT excluded.bpm OR genre IS NOT excluded.genre
       OR duration_ms IS NOT excluded.duration_ms OR file_size_bytes IS NOT excluded.file_size_bytes
       OR file_modified_at IS NOT excluded.file_modified_at OR file_path IS NOT excluded.file_path
       OR stream_url IS NOT excluded.stream_url
       OR has_cover_art IS NOT excluded.has_cover_art OR cover_art_path IS NOT excluded.cover_art_path
       OR codec IS NOT excluded.codec OR sample_rate IS NOT excluded.sample_rate
       OR bits_per_sample IS NOT excluded.bits_per_sample OR channels IS NOT excluded.channels
       OR bitrate_kbps IS NOT excluded.bitrate_kbps OR is_lossless IS NOT excluded.is_lossless
       OR added_at IS NOT excluded.added_at
    ''';

  /// Makes the table hold exactly [tracks]. Rows that are gone are deleted and the others are inserted or updated in
  /// place, and a row whose values did not change is not written at all: a rescan or a refresh of an unchanged library
  /// leaves the database file as it is instead of rewriting every track.
  void replaceAllTracks(Iterable<Track> tracks) {
    final wanted = {for (final t in tracks) t.id: t}; // of two tracks with one ID, the last one wins

    _db.transaction((db) {
      final obsolete = [
        for (final row in db.select('SELECT id FROM tracks'))
          if (!wanted.containsKey(row['id'])) row['id'] as String,
      ];
      if (obsolete.isNotEmpty) {
        final delete = db.prepare('DELETE FROM tracks WHERE id = ?');
        try {
          for (final id in obsolete) {
            delete.execute([id]);
          }
        } finally {
          delete.close();
        }
      }

      final upsert = db.prepare(_upsertSql);
      try {
        for (final t in wanted.values) {
          // What the file's tags say, not where the library filed the track.
          upsert.execute([
            t.id,
            t.title,
            t.artist,
            t.tagged.album,
            t.tagged.albumArtist,
            t.tagged.trackNumber,
            t.trackCount,
            t.tagged.discNumber,
            t.releaseYear,
            t.bpm,
            t.genre,
            t.duration.inMilliseconds,
            t.fileSizeBytes,
            toDbTime(t.fileModifiedAt),
            t.filePath,
            t.streamUrl,
            t.hasCoverArt ? 1 : 0,
            t.coverArtPath,
            t.format.codec,
            t.format.sampleRate,
            t.format.bitsPerSample,
            t.format.channels,
            t.format.bitrateKbps,
            t.format.isLossless ? 1 : 0,
            toDbTime(t.addedAt),
            t.artists.isEmpty ? null : jsonEncode(t.artists),
          ]);
        }
      } finally {
        upsert.close();
      }
    });
  }

  List<Playlist> getAllPlaylists() {
    final rows = _db.connection.select('SELECT * FROM playlists ORDER BY name');
    return [
      for (final r in rows)
        Playlist(
          id: r['id'] as String,
          name: r['name'] as String,
          description: r['description'] as String?,
          createdAt: fromDbTime(r['created_at']),
          modifiedAt: fromDbTime(r['modified_at']),
          isServer: _int(r['is_server']) == 1,
          trackIds: decodeTrackIds(r['track_ids_json']),
        ),
    ];
  }

  void savePlaylist(Playlist playlist) {
    _db.connection.execute(
      'INSERT OR REPLACE INTO playlists (id, name, description, track_ids_json, created_at, modified_at, is_server) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        playlist.id,
        playlist.name,
        playlist.description,
        jsonEncode(playlist.trackIds),
        toDbTime(playlist.createdAt),
        toDbTime(playlist.modifiedAt),
        playlist.isServer ? 1 : 0,
      ],
    );
  }

  void deletePlaylist(String playlistId) {
    _db.connection.execute('DELETE FROM playlists WHERE id = ?', [playlistId]);
  }

  /// Removes the cached copies of server playlists (on sign-out); playlists made on this device stay.
  void deleteServerPlaylists() {
    _db.connection.execute('DELETE FROM playlists WHERE is_server = 1');
  }

  String? getSetting(String key, [String? defaultValue]) {
    final rows = _db.connection.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? defaultValue : rows.first['value'] as String? ?? defaultValue;
  }

  void setSetting(String key, String value) {
    _db.connection.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [key, value]);
  }

  /// Returns the stored value, first storing the one [createValue] makes when there is none (or only an empty one). If
  /// two processes race on a new database, the value stored first wins and both return it.
  String getOrAddSetting(String key, String Function() createValue) {
    final db = _db.connection;
    final existing = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    if (existing.isNotEmpty && (existing.first['value'] as String? ?? '').isNotEmpty) {
      return existing.first['value'] as String;
    }
    db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      "ON CONFLICT (key) DO UPDATE SET value = excluded.value WHERE settings.value = ''",
      [key, createValue()],
    );
    return db.select('SELECT value FROM settings WHERE key = ?', [key]).first['value'] as String;
  }

  Map<String, Set<String>> getHiddenItems([String userId = 'local']) {
    final rows = _db.connection.select('SELECT item_type, item_id FROM user_hidden WHERE user_id = ?', [userId]);
    final result = <String, Set<String>>{'artist': <String>{}, 'album': <String>{}, 'track': <String>{}};
    for (final r in rows) {
      final type = r['item_type'] as String;
      final id = r['item_id'] as String;
      result.putIfAbsent(type, () => <String>{}).add(id);
    }
    return result;
  }

  void setHiddenItem(String itemType, String itemId, bool hidden, [String userId = 'local']) {
    if (hidden) {
      _db.connection.execute(
        'INSERT OR REPLACE INTO user_hidden (user_id, item_type, item_id, hidden_at) VALUES (?, ?, ?, ?)',
        [userId, itemType, itemId, toDbTime(DateTime.now().toUtc())],
      );
    } else {
      _db.connection.execute('DELETE FROM user_hidden WHERE user_id = ? AND item_type = ? AND item_id = ?', [
        userId,
        itemType,
        itemId,
      ]);
    }
  }

  /// Makes the hidden items of [userId] exactly these, in one transaction.
  void replaceHiddenItems(
    String userId, {
    required Iterable<String> artists,
    required Iterable<String> albums,
    required Iterable<String> tracks,
  }) {
    final now = toDbTime(DateTime.now().toUtc());
    _db.transaction((db) {
      db.execute('DELETE FROM user_hidden WHERE user_id = ?', [userId]);
      final insert = db.prepare(
        'INSERT OR IGNORE INTO user_hidden (user_id, item_type, item_id, hidden_at) VALUES (?, ?, ?, ?)',
      );
      try {
        for (final (type, ids) in [('artist', artists), ('album', albums), ('track', tracks)]) {
          for (final id in ids) {
            insert.execute([userId, type, id, now]);
          }
        }
      } finally {
        insert.close();
      }
    });
  }

  void clearHiddenItems([String userId = 'local']) {
    _db.connection.execute('DELETE FROM user_hidden WHERE user_id = ?', [userId]);
  }

  /// The downloaded copies: track ID -> the version of the server's file and the path relative to the downloads folder.
  Map<String, (String version, String path)> getDownloads() => {
    for (final r in _db.connection.select('SELECT track_id, version, path FROM downloads'))
      r['track_id'] as String: (r['version'] as String, r['path'] as String),
  };

  void saveDownload(String trackId, String version, String path) => _db.connection.execute(
    'INSERT OR REPLACE INTO downloads (track_id, version, path) VALUES (?, ?, ?)',
    [trackId, version, path],
  );

  void deleteDownload(String trackId) => _db.connection.execute('DELETE FROM downloads WHERE track_id = ?', [trackId]);

  static int? _int(Object? value) => value == null ? null : (value as num).toInt();

  static List<String>? _names(Object? value) {
    if (value is! String) return null;
    try {
      final names = jsonDecode(value);
      return names is List ? names.whereType<String>().toList() : null;
    } on FormatException {
      return null; // not written by Wiretune: the artist column alone
    }
  }
}
