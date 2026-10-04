import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The formats the C# Wiretune wrote, which a migrated server and player must keep reading and writing the same way.
void main() {
  setUpAll(useTempDataDirectory);

  test('TimeSpan strings', () {
    expect(formatTimeSpan(const Duration(minutes: 3, seconds: 45, milliseconds: 123)), '00:03:45.1230000');
    expect(formatTimeSpan(const Duration(seconds: 7)), '00:00:07');
    expect(
      formatTimeSpan(const Duration(days: 1, hours: 2, minutes: 3, seconds: 4, milliseconds: 500)),
      '1.02:03:04.5000000',
    );
    expect(parseTimeSpan('00:03:45.1230000'), const Duration(minutes: 3, seconds: 45, milliseconds: 123));
    expect(parseTimeSpan('1.02:03:04.5'), const Duration(days: 1, hours: 2, minutes: 3, seconds: 4, milliseconds: 500));
    expect(parseTimeSpan('00:00:07'), const Duration(seconds: 7));
    expect(parseTimeSpan(225.5), const Duration(milliseconds: 225500));
    expect(parseTimeSpan('garbage'), isNull);
  });

  test('ISO timestamps with seven fractional digits', () {
    final value = DateTime.utc(2024, 1, 2, 3, 4, 5, 123, 456);
    expect(formatIsoUtc(value), '2024-01-02T03:04:05.1234560Z');
    expect(parseIsoUtc('2024-01-02T03:04:05.1234567Z'), value);
    expect(parseIsoUtc('2024-01-02T03:04:05'), DateTime.utc(2024, 1, 2, 3, 4, 5)); // no offset: UTC
    expect(parseIsoUtc('2024-01-02T05:04:05+02:00'), DateTime.utc(2024, 1, 2, 3, 4, 5));
    expect(parseIsoUtc(''), isNull);
  });

  test('invariant case mapping is the simple one, as in .NET', () {
    expect(toUpperInvariant('straße'), 'STRAßE'); // Dart's toUpperCase would write STRASSE
    expect(toUpperInvariant('éclair'), 'ÉCLAIR');
    expect(toLowerInvariant('İSTANBUL'), 'İstanbul'); // .NET's invariant casing leaves the Turkish I alone
    expect(toUpperInvariant('ıi'), 'ıI');
    expect(toLowerInvariant('/Music/ÁRVÍZTŰRŐ'), '/music/árvíztűrő');
  });

  // Reference values computed with the C# implementation (Wiretune.Core before the move to Dart): a server or player
  // that moves to this version keeps every favourite, play count, playlist entry and cover URL.
  test('track and album IDs match the C# implementation', () {
    expect(MetadataScanner.computeTrackId('/music/Artist/Album/01 Song.flac'), 'A9D288EBF81660BF79673390C4060682');
    expect(MetadataScanner.computeTrackId('/music/ÁRVÍZTŰRŐ/01.flac'), 'BB4402E1A9FADF14A80CB3EBDAB181FA');
    expect(MetadataScanner.computeTrackId('/music/Straße/İstanbul.flac'), '2A039F072DC9DCFFBFEA0E9D8981EBB0');
    expect(Track(album: 'Discovery', artist: 'Daft Punk').albumId, '7EBD55652378E7EF');
    expect(Track(album: 'Straße', artist: 'Bärenmarke').albumId, '9C4DE9412848489D');
    expect(Track(album: 'éclair', artist: 'ß').albumId, 'D0EB3EC773FF5095');
  });

  test('album and artist IDs are stable', () {
    final track = Track(album: 'Discovery', artist: 'Daft Punk');
    expect(track.albumId, stableId('DISCOVERY\u001fDAFT PUNK'));
    expect(track.albumId, hasLength(16));
    expect(Track(album: 'discovery', artist: 'DAFT PUNK').albumId, track.albumId); // ignoring case
  });

  test('a track survives the JSON round trip of the API', () {
    final track = TestSupport.makeTrack('ABC', 'Title', album: 'Album')
      ..year = 1999
      ..fileModifiedUtc = DateTime.utc(2025, 1, 2)
      ..hasCoverArt = true;
    final copy = Track.fromJson(track.toJson());
    expect(copy.id, 'ABC');
    expect(copy.duration, track.duration);
    expect(copy.year, 1999);
    expect(copy.fileModifiedUtc, DateTime.utc(2025, 1, 2));
    expect(copy.format, track.format);
    expect(copy.streamUrl, isNull);
    expect(track.toJson().containsKey('streamUrl'), isFalse);
    expect(track.toJson().containsKey('isFavorite'), isFalse);
    expect(() => Track.fromJson({'title': 'no id'}), throwsFormatException);
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

  test('log lines never carry a token', () {
    expect(
      WiretuneLog.redact('GET http://h/api/stream/1?token=abc.def&x=1'),
      'GET http://h/api/stream/1?token=***&x=1',
    );
  });
}
