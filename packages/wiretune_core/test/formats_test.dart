// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// IDs, the track's JSON, server addresses and paths: what the player and the server have to agree on.
void main() {
  setUpAll(useTempDataDirectory);

  test('track IDs come from the full path, and tell apart names that differ only in case where the disk does', () {
    final id = MetadataScanner.computeTrackId('/music/Artist/Album/01 Song.flac');
    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(MetadataScanner.computeTrackId('/music/Artist/../Artist/Album/01 Song.flac'), id); // the same file
    expect(MetadataScanner.computeTrackId('/music/Artist/Album/02 Song.flac'), isNot(id));

    final sameIgnoringCase = MetadataScanner.computeTrackId('/music/artist/album/01 song.flac') == id;
    expect(sameIgnoringCase, Platform.isWindows || Platform.isMacOS);
  });

  test('album IDs are short, stable and ignore case', () {
    final track = Track(album: 'Discovery', artist: 'Daft Punk');
    expect(track.albumId, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(track.albumId, stableId('discovery\u001fdaft punk'));
    expect(Track(album: 'discovery', artist: 'DAFT PUNK').albumId, track.albumId);
    expect(Track(album: 'Discovery', artist: 'Someone Else').albumId, isNot(track.albumId));
  });

  test('a track survives the JSON round trip of the API, without anything that stays on the server', () {
    final track = TestSupport.makeTrack('abc', 'Title', album: 'Album')
      ..year = 1999
      ..fileModifiedUtc = DateTime.utc(2025, 1, 2, 3, 4, 5, 6, 7)
      ..hasCoverArt = true;
    final json = track.toJson();
    expect(json['durationMs'], track.duration.inMilliseconds);
    for (final key in ['filePath', 'streamUrl', 'isFavorite', 'playCount', 'lastPlayed']) {
      expect(json.containsKey(key), isFalse, reason: key);
    }

    final copy = Track.fromJson(json);
    expect(copy.id, 'abc');
    expect(copy.duration, Duration(milliseconds: track.duration.inMilliseconds));
    expect(copy.year, 1999);
    expect(copy.fileModifiedUtc, DateTime.utc(2025, 1, 2, 3, 4, 5, 6, 7));
    expect(copy.format, track.format);
    expect(copy.filePath, isEmpty);
    expect(() => Track.fromJson({'title': 'no id'}), throwsFormatException);
  });

  test('instants keep their microseconds through the API and the database', () {
    final instant = DateTime.utc(2024, 1, 2, 3, 4, 5, 123, 456);
    expect(parseIsoUtc(formatIsoUtc(instant)), instant);
    expect(parseIsoUtc(formatIsoUtc(instant.toLocal())), instant);
    expect(fromDbTime(toDbTime(instant)), instant);
    expect(parseIsoUtc('not a date'), isNull);
    expect(parseIsoUtc(42), isNull);
  });

  test('server URLs are normalised', () {
    expect(ServerSession.normalizeServerUrl('192.168.1.10:5200'), 'http://192.168.1.10:5200');
    expect(ServerSession.normalizeServerUrl(' https://music.example.org/ '), 'https://music.example.org');
    expect(ServerSession.normalizeServerUrl('http://host:5200/wiretune/?x=1#y'), 'http://host:5200/wiretune');
    expect(ServerSession.normalizeServerUrl('http://user:pass@host'), isNull);
    expect(ServerSession.normalizeServerUrl('ftp://host'), isNull);
    expect(ServerSession.normalizeServerUrl('   '), isNull);
  });

  test('paths under a root are compared by whole segments', () {
    expect(AppPaths.isPathUnderRoot('/music/a.flac', '/music'), isTrue);
    expect(AppPaths.isPathUnderRoot('/music', '/music'), isTrue);
    expect(AppPaths.isPathUnderRoot('/music2/a.flac', '/music'), isFalse);
    expect(AppPaths.isPathUnderRoot('/music/../etc/passwd', '/music'), isFalse);
    expect(AppPaths.isPathUnderRoot('', '/music'), isFalse);
  });

  test("the music folder on Linux is the XDG one, in the system's language", () {
    const config = '''
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/Asztal"
XDG_MUSIC_DIR="\$HOME/Zenék"
XDG_VIDEOS_DIR="/srv/videos"
XDG_PUBLICSHARE_DIR="\$HOME/"
''';
    expect(AppPaths.xdgUserDir(config, 'MUSIC', '/home/me'), '/home/me/Zenék');
    expect(AppPaths.xdgUserDir(config, 'VIDEOS', '/home/me'), '/srv/videos');
    expect(AppPaths.xdgUserDir(config, 'PUBLICSHARE', '/home/me'), isNull); // switched off
    expect(AppPaths.xdgUserDir(config, 'PICTURES', '/home/me'), isNull);
    expect(AppPaths.xdgUserDir('XDG_MUSIC_DIR="relative/path"', 'MUSIC', '/home/me'), isNull);
  });

  test("the server's error codes read in the user's language, and an unknown one in the server's words", () {
    expect(
      describeServerError(ErrorCodes.folderWholeDisk),
      "A whole disk can't be the music folder: choose a folder on it.",
    );
    expect(describeServerError(ErrorCodes.favoritesLimit, 100000), contains('100'));
    expect(describeServerError(ErrorCodes.rateLimited, 1), 'Too many attempts. Try again in 1 second.');
    expect(describeServerError('somethingNew'), isNull);
    expect(describeServerError(null), isNull);
    Localizer.instance.setLanguage('hu');
    expect(describeServerError(ErrorCodes.folderMissing, '/mnt/nas'), 'Ez a mappa nem létezik a szerveren: /mnt/nas');
    Localizer.instance.setLanguage('en');

    // Every code the server sends has its text.
    const codes = [
      ErrorCodes.invalidJson, ErrorCodes.bodyTooLarge, ErrorCodes.notFound, ErrorCodes.internalError, //
      ErrorCodes.rateLimited, ErrorCodes.signInRequired, ErrorCodes.tokenInvalid, ErrorCodes.sessionExpired,
      ErrorCodes.passwordChanged, ErrorCodes.accountRemoved, ErrorCodes.wrongCredentials, ErrorCodes.adminOnly,
      ErrorCodes.credentialsRequired, ErrorCodes.usernameInvalid, ErrorCodes.passwordTooShort,
      ErrorCodes.passwordTooLong, ErrorCodes.alreadySetUp, ErrorCodes.setupCodeWrong, ErrorCodes.currentPasswordWrong,
      ErrorCodes.usernameTaken, ErrorCodes.userNotFound, ErrorCodes.cannotDeleteSelf,
      ErrorCodes.cannotResetOwnPassword, ErrorCodes.folderRequired, ErrorCodes.folderInvalid,
      ErrorCodes.folderMissing, ErrorCodes.folderUnreadable, ErrorCodes.folderWholeDisk, ErrorCodes.folderSystem,
      ErrorCodes.folderServerData, ErrorCodes.folderLooksUnmounted, ErrorCodes.scanFailed, ErrorCodes.invalidId,
      ErrorCodes.invalidItemType, ErrorCodes.favoritesLimit, ErrorCodes.playCountsLimit, ErrorCodes.playlistsLimit,
      ErrorCodes.hiddenLimit, ErrorCodes.playlistInvalid, ErrorCodes.playlistNameRequired,
      ErrorCodes.playlistNameTooLong, ErrorCodes.playlistDescriptionTooLong, ErrorCodes.playlistTooManyTracks,
      ErrorCodes.playlistNotFound, ErrorCodes.notWebSocket, ErrorCodes.originRefused, ErrorCodes.tooManyConnections,
    ];
    for (final code in codes) {
      expect(describeServerError(code, 1), isNotNull, reason: code);
    }
  });

  test('log lines never carry a token', () {
    expect(
      WiretuneLog.redact('GET http://h/api/stream/1?token=abc.def&x=1'),
      'GET http://h/api/stream/1?token=***&x=1',
    );
  });
}
