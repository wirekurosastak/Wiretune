// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../util/time.dart';
import 'database_manager.dart';

/// The player's (and the server's) track index, playlists and settings in SQLite.
class LibraryRepository {
  LibraryRepository([DatabaseManager? dbManager]) : _dbManager = dbManager;

  DatabaseManager? _dbManager;

  /// Opened on first use, so a test double that overrides every method never creates a database.
  DatabaseManager get _db => _dbManager ??= DatabaseManager();

  Future<void> initialize() async => _db.initializeSchema();

  Future<List<Track>> getAllTracks() async {
    final rows = _db.connection.select('SELECT * FROM tracks');
    return [
      for (final r in rows)
        Track(
          id: r['id'] as String,
          title: r['title'] as String,
          artist: r['artist'] as String,
          album: r['album'] as String,
          albumArtist: r['album_artist'] as String?,
          trackNumber: _int(r['track_number']),
          trackCount: _int(r['track_count']),
          discNumber: _int(r['disc_number']),
          year: _int(r['year']),
          bpm: _int(r['bpm']),
          genre: r['genre'] as String?,
          duration: Duration(milliseconds: _int(r['duration_ms']) ?? 0),
          fileSizeBytes: _int(r['file_size_bytes']) ?? 0,
          fileModifiedUtc: fromDbTime(r['file_modified']),
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
          isFavorite: _int(r['is_favorite']) == 1,
          favoritedAt: fromDbTime(r['favorited_at']),
          playCount: _int(r['play_count']) ?? 0,
          lastPlayed: fromDbTime(r['last_played']),
          dateAdded: fromDbTime(r['date_added']),
        ),
    ];
  }

  static const String _upsertSql = '''
    INSERT INTO tracks (
        id, title, artist, album, album_artist, track_number, track_count, disc_number,
        year, bpm, genre, duration_ms, file_size_bytes, file_modified, file_path, stream_url,
        has_cover_art, cover_art_path, codec, sample_rate, bits_per_sample, channels,
        bitrate_kbps, is_lossless, is_favorite, play_count, last_played, date_added, favorited_at
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23,
              ?24, ?25, ?26, ?27, ?28, ?29)
    ON CONFLICT(id) DO UPDATE SET
        title = excluded.title, artist = excluded.artist, album = excluded.album,
        album_artist = excluded.album_artist, track_number = excluded.track_number,
        track_count = excluded.track_count, disc_number = excluded.disc_number, year = excluded.year,
        bpm = excluded.bpm, genre = excluded.genre, duration_ms = excluded.duration_ms,
        file_size_bytes = excluded.file_size_bytes, file_modified = excluded.file_modified,
        file_path = excluded.file_path, stream_url = excluded.stream_url, has_cover_art = excluded.has_cover_art,
        cover_art_path = excluded.cover_art_path, codec = excluded.codec, sample_rate = excluded.sample_rate,
        bits_per_sample = excluded.bits_per_sample, channels = excluded.channels,
        bitrate_kbps = excluded.bitrate_kbps, is_lossless = excluded.is_lossless,
        is_favorite = excluded.is_favorite, play_count = excluded.play_count,
        last_played = excluded.last_played, date_added = excluded.date_added, favorited_at = excluded.favorited_at
    WHERE title IS NOT excluded.title OR artist IS NOT excluded.artist OR album IS NOT excluded.album
       OR album_artist IS NOT excluded.album_artist OR track_number IS NOT excluded.track_number
       OR track_count IS NOT excluded.track_count OR disc_number IS NOT excluded.disc_number
       OR year IS NOT excluded.year OR bpm IS NOT excluded.bpm OR genre IS NOT excluded.genre
       OR duration_ms IS NOT excluded.duration_ms OR file_size_bytes IS NOT excluded.file_size_bytes
       OR file_modified IS NOT excluded.file_modified OR file_path IS NOT excluded.file_path
       OR stream_url IS NOT excluded.stream_url
       OR has_cover_art IS NOT excluded.has_cover_art OR cover_art_path IS NOT excluded.cover_art_path
       OR codec IS NOT excluded.codec OR sample_rate IS NOT excluded.sample_rate
       OR bits_per_sample IS NOT excluded.bits_per_sample OR channels IS NOT excluded.channels
       OR bitrate_kbps IS NOT excluded.bitrate_kbps OR is_lossless IS NOT excluded.is_lossless
       OR is_favorite IS NOT excluded.is_favorite OR play_count IS NOT excluded.play_count
       OR last_played IS NOT excluded.last_played OR date_added IS NOT excluded.date_added
       OR favorited_at IS NOT excluded.favorited_at
    ''';

  /// Makes the table hold exactly [tracks]. Rows that are gone are deleted and the others are inserted or updated in
  /// place, and a row whose values did not change is not written at all: a rescan or a refresh of an unchanged library
  /// leaves the database file as it is instead of rewriting every track.
  Future<void> replaceAllTracks(Iterable<Track> tracks) async {
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
          upsert.execute([
            t.id,
            t.title,
            t.artist,
            t.album,
            t.albumArtistInferred ? null : t.albumArtist, // only what the file's tag says
            t.trackNumber,
            t.trackCount,
            t.discNumber,
            t.year,
            t.bpm,
            t.genre,
            t.duration.inMilliseconds,
            t.fileSizeBytes,
            toDbTime(t.fileModifiedUtc),
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
            t.isFavorite ? 1 : 0,
            t.playCount,
            toDbTime(t.lastPlayed),
            toDbTime(t.dateAdded),
            toDbTime(t.favoritedAt),
          ]);
        }
      } finally {
        upsert.close();
      }
    });
  }

  /// Marks a track as a favourite since [favoritedAt], or (null) as none.
  Future<void> updateTrackFavorite(String trackId, DateTime? favoritedAt) async {
    _db.connection.execute('UPDATE tracks SET is_favorite = ?, favorited_at = ? WHERE id = ?', [
      favoritedAt == null ? 0 : 1,
      toDbTime(favoritedAt),
      trackId,
    ]);
  }

  Future<void> incrementPlayCount(String trackId) async {
    _db.connection.execute('UPDATE tracks SET play_count = play_count + 1, last_played = ? WHERE id = ?', [
      toDbTime(DateTime.now()),
      trackId,
    ]);
  }

  Future<void> updateTrackBpm(String trackId, int bpm) async {
    _db.connection.execute('UPDATE tracks SET bpm = ? WHERE id = ?', [
      bpm,
      trackId,
    ]);
  }

  Future<List<Playlist>> getAllPlaylists() async {
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

  Future<void> savePlaylist(Playlist playlist) async {
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

  Future<void> deletePlaylist(String playlistId) async {
    _db.connection.execute('DELETE FROM playlists WHERE id = ?', [playlistId]);
  }

  /// Removes the cached copies of server playlists (on sign-out); playlists made on this device stay.
  Future<void> deleteServerPlaylists() async {
    _db.connection.execute('DELETE FROM playlists WHERE is_server = 1');
  }

  Future<String?> getSetting(String key, [String? defaultValue]) async {
    final rows = _db.connection.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? defaultValue : rows.first['value'] as String? ?? defaultValue;
  }

  Future<void> setSetting(String key, String value) async {
    _db.connection.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [key, value]);
  }

  /// Returns the stored value, first storing the one [createValue] makes when there is none (or only an empty one). If
  /// two processes race on a new database, the value stored first wins and both return it.
  Future<String> getOrAddSetting(String key, String Function() createValue) async {
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

  static int? _int(Object? value) => value == null ? null : (value as num).toInt();
}
