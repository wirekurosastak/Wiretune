// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../about.dart';
import '../models/library_models.dart';
import '../util/text.dart';
import 'app_paths.dart';
import 'wiretune_log.dart';

/// The lookup could not be made (no connection, the service answered with an error): not the same as "no lyrics".
class LyricsLookupException implements Exception {
  const LyricsLookupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Looks the lyrics of a track up on the internet, for tracks that have none of their own, using LRCLIB (lrclib.net:
/// a free, open lyrics database that needs no account or API key). This device asks LRCLIB directly, so it works for
/// local files and server tracks alike, and the server needs no internet access.
///
/// What leaves the device is the track's title, artist, album and length, nothing else. Answers are kept in a small
/// cache folder next to the library database (a found text for good, "nothing found" for a week). The environment
/// variable `WIRETUNE_NO_ONLINE_LYRICS=1` switches the lookup off for the whole process, whatever the setting says.
class OnlineLyrics {
  /// [client] sends the requests (null creates one); [baseUrl] is the LRCLIB server; [cacheDirectory] null keeps no
  /// cache; [now] is the clock (UTC), replaceable by tests.
  OnlineLyrics({http.Client? client, Uri? baseUrl, String? cacheDirectory, DateTime Function()? now})
    : _ownsClient = client == null,
      _http = client ?? http.Client(),
      _baseUrl = baseUrl ?? defaultBaseUrl,
      _cacheDirectory = cacheDirectory,
      _now = now ?? (() => DateTime.now().toUtc());

  /// The production service: a cache folder inside the Wiretune data directory.
  factory OnlineLyrics.createDefault() => OnlineLyrics(cacheDirectory: p.join(AppPaths.getDataDirectory(), 'lyrics'));

  /// The name shown as the source of lyrics found by this service.
  static const String sourceName = 'LRCLIB';
  static const String disableEnvironmentVariable = 'WIRETUNE_NO_ONLINE_LYRICS';
  static final Uri defaultBaseUrl = Uri.parse('https://lrclib.net/');
  static const Duration _missLifetime = Duration(days: 7);
  static const Duration _timeout = Duration(seconds: 12);
  static const int _maxResponseBytes = 1024 * 1024;
  static const int _maxLyricsLength = 100000;

  /// A search result whose length differs from the track's by more than this is a different recording.
  static const double _maxDurationDifferenceSeconds = 5;

  static final RegExp _leadingTimestamps = RegExp(r'^(?:\s*\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+\s*');
  static final RegExp _wordTimestamps = RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>\s?');
  static final RegExp _versionNote = RegExp(r'\([^)]*\)|\[[^\]]*\]');
  static final RegExp _metadataLine = RegExp(r'^\s*\[[A-Za-z]+:[^\]]*\]\s*$');
  static const List<String> _artistSeparators = [';', ' feat. ', ' feat ', ' ft. ', ' ft ', ' & ', ' x ', ', '];

  final http.Client _http;
  final bool _ownsClient;
  final Uri _baseUrl;
  final String? _cacheDirectory;
  final DateTime Function() _now;

  /// True unless the lookup was switched off for the whole process.
  static bool get isAllowedByEnvironment {
    final value = Platform.environment[disableEnvironmentVariable];
    return value == null || value.isEmpty || value == '0';
  }

  /// The lyrics of [track] as plain text, or null when LRCLIB has none (or the track has too little tag data to look
  /// for). Throws [LyricsLookupException] when the service could not be reached or answered with an error, so the
  /// caller can tell "no lyrics exist" from "could not check"; such a failure is never cached.
  Future<String?> find(Track track) async {
    if (!isAllowedByEnvironment) return null;
    final query = LyricsQuery.from(track);
    if (query == null) return null;

    final cached = await _readCache(query);
    if (cached != null) return cached.$1;

    final text = await _fetch(query);
    await _writeCache(query, text);
    return text;
  }

  void close() {
    if (_ownsClient) _http.close();
  }

  // ── Network ──────────────────────────────────────────────────────────────────────────────────────

  Future<String?> _fetch(LyricsQuery query) async {
    // 1. The exact recording: LRCLIB matches title, artist, album and a length within a couple of seconds.
    if (query.album != null && query.durationSeconds > 0) {
      final exact = await _getJson('api/get', {
        'artist_name': query.artist,
        'track_name': query.title,
        'album_name': query.album!,
        'duration': '${query.durationSeconds}',
      });
      final text = exact == null ? null : textOf(exact);
      if (text != null) return text;
    }

    // 2. A search by title and artist, taking the result whose length is closest to the track's. The file's artist tag
    //    may name several artists, while LRCLIB lists the track under the first, so that is tried second.
    for (final artist in artistCandidates(query.artist)) {
      final found = await _getJson('api/search', {'track_name': query.title, 'artist_name': artist});
      if (found == null) continue;
      final text = pickBest(found, query.title, artist, query.durationSeconds);
      if (text != null) return text;
    }
    return null;
  }

  /// The parsed answer, or null when LRCLIB has nothing for the request (404). Throws for any other failure.
  Future<Object?> _getJson(String path, Map<String, String> query) async {
    // Percent-encoding throughout: a space is %20, which every server reads as a space ("+" only means one in forms).
    final queryText = query.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final uri = Uri.parse('${_baseUrl.resolve(path)}?$queryText');
    http.StreamedResponse response;
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = WiretuneInfo.userAgent
        ..headers['Accept'] = 'application/json';
      response = await _http.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const LyricsLookupException('The lyrics service did not answer in time.');
    } on Exception catch (e) {
      throw LyricsLookupException('The lyrics service cannot be reached: $e');
    }

    if (response.statusCode == 404) {
      await response.stream.drain<void>();
      return null;
    }
    if (response.statusCode < 200 || response.statusCode > 299) {
      await response.stream.drain<void>();
      throw LyricsLookupException('The lyrics service answered HTTP ${response.statusCode}.');
    }
    if ((response.contentLength ?? 0) > _maxResponseBytes) {
      throw const LyricsLookupException('The lyrics service sent an unexpectedly large answer.');
    }

    final bytes = <int>[];
    try {
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxResponseBytes) {
          throw const LyricsLookupException('The lyrics service sent an unexpectedly large answer.');
        }
      }
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on LyricsLookupException {
      rethrow;
    } on FormatException {
      throw const LyricsLookupException('The lyrics service sent an unreadable answer.');
    } on Exception catch (e) {
      throw LyricsLookupException('The lyrics service cannot be reached: $e');
    }
  }

