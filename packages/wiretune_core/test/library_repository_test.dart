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

  test('tracks are keyed by ID: a new path updates the row, and server tracks need no path', () async {
    final (repo, _) = await open();
    await repo.replaceAllTracks([make('a', path: '/music/old.flac')]);
    await repo.replaceAllTracks([make('a', path: '/music/new.flac'), make('s1', path: ''), make('s2', path: '')]);
    final stored = {for (final t in await repo.getAllTracks()) t.id: t};
    expect(stored['a']!.filePath, '/music/new.flac');
    expect(stored.keys, containsAll(['s1', 's2']));
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

    await repo.setSetting('blank', ''); // an empty value is no value: a signing key must never be empty
    expect(await repo.getOrAddSetting('blank', () => 'filled'), 'filled');
  });

  test('a database of another schema version is refused instead of misread', () async {
    final (_, db) = await open();
    db.connection.execute('PRAGMA user_version = 99');
    db.close();
    final other = DatabaseManager(dbPath());
    opened.add(other);
    expect(
      other.initializeSchema,
      throwsA(isA<IncompatibleDatabaseException>().having((e) => e.message, 'message', contains('schema 99'))),
    );
    expect(count(other, 'PRAGMA user_version'), 99); // left as it was

    // Tables without a version are somebody else's: refused as well.
    final foreign = DatabaseManager(p.join(dir.path, 'foreign.db'));
    opened.add(foreign);
    foreign.connection.execute('CREATE TABLE tracks (id TEXT)');
    expect(foreign.initializeSchema, throwsA(isA<IncompatibleDatabaseException>()));
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
}
