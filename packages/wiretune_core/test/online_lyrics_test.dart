import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The LRCLIB lookup, against a stub of the service and a throw-away cache folder.
void main() {
  late Directory dir;
  late DateTime now;
  late List<String> requests;

  setUpAll(useTempDataDirectory);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('wiretune_onlinelyrics_');
    now = DateTime.utc(2026, 10, 1, 12);
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  http.Response json(String body, [int status = 200]) =>
      http.Response.bytes(utf8.encode(body), status, headers: {'content-type': 'application/json'});
  http.Response notFound() => json('{"code":404,"name":"TrackNotFound"}', 404);

  OnlineLyrics create(http.Response Function(http.Request request) respond, {bool cache = true}) => OnlineLyrics(
    client: MockClient((request) async {
      requests.add(request.url.toString().substring('https://lrclib.test'.length));
      return respond(request);
    }),
    baseUrl: Uri.parse('https://lrclib.test/'),
    cacheDirectory: cache ? dir.path : null,
    now: () => now,
  );

  Track song({String title = 'Song', String artist = 'Artist', String album = 'Album'}) =>
      TestSupport.makeTrack('t1', title, artist: artist, album: album, minutes: 3.0);

  List<FileSystemEntity> cacheFiles() => dir.listSync().where((f) => f.path.endsWith('.json')).toList();

  test('uses the exact match and keeps the answer for next time', () async {
    final lyrics = create(
      (_) => json(
        '{"id":1,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":180,'
        '"instrumental":false,"plainLyrics":"Line one\\r\\nLine two\\r\\n","syncedLyrics":"[00:01.00] Line one"}',
      ),
    );

    expect(await lyrics.find(song()), 'Line one\nLine two');
    expect(requests, ['/api/get?artist_name=Artist&track_name=Song&album_name=Album&duration=180']);

    expect(await lyrics.find(song()), 'Line one\nLine two'); // from the cache folder now
    expect(requests, hasLength(1));
    expect(cacheFiles(), hasLength(1));
  });

  test('escapes what it sends', () async {
    final lyrics = create((_) => json('{"plainLyrics":"x"}'));
    await lyrics.find(song(title: 'Rock & Roll? #1', artist: 'AC/DC', album: 'Back in Black'));
    final request = requests.single;
    expect(request, contains('artist_name=AC%2FDC'));
    expect(request, contains('track_name=Rock%20%26%20Roll%3F%20%231'));
    expect(request, contains('album_name=Back%20in%20Black'));
  });

  test('without an exact match it searches and takes the same song closest in length', () async {
    final lyrics = create(
      (request) => request.url.path == '/api/get'
          ? notFound()
          : json('''[
            {"trackName":"Song","artistName":"Artist","albumName":"Live","duration":240,"plainLyrics":"live version"},
            {"trackName":"Song","artistName":"Artist","albumName":"Greatest hits","duration":183,"plainLyrics":"hits version"},
            {"trackName":"Song (Remastered)","artistName":"Artist","albumName":"Album","duration":181,"plainLyrics":"remaster"},
            {"trackName":"Another Song","artistName":"Artist","albumName":"Album","duration":180,"plainLyrics":"wrong song"},
            {"trackName":"Song","artistName":"Someone Else","albumName":"Album","duration":180,"plainLyrics":"wrong artist"}
          ]'''),
    );

    expect(await lyrics.find(song()), 'remaster');
    expect(requests, hasLength(2));
    expect(requests[1], '/api/search?track_name=Song&artist_name=Artist');
  });

  test('without a known album it goes straight to the search', () async {
    final lyrics = create(
      (_) => json('[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"found"}]'),
    );
    expect(await lyrics.find(song(album: MetadataScanner.unknownAlbum)), 'found');
    expect(requests.single, startsWith('/api/search?'));
  });

  test('when the tag names several artists it tries the first one too', () async {
    final lyrics = create(
      (request) => request.url.query.contains('artist_name=Artist%20feat.%20Guest')
          ? json('[]')
          : request.url.path == '/api/get'
          ? notFound()
          : json(
              '[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"found under the first artist"}]',
            ),
    );
    expect(await lyrics.find(song(artist: 'Artist feat. Guest')), 'found under the first artist');
  });

  test('a time-synced-only record loses its timestamps', () async {
    final lyrics = create(
      (_) => json(
        '{"instrumental":false,"plainLyrics":null,'
        '"syncedLyrics":"[ar:Artist]\\n[ti:Song]\\n[00:12.34] Hello\\n[00:15.00][00:30.00] World <00:15.50>again\\n[00:40.00]"}',
      ),
    );
    expect(await lyrics.find(song()), 'Hello\nWorld again');
  });

  test('an instrumental is null and not asked again for a week', () async {
    final lyrics = create(
      (request) => request.url.path == '/api/get'
          ? json('{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}')
          : json('[]'),
    );

    expect(await lyrics.find(song()), isNull);
    expect(requests, hasLength(2)); // the exact match, then the search

    now = now.add(const Duration(days: 6));
    expect(await lyrics.find(song()), isNull);
    expect(requests, hasLength(2)); // still remembered

    now = now.add(const Duration(days: 2)); // eight days after the first look
    expect(await lyrics.find(song()), isNull);
    expect(requests, hasLength(4)); // asked again
  });

  test('found lyrics are kept for good', () async {
    final lyrics = create((_) => json('{"plainLyrics":"keep me"}'));
    await lyrics.find(song());
    now = now.add(const Duration(days: 800));
    expect(await lyrics.find(song()), 'keep me');
    expect(requests, hasLength(1));
  });

  test('when the service cannot be reached it throws and remembers nothing', () async {
    var down = true;
    final lyrics = create((_) => down ? json('{}', 503) : json('{"plainLyrics":"back again"}'));

    await expectLater(lyrics.find(song()), throwsA(isA<LyricsLookupException>()));
    expect(cacheFiles(), isEmpty); // a failure is not "no lyrics"

    down = false;
    expect(await lyrics.find(song()), 'back again');
  });

  test('a dropped connection is a lookup failure', () async {
    final lyrics = OnlineLyrics(
      client: MockClient((_) async => throw http.ClientException('no route to host')),
      baseUrl: Uri.parse('https://lrclib.test/'),
      cacheDirectory: dir.path,
    );
    await expectLater(lyrics.find(song()), throwsA(isA<LyricsLookupException>()));
  });

  test('an unreasonably large answer is refused', () async {
    final lyrics = create((_) => json('{"plainLyrics":"${'a' * (2 * 1024 * 1024)}"}'));
    await expectLater(lyrics.find(song()), throwsA(isA<LyricsLookupException>()));
  });

  test('a track that is too anonymous is not looked up', () async {
    final lyrics = create((_) => json('{"plainLyrics":"x"}'));
    for (final (title, artist) in [
      ('Song', 'Unknown artist'),
      ('Song', '   '),
      ('   ', 'Artist'),
      ('Unknown Title', 'Artist'),
    ]) {
      expect(await lyrics.find(song(title: title, artist: artist)), isNull);
    }
    expect(requests, isEmpty);
  });

  test('an unreadable cache entry is ignored and repaired', () async {
    final lyrics = create((_) => json('{"plainLyrics":"fresh"}'));
    final key = LyricsQuery.from(song())!.cacheKey;
    File(p.join(dir.path, '$key.json')).writeAsStringSync('{ this is not json');

    expect(await lyrics.find(song()), 'fresh');
    expect(await lyrics.find(song()), 'fresh');
    expect(requests, hasLength(1));
  });

  test('works without a cache folder', () async {
    final lyrics = create((_) => json('{"plainLyrics":"x"}'), cache: false);
    expect(await lyrics.find(song()), 'x');
    expect(await lyrics.find(song()), 'x');
    expect(requests, hasLength(2));
  });

  test('the cache key is stable and does not leak the tags', () {
    final key = LyricsQuery.from(song(title: 'Secret Title', artist: 'Secret Artist'))!.cacheKey;
    expect(LyricsQuery.from(song(title: 'secret title', artist: 'SECRET ARTIST'))!.cacheKey, key);
    expect(LyricsQuery.from(song(title: 'Another Title', artist: 'Secret Artist'))!.cacheKey, isNot(key));
    expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  group('stripTimestamps leaves just the words', () {
    for (final (lrc, expected) in [
      ('[00:12.34] Hello', 'Hello'),
      ('[01:02] Hello', 'Hello'),
      ('[00:15.00][00:30.00] Chorus', 'Chorus'),
      ('[00:12.340]   Spaced', 'Spaced'),
      ('No tag here', 'No tag here'),
      ('[ar:Artist]\n[00:01.00] First\n\n[00:05.00] Third', 'First\n\nThird'),
      ('[00:01.00] Un <00:01.50>deux <00:02.00>trois', 'Un deux trois'),
    ]) {
      test(lrc, () => expect(OnlineLyrics.stripTimestamps(lrc), expected));
    }
  });

  test('artist candidates are the tag, then the first artist', () {
    expect(OnlineLyrics.artistCandidates('Artist'), ['Artist']);
    expect(OnlineLyrics.artistCandidates('Artist feat. Guest'), ['Artist feat. Guest', 'Artist']);
    expect(OnlineLyrics.artistCandidates('Artist; Other'), ['Artist; Other', 'Artist']);
    expect(OnlineLyrics.artistCandidates('Artist & Other'), ['Artist & Other', 'Artist']);
    expect(OnlineLyrics.artistCandidates('Artist ft. Guest, Other'), ['Artist ft. Guest, Other', 'Artist']);
  });

  test('similar titles are the same song under another spelling, but not another song', () {
    for (final (found, wanted, expected) in [
      ('Song', 'Song', true),
      ('song!', 'SONG', true),
      ('Song (Remastered 2011)', 'Song', true),
      ('Song [Live]', 'Song', true),
      ('Song - Single Edit', 'Song', true),
      ('Song', 'Song (feat. Guest)', true),
      ('Song (feat. Guest)', 'Song (feat. Guest)', true),
      (null, 'Song', true),
      ('Another Song', 'Song', false),
      ('Song Two', 'Song', false),
      ('Other', 'Song', false),
      ('(Untitled)', '(Untitled)', true),
    ]) {
      expect(OnlineLyrics.similarTitle(found, wanted), expected, reason: '$found / $wanted');
    }
  });

  test('similar artists are the same act with more or fewer names', () {
    for (final (found, wanted, expected) in [
      ('Artist', 'Artist', true),
      ('ARTIST', 'artist!', true),
      ('Artist feat. Guest', 'Artist', true),
      ('Artist', 'Artist & Friends', true),
      (null, 'Artist', true),
      ('Someone Else', 'Artist', false),
      ('AB', 'ABC', false),
    ]) {
      expect(OnlineLyrics.similarArtist(found, wanted), expected, reason: '$found / $wanted');
    }
  });

  test('textOf prefers the plain text and caps the length', () {
    expect(OnlineLyrics.textOf({'plainLyrics': 'plain', 'syncedLyrics': '[00:01.00] synced'}), 'plain');
    expect(OnlineLyrics.textOf({'plainLyrics': 'x' * 150000})!.length, 100000);
    expect(OnlineLyrics.textOf({'plainLyrics': '  ', 'syncedLyrics': ''}), isNull);
  });
}