  // ── Reading an answer ────────────────────────────────────────────────────────────────────────────

  /// The lyrics in one LRCLIB record as plain text; null for an instrumental or a record without any text.
  static String? textOf(Object? record) {
    if (record is! Map) return null;
    if (record['instrumental'] == true) return null;

    final plain = record['plainLyrics'];
    if (plain is String && plain.trim().isNotEmpty) return _tidy(plain);

    // Some records only have the time-synced version; the timestamps are dropped to leave the text.
    final synced = record['syncedLyrics'];
    return synced is String && synced.trim().isNotEmpty ? _tidy(stripTimestamps(synced)) : null;
  }

  /// The lyrics of the search result that is the same song (similar title and artist) and closest in length to
  /// [durationSeconds] (0 = unknown length: the first match with text). A search can return loosely related songs;
  /// showing the lyrics of a different song would be worse than showing none.
  static String? pickBest(Object? results, String title, String artist, int durationSeconds) {
    if (results is! List) return null;

    String? best;
    var bestDifference = double.maxFinite;
    var inspected = 0;
    for (final record in results) {
      if (++inspected > 50) break;
      if (record is! Map) continue;
      final trackName = record['trackName'];
      final artistName = record['artistName'];
      if (!similarTitle(trackName is String ? trackName : null, title) ||
          !similarArtist(artistName is String ? artistName : null, artist)) {
        continue;
      }

      final text = textOf(record);
      if (text == null) continue;

      var difference = 0.0;
      final length = record['duration'];
      if (durationSeconds > 0 && length is num) {
        difference = (length - durationSeconds).abs().toDouble();
        if (difference > _maxDurationDifferenceSeconds) continue;
      }
      if (difference < bestDifference) {
        best = text;
        bestDifference = difference;
      }
    }
    return best;
  }

  /// True when two titles are the same song: equal apart from case, spacing, punctuation and a version note such as
  /// "(Remastered 2011)", "[Live]" or "- Single Edit". A title that merely contains the other is not.
  static bool similarTitle(String? found, String wanted) {
    if (found == null) return true; // the record does not say, so it cannot be ruled out
    final a = _fold(found);
    final b = _fold(wanted);
    if (a.isEmpty || b.isEmpty || a == b) return true;
    final coreA = _fold(_withoutVersionNote(found));
    final coreB = _fold(_withoutVersionNote(wanted));
    return coreA.isNotEmpty && coreA == coreB;
  }

