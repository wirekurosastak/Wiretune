// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The repository against a real SQLite file: what it stores, and the upgrades of older databases.
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

  /// Takes a database of the current schema back to what an older Wiretune of schema [version] left behind.
  void downgrade(DatabaseManager db, int version) {
    final c = db.connection;
    if (version < 6) c.execute('ALTER TABLE tracks DROP COLUMN artists');
    if (version < 5) c.execute('ALTER TABLE users DROP COLUMN token_version; DROP TABLE downloads;');
    if (version < 4) c.execute('DROP TABLE user_hidden');
    if (version < 3) c.execute('ALTER TABLE tracks DROP COLUMN bpm');
    if (version < 2) c.execute('ALTER TABLE tracks DROP COLUMN favorited_at');
    c.execute('PRAGMA user_version = $version');
    db.close();
  }

  Future<(LibraryRepository, DatabaseManager)> open() async {
    final db = DatabaseManager(dbPath());
    opened.add(db);
    final repo = LibraryRepository(db);
    repo.initialize();
    return (repo, db);
  }

  Track make(
    String id, {
    String title = 'Song',
    String? path,
    String album = 'Album',
    String? albumArtist,
    int? number,
  }) => Track(
    id: id,
    title: title,
    artist: 'Artist',
    album: album,
    albumArtist: albumArtist,
    trackNumber: number,
    duration: const Duration(milliseconds: 200500),
    filePath: path ?? '/music/$id.flac',
    format: const AudioFormat(codec: 'FLAC', sampleRate: 44100, bitsPerSample: 16, channels: 2, isLossless: true),
    dateAdded: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );

  int count(DatabaseManager db, String sql) => db.connection.select(sql).first.values.first as int;

  test('tracks round-trip, and their favourites and play statistics are kept beside them', () async {
    final (repo, _) = await open();
    final track = make('a', number: 4)
      ..genre = 'Jazz'
      ..fileModifiedUtc = DateTime.utc(2025, 1, 2, 3, 4, 5, 678, 901);
    final played = DateTime.utc(2026, 5, 6, 7, 8, 9);

    repo.replaceAllTracks([track, make('b')]);
    repo.saveUserData(['a', 'b'], {'a': null}, {'a': (count: 3, lastPlayedAt: played)});
    final stored = repo.getAllTracks().firstWhere((t) => t.id == 'a');

    expect(stored.duration, const Duration(milliseconds: 200500));
    expect(stored.genre, 'Jazz');
    expect(stored.trackNumber, 4);
    expect(stored.fileModifiedUtc, track.fileModifiedUtc); // microseconds survive, so an unchanged file is reused
    expect(stored.dateAdded, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(stored.format.codec, 'FLAC');
    final data = repo.getUserData();
    expect(data.favorites, {'a': null});
    expect(data.plays, {'a': (count: 3, lastPlayedAt: played)});

    // Writing the tracks again leaves what was said about them alone.
    repo.replaceAllTracks([make('a', title: 'Retagged'), make('b')]);
    expect(repo.getUserData().plays['a']!.count, 3);
  });

  test("a track's artists round-trip, and where the library filed a track is not stored, only its tags", () async {
    final (repo, _) = await open();
    final featuring = Track(id: 'f', title: 'Song', artist: 'Future, Lil Durk', artists: ['Future', 'Lil Durk']);
    final refiled = Track(id: 'r', title: 'Song', album: 'Back In Black', trackNumber: 6, discNumber: 1)
      ..filed = (album: 'ACDC Essentials', albumArtist: 'AC/DC', trackNumber: 3, discNumber: null);
    final inferred = make('i')
      ..filed = (album: 'Album', albumArtist: 'Various Artists', trackNumber: null, discNumber: null);

    repo.replaceAllTracks([featuring, refiled, inferred, make('a', albumArtist: 'The Band')]);
    final stored = {for (final t in repo.getAllTracks()) t.id: t};

    expect(stored['f']!.artist, 'Future, Lil Durk');
    expect(stored['f']!.artists, ['Future', 'Lil Durk']);
    expect(stored['a']!.artists, isEmpty);
    expect(stored['a']!.albumArtist, 'The Band');
    expect(stored['i']!.albumArtist, isNull);
    final r = stored['r']!;
    expect((r.album, r.albumArtist, r.trackNumber, r.discNumber, r.filed), ('Back In Black', null, 6, 1, null));
  });

  test('replacing the tracks deletes what is gone and updates what changed', () async {
    final (repo, _) = await open();
    repo.replaceAllTracks([make('a'), make('b'), make('c')]);
    repo.replaceAllTracks([make('a'), make('b', title: 'Renamed'), make('d')]);

    final stored = {for (final t in repo.getAllTracks()) t.id: t};
    expect(stored.keys.toList()..sort(), ['a', 'b', 'd']);
    expect(stored['b']!.title, 'Renamed');
  });

  test('replacing the tracks with the same library writes nothing', () async {
    final (repo, db) = await open();
    repo.replaceAllTracks([make('a'), make('b')]);

    // A trigger records every update the table sees.
    db.connection.execute('CREATE TABLE audit (id TEXT NOT NULL)');
    db.connection.execute(
      'CREATE TRIGGER tracks_audit AFTER UPDATE ON tracks BEGIN INSERT INTO audit VALUES (NEW.id); END',
    );

    repo.replaceAllTracks([make('a'), make('b')]);
    expect(count(db, 'SELECT COUNT(*) FROM audit'), 0);

    repo.replaceAllTracks([make('a'), make('b', title: 'Changed')]);
    expect(count(db, "SELECT COUNT(*) FROM audit WHERE id = 'b'"), 1);
    expect(count(db, 'SELECT COUNT(*) FROM audit'), 1);
  });

  test('tracks are keyed by ID: a new path updates the row, and server tracks need no path', () async {
    final (repo, _) = await open();
    repo.replaceAllTracks([make('a', path: '/music/old.flac')]);
    repo.replaceAllTracks([make('a', path: '/music/new.flac'), make('s1', path: ''), make('s2', path: '')]);
    final stored = {for (final t in repo.getAllTracks()) t.id: t};
    expect(stored['a']!.filePath, '/music/new.flac');
    expect(stored.keys, containsAll(['s1', 's2']));
  });

  test('server playlists are marked, and only they are removed on sign-out', () async {
    final (repo, _) = await open();
    repo.savePlaylist(Playlist(id: 'mine', name: 'Mine', trackIds: ['a']));
    repo.savePlaylist(Playlist(id: 'theirs', name: 'Theirs', isServer: true, trackIds: ['b', 'c']));

    final stored = {for (final pl in repo.getAllPlaylists()) pl.id: pl};
    expect(stored['mine']!.isServer, isFalse);
    expect(stored['theirs']!.isServer, isTrue);
    expect(stored['theirs']!.trackIds, ['b', 'c']);

    repo.deleteServerPlaylists();
    expect((repo.getAllPlaylists()).single.id, 'mine');
  });

  test('getOrAddSetting creates the value once and keeps it', () async {
    final (repo, _) = await open();
    var calls = 0;
    final first = repo.getOrAddSetting('secret', () => 'value-${++calls}');
    final second = repo.getOrAddSetting('secret', () => 'value-${++calls}');
    expect(first, 'value-1');
    expect(second, first);
    expect(calls, 1);
    expect(repo.getSetting('secret'), first);

    repo.setSetting('blank', ''); // an empty value is no value: a signing key must never be empty
    expect(repo.getOrAddSetting('blank', () => 'filled'), 'filled');
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

  test('a database of the previous schema is upgraded in place, and favourites get their time from then on', () async {
    final (repo, db) = await open();
    repo
      ..replaceAllTracks([make('a')])
      ..saveUserData(['a'], {'a': null}, const {});
    downgrade(db, 1); // no time for a favourite, no bpm, no hidden items, no token versions

    final (upgraded, again) = await open();
    expect(count(again, 'PRAGMA user_version'), DatabaseManager.schemaVersion);
    expect(upgraded.getAllTracks().single.id, 'a');
    expect(upgraded.getUserData().favorites, {'a': null});

    final when = DateTime.utc(2026, 3, 4, 5, 6, 7);
    upgraded.saveUserData(['a'], {'a': when}, const {});
    expect(upgraded.getUserData().favorites, {'a': when});
    upgraded.saveUserData(['a'], const {}, const {});
    expect(upgraded.getUserData().favorites, isEmpty);
  });

  test('a database of schema 2 is upgraded, gaining bpm', () async {
    final (repo, db) = await open();
    repo.replaceAllTracks([make('a')]);
    downgrade(db, 2);

    final (upgraded, again) = await open();
    expect(count(again, 'PRAGMA user_version'), DatabaseManager.schemaVersion);
    final kept = (upgraded.getAllTracks()).single;
    expect((kept.id, kept.bpm), ('a', null));
  });

  test('a database of schema 3 is upgraded, gaining the hidden items', () async {
    final (repo, db) = await open();
    repo.replaceAllTracks([make('a')]);
    downgrade(db, 3);

    final (upgraded, again) = await open();
    expect(count(again, 'PRAGMA user_version'), DatabaseManager.schemaVersion);
    final hidden = upgraded.getHiddenItems('user1');
    expect(hidden['track'], isEmpty);
    expect(hidden['album'], isEmpty);
    expect(hidden['artist'], isEmpty);
  });

  test('a database of schema 5 is upgraded, and its files are read again for their artists', () async {
    final (repo, db) = await open();
    repo.replaceAllTracks([make('a')..fileModifiedUtc = DateTime.utc(2025, 1, 2)]);
    downgrade(db, 5);

    final (upgraded, again) = await open();
    expect(count(again, 'PRAGMA user_version'), DatabaseManager.schemaVersion);
    final kept = (upgraded.getAllTracks()).single;
    expect((kept.id, kept.fileModifiedUtc), ('a', null));
    expect(kept.artists, isEmpty);
  });

  test("a database of schema 4 is upgraded, and its accounts' tokens keep the version they were signed with", () async {
    final (_, db) = await open();
    db.connection.execute(
      "INSERT INTO users (id, username, password_hash, is_admin, created_at) VALUES ('u1', 'owner', 'hash', 1, 0)",
    );
    downgrade(db, 4);

    final (_, again) = await open();
    expect(count(again, 'PRAGMA user_version'), DatabaseManager.schemaVersion);
    final row = again.connection.select('SELECT username, is_admin, token_version FROM users').single;
    expect((row['username'], row['is_admin'], row['token_version']), ('owner', 1, 0));
    expect(again.connection.select('SELECT * FROM downloads'), isEmpty);
  });

  test('user_hidden items persist, isolate users, and clear correctly', () async {
    final (repo, _) = await open();
    repo.setHiddenItem('track', 't1', true, 'u1');
    repo.setHiddenItem('album', 'al1', true, 'u1');
    repo.setHiddenItem('artist', 'ar1', true, 'u1');
    repo.setHiddenItem('track', 't2', true, 'u2');

    final u1Hidden = repo.getHiddenItems('u1');
    expect(u1Hidden['track'], {'t1'});
    expect(u1Hidden['album'], {'al1'});
    expect(u1Hidden['artist'], {'ar1'});

    final u2Hidden = repo.getHiddenItems('u2');
    expect(u2Hidden['track'], {'t2'});
    expect(u2Hidden['album'], isEmpty);
    expect(u2Hidden['artist'], isEmpty);

    // Unhide t1
    repo.setHiddenItem('track', 't1', false, 'u1');
    final u1After = repo.getHiddenItems('u1');
    expect(u1After['track'], isEmpty);
    expect(u1After['album'], {'al1'});

    // Clear u1
    repo.clearHiddenItems('u1');
    expect((repo.getHiddenItems('u1'))['album'], isEmpty);
    expect((repo.getHiddenItems('u2'))['track'], {'t2'});
  });

  test('initializing the schema twice changes nothing', () async {
    final (repo, db) = await open();
    repo.replaceAllTracks([make('a')]);
    final second = DatabaseManager(dbPath());
    opened.add(second);
    second.initializeSchema();
    db.initializeSchema();
    expect(repo.getAllTracks(), hasLength(1));
  });
}
