import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The repository against a real SQLite file (the other tests use a stand-in that never runs the SQL).
void main() {
  late Directory dir;
  late List<DatabaseManager> opened;

  setUpAll(useTempDataDirectory);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('wiretune_repo_');
    opened = [];
  });
  tearDown(() {
    for (final db in opened) {
      db.close();
    }
    dir.deleteSync(recursive: true);
  });

  String dbPath() => p.join(dir.path, 'wiretune.db');

  Future<(LibraryRepository, DatabaseManager)> open() async {
    final db = DatabaseManager(dbPath());
    opened.add(db);
    final repo = LibraryRepository(db);
    await repo.initialize();
    return (repo, db);
  }

  Track make(String id, {String title = 'Song', String? path}) => Track(
    id: id,
    title: title,
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(milliseconds: 200500),
    filePath: path ?? '/music/$id.flac',
    format: const AudioFormat(codec: 'FLAC', sampleRate: 44100, bitsPerSample: 16, channels: 2, isLossless: true),
    dateAdded: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );

  int count(DatabaseManager db, String sql) => db.connection.select(sql).first.values.first as int;

  test('tracks round-trip with their user data', () async {
    final (repo, _) = await open();
    final track = make('a')
      ..isFavorite = true
      ..playCount = 3
      ..lastPlayed = DateTime.utc(2026, 5, 6, 7, 8, 9)
      ..genre = 'Jazz'
      ..trackNumber = 4
      ..fileModifiedUtc = DateTime.utc(2025, 1, 2, 3, 4, 5, 678, 901);

    await repo.replaceAllTracks([track]);
    final stored = (await repo.getAllTracks()).single;

    expect(stored.id, 'a');
    expect(stored.duration, const Duration(milliseconds: 200500));
    expect(stored.genre, 'Jazz');
    expect(stored.trackNumber, 4);
    expect(stored.isFavorite, isTrue);
    expect(stored.playCount, 3);
    expect(stored.lastPlayed, track.lastPlayed);
    expect(stored.fileModifiedUtc, track.fileModifiedUtc); // microseconds survive, so an unchanged file is reused
    expect(stored.dateAdded, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(stored.format.codec, 'FLAC');
  });

  test('replacing the tracks deletes what is gone and updates what changed', () async {
    final (repo, _) = await open();
    await repo.replaceAllTracks([make('a'), make('b'), make('c')]);
    await repo.replaceAllTracks([make('a'), make('b', title: 'Renamed'), make('d')]);

    final stored = {for (final t in await repo.getAllTracks()) t.id: t};
    expect(stored.keys.toList()..sort(), ['a', 'b', 'd']);
    expect(stored['b']!.title, 'Renamed');
  });

  test('replacing the tracks with the same library writes nothing', () async {
    final (repo, db) = await open();
    await repo.replaceAllTracks([make('a'), make('b')]);

    // A trigger records every update the table sees.
    db.connection.execute('CREATE TABLE audit (id TEXT NOT NULL)');
    db.connection.execute(
      'CREATE TRIGGER tracks_audit AFTER UPDATE ON tracks BEGIN INSERT INTO audit VALUES (NEW.id); END',
    );

    await repo.replaceAllTracks([make('a'), make('b')]);
    expect(count(db, 'SELECT COUNT(*) FROM audit'), 0);

    await repo.replaceAllTracks([make('a'), make('b', title: 'Changed')]);
    expect(count(db, "SELECT COUNT(*) FROM audit WHERE id = 'b'"), 1);
    expect(count(db, 'SELECT COUNT(*) FROM audit'), 1);
  });

  test('a track whose path changed is stored again, and of two tracks with one path the last wins', () async {
    final (repo, _) = await open();
    await repo.replaceAllTracks([make('a', path: '/music/old.flac'), make('b', path: '/music/other.flac')]);
    await repo.replaceAllTracks([make('a', path: '/music/other.flac'), make('b', path: '/music/new.flac')]);
    final stored = {for (final t in await repo.getAllTracks()) t.id: t};
    expect(stored['a']!.filePath, '/music/other.flac');
    expect(stored['b']!.filePath, '/music/new.flac');

    await repo.replaceAllTracks([make('x', path: '/music/same.flac'), make('y', path: '/music/same.flac')]);
    expect((await repo.getAllTracks()).single.id, 'y');
  });

  test('only what the tags say is stored as the album artist', () async {
    final (repo, _) = await open();
    final tagged = make('a')..albumArtist = 'The Band';
    final inferred = make('b')
      ..albumArtist = 'Various Artists'
      ..albumArtistInferred = true;
    await repo.replaceAllTracks([tagged, inferred]);

    final stored = {for (final t in await repo.getAllTracks()) t.id: t};
    expect(stored['a']!.albumArtist, 'The Band');
    expect(stored['b']!.albumArtist, isNull);
  });

  test('user data of several tracks is written in one call', () async {
    final (repo, _) = await open();
    await repo.replaceAllTracks([make('a'), make('b')]);
    final played = DateTime.utc(2026, 3, 4, 5, 6, 7);
    await repo.updateTracksUserData([
      Track(id: 'a', isFavorite: true, playCount: 7, lastPlayed: played),
      Track(id: 'missing', isFavorite: true, playCount: 1),
    ]);

    final stored = {for (final t in await repo.getAllTracks()) t.id: t};
    expect(stored['a']!.isFavorite, isTrue);
    expect(stored['a']!.playCount, 7);
    expect(stored['a']!.lastPlayed, played);
    expect(stored['b']!.isFavorite, isFalse);
  });

  test('server playlists are marked, and only they are removed on sign-out', () async {
    final (repo, _) = await open();
    await repo.savePlaylist(Playlist(id: 'mine', name: 'Mine', trackIds: ['a']));
    await repo.savePlaylist(Playlist(id: 'theirs', name: 'Theirs', isServer: true, trackIds: ['b', 'c']));

    final stored = {for (final pl in await repo.getAllPlaylists()) pl.id: pl};
    expect(stored['mine']!.isServer, isFalse);
    expect(stored['theirs']!.isServer, isTrue);
    expect(stored['theirs']!.trackIds, ['b', 'c']);

    await repo.deleteServerPlaylists();
    expect((await repo.getAllPlaylists()).single.id, 'mine');
  });

  test('getOrAddSetting creates the value once and keeps it', () async {
    final (repo, _) = await open();
    var calls = 0;
    final first = await repo.getOrAddSetting('secret', () => 'value-${++calls}');
    final second = await repo.getOrAddSetting('secret', () => 'value-${++calls}');
    expect(first, 'value-1');
    expect(second, first);
    expect(calls, 1);
    expect(await repo.getSetting('secret'), first);
  });

  test('a database of an older version is upgraded in place and keeps its content', () async {
    final (repo, db) = await open();
    final local = make('local', path: '/music/local.flac')..fileModifiedUtc = DateTime.utc(2025);
    final remote = make('remote', path: 'server:remote')
      ..streamUrl = 'http://server/api/stream/remote'
      ..fileModifiedUtc = DateTime.utc(2025);
    await repo.replaceAllTracks([local, remote]);
    await repo.savePlaylist(Playlist(id: 'p', name: 'Kept', trackIds: ['local']));

    // Turn it back into what version 2 left: no per-account tables and no is_server column.
    for (final sql in [
      'DROP TABLE user_favorites',
      'DROP TABLE user_plays',
      'DROP TABLE user_playlists',
      'ALTER TABLE playlists DROP COLUMN is_server',
      'PRAGMA user_version = 2',
    ]) {
      db.connection.execute(sql);
    }
    db.close();

    final upgraded = DatabaseManager(dbPath());
    opened.add(upgraded);
    upgraded.initializeSchema();

    expect(count(upgraded, 'PRAGMA user_version'), 4);
    expect(count(upgraded, 'SELECT COUNT(*) FROM user_favorites'), 0);
    expect(count(upgraded, 'SELECT COUNT(*) FROM user_plays'), 0);
    expect(count(upgraded, 'SELECT COUNT(*) FROM user_playlists'), 0);
    // The tags of local files are read again by the next scan; tracks of a server are replaced on refresh.
    expect(count(upgraded, "SELECT COUNT(*) FROM tracks WHERE file_modified_utc IS NULL AND id = 'local'"), 1);
    expect(count(upgraded, "SELECT COUNT(*) FROM tracks WHERE file_modified_utc IS NOT NULL AND id = 'remote'"), 1);

    final reopened = LibraryRepository(upgraded);
    expect(await reopened.getAllTracks(), hasLength(2));
    final playlist = (await reopened.getAllPlaylists()).single;
    expect(playlist.name, 'Kept');
    expect(playlist.isServer, isFalse);
  });

  test('initializing the schema twice changes nothing', () async {
    final (repo, db) = await open();
    await repo.replaceAllTracks([make('a')]);
    final second = DatabaseManager(dbPath());
    opened.add(second);
    second.initializeSchema();
    db.initializeSchema();
    expect(await repo.getAllTracks(), hasLength(1));
  });

  test('dates written by the C# version (seven fractional digits) are read', () async {
    final (repo, db) = await open();
    await repo.replaceAllTracks([make('a')]);
    db.connection.execute(
      "UPDATE tracks SET last_played = '2024-02-03T04:05:06.1234567Z', "
      "date_added = '2024-01-01T00:00:00.0000000Z', duration_seconds = 225.1234567",
    );
    final stored = (await repo.getAllTracks()).single;
    expect(stored.lastPlayed, DateTime.utc(2024, 2, 3, 4, 5, 6, 123, 456));
    expect(stored.dateAdded, DateTime.utc(2024));
    expect(stored.duration, const Duration(microseconds: 225123457));
  });
}