  /// True when two artist names are the same act: equal apart from case and punctuation, or one names more artists than
  /// the other ("Artist feat. Guest" and "Artist"). A name of one or two letters is only ever equal to itself.
  static bool similarArtist(String? found, String wanted) {
    if (found == null) return true;
    final a = _fold(found);
    final b = _fold(wanted);
    if (a.isEmpty || b.isEmpty || a == b) return true;
    return (a.length < b.length ? a.length : b.length) >= 3 && (a.contains(b) || b.contains(a));
  }

  static String _withoutVersionNote(String title) {
    final plain = title.replaceAll(_versionNote, '');
    final dash = plain.indexOf(' - ');
    return dash > 0 ? plain.substring(0, dash) : plain;
  }

  static String _fold(String text) => lettersAndDigits(text).toLowerCase();

  /// Removes the `[01:23.45]` time tags of an LRC text, and its `[ar:Artist]`-style header lines.
  static String stripTimestamps(String lrc) {
    final kept = <String>[];
    for (final line in lrc.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      if (_metadataLine.hasMatch(line)) continue;
      final text = line.replaceFirst(_leadingTimestamps, '');
      kept.add(text.replaceAll(_wordTimestamps, '').trimRight());
    }
    return kept.join('\n');
  }

  static String _tidy(String text) {
    final tidy = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    return tidy.length > _maxLyricsLength ? tidy.substring(0, _maxLyricsLength) : tidy;
  }

  /// The artist as tagged, then (when the tag names several artists) the first of them.
  static List<String> artistCandidates(String artist) {
    var first = artist;
    for (final separator in _artistSeparators) {
      final at = first.toLowerCase().indexOf(separator);
      if (at > 0) first = first.substring(0, at);
    }
    first = first.trim();
    return [artist, if (first.isNotEmpty && !equalsIgnoreCase(first, artist)) first];
  }

  // ── Cache ────────────────────────────────────────────────────────────────────────────────────────

  String? _cachePathFor(LyricsQuery query) =>
      _cacheDirectory == null ? null : p.join(_cacheDirectory, '${query.cacheKey}.json');

  /// (text, true) for a usable cache entry (text null for a cached "nothing found"), null when there is none.
  Future<(String?, bool)?> _readCache(LyricsQuery query) async {
    final path = _cachePathFor(query);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final root = jsonDecode(await file.readAsString());
      if (root is! Map) return null;
      final text = root['text'];
      if (text is! String) {
        // "Nothing found" is only believed for a while: LRCLIB's collection keeps growing.
        final fetched = DateTime.tryParse(root['fetchedUtc'] as String? ?? '')?.toUtc();
        if (fetched == null || _now().difference(fetched) > _missLifetime) return null;
        return (null, true);
      }
      return (text, true);
    } catch (e) {
      WiretuneLog.debug('OnlineLyrics', 'Ignoring an unreadable cache entry: $e');
      return null;
    }
  }

  Future<void> _writeCache(LyricsQuery query, String? text) async {
    final path = _cachePathFor(query);
    if (path == null) return;
    try {
      await Directory(_cacheDirectory!).create(recursive: true);
      final temporary = '$path.${newId()}.tmp';
      await File(temporary).writeAsString(jsonEncode({'fetchedUtc': _now().toIso8601String(), 'text': text}));
      await File(temporary).rename(path);
    } catch (e) {
      // The cache is an optimisation: lyrics that could not be saved are simply looked up again next time.
      WiretuneLog.debug('OnlineLyrics', 'Could not cache lyrics: $e');
    }
  }
}

/// The identifying tags of a track, cleaned up.
class LyricsQuery {
  const LyricsQuery(this.title, this.artist, this.album, this.durationSeconds);

  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;

  /// Null for a track that is too anonymous to look up.
  static LyricsQuery? from(Track track) {
    final title = cleanText(track.title);
    final artist = cleanText(track.artist);
    if (title == null || artist == null) return null;
    if (Track.isUnknownArtist(artist)) return null;
    if (equalsIgnoreCase(title, Track.unknownTitle)) return null;

    final album = cleanText(track.album);
    final knownAlbum = equalsIgnoreCase(album, Track.unknownAlbum) ? null : album;
    return LyricsQuery(title, artist, knownAlbum, (track.duration.inMilliseconds / 1000).round());
  }

  /// A stable file name for this track's cache entry (a hash, so no tag text ends up in a path).
  String get cacheKey {
    final identity = '${artist.toLowerCase()}\n${title.toLowerCase()}\n${album?.toLowerCase() ?? ''}\n$durationSeconds';
    return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
  }
}
