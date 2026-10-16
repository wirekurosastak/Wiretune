// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../about.dart';
import '../models/library_models.dart';
import '../util/event.dart';
import 'app_paths.dart';
import 'wiretune_log.dart';

/// Fetches artist pictures from the internet (Deezer's public artist search) and caches the answers on disk and in
/// memory. Artist names are sent to api.deezer.com; set `WIRETUNE_NO_ARTIST_PICTURES=1` to keep the library offline.
class ArtistPictureService {
  /// [client] sends the requests (null creates one); [cacheFile] keeps the answers (null keeps them in memory only).
  ArtistPictureService({http.Client? client, String? cacheFile})
    : _http = client ?? http.Client(),
      _ownsClient = client == null,
      _cacheFile = cacheFile;

  /// The production service: the answers kept in the Wiretune data directory.
  factory ArtistPictureService.createDefault() =>
      ArtistPictureService(cacheFile: p.join(AppPaths.getDataDirectory(), 'artist_pictures.json'));

  static const String disableEnvironmentVariable = 'WIRETUNE_NO_ARTIST_PICTURES';

  /// After a network or server failure no further requests are made for this long (and nothing is cached).
  static const Duration _failureBackoff = Duration(minutes: 5);
  static const Duration _saveDelay = Duration(seconds: 2);

  /// The pause after each request of a batch, to be polite to the public API.
  static const Duration _spacing = Duration(milliseconds: 80);

  final http.Client _http;
  final bool _ownsClient;
  final String? _cacheFile;
  final Map<String, String> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Queue<Artist> _queue = Queue();
  bool _isLoaded = false;
  bool _working = false;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Timer? _saveTimer;

  /// Raised (with the artist) when a picture was found and set.
  final Event<Artist> pictureResolved = Event<Artist>();

  static bool get _isDisabled {
    final value = Platform.environment[disableEnvironmentVariable];
    return value != null && value.isNotEmpty && value != '0';
  }

  bool get _mayAsk => !_isDisabled && !DateTime.now().toUtc().isBefore(_retryAfter);

  static String _key(String name) => name.trim().toLowerCase();

  /// The cached or fetched picture URL of the artist; null if there is none or on error.
  Future<String?> getArtistPictureUrl(String? artistName) async {
    if (artistName == null || artistName.trim().isEmpty || Track.isUnknownArtist(artistName)) return null;
    _loadCache();

    final key = _key(artistName);
    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    if (!_mayAsk) return null;

    // Callers asking for the same artist at once share one request.
    return _inFlight[key] ??= _fetch(artistName.trim(), key);
  }

  /// Resolves the picture of [artist] at once (its page is open) and sets [Artist.picturePath] when one is found.
  void resolveArtistPicture(Artist? artist) {
    if (artist != null && _wanted(artist)) unawaited(_resolve(artist));
  }

  /// Resolves the pictures of [artists] in the background, one request at a time.
  void resolveArtistPictures(Iterable<Artist> artists) {
    _queue.addAll(artists.where(_wanted));
    if (!_working) unawaited(_work());
  }

  /// An artist with a name and no picture from here yet (the album cover it shows meanwhile is a file path).
  static bool _wanted(Artist artist) =>
      artist.name.trim().isNotEmpty && !(artist.picturePath?.toLowerCase().startsWith('http') ?? false);

  Future<void> _work() async {
    _working = true;
    try {
      _loadCache();
      while (_queue.isNotEmpty) {
        final artist = _queue.removeFirst();
        final asks = !_cache.containsKey(_key(artist.name));
        if (asks && !_mayAsk) {
          _queue.clear(); // switched off or backing off: the next batch tries again
          break;
        }
        await _resolve(artist);
        if (asks) await Future<void>.delayed(_spacing);
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _resolve(Artist artist) async {
    try {
      final url = await getArtistPictureUrl(artist.name);
      if (url != null && url.isNotEmpty) {
        artist.picturePath = url;
        pictureResolved.emit(artist);
      }
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', "Error resolving picture for '${artist.name}': $e");
    }
  }

  Future<String?> _fetch(String artistName, String key) async {
    try {
      final uri = Uri.https('api.deezer.com', '/search/artist', {'q': artistName, 'limit': '1'});
      final response = await _http
          .get(uri, headers: {'User-Agent': WiretuneInfo.userAgent})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode > 299) {
        // Rate limiting or an outage says nothing about the artist: remember nothing, back off instead.
        _backOff('Deezer answered HTTP ${response.statusCode}');
        return null;
      }

      String? pictureUrl;
      final document = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      final data = document is Map ? document['data'] : null;
      if (data is List && data.isNotEmpty && data.first is Map) {
        final first = data.first as Map;
        for (final field in const ['picture_medium', 'picture_big', 'picture']) {
          final value = first[field];
          final uri = value is String ? Uri.tryParse(value) : null;
          if (uri != null && uri.isAbsolute && uri.scheme == 'https') {
            pictureUrl = uri.toString();
            break;
          }
        }
      }

      // A definitive answer, including "no such artist" (empty string), is cached so it is never asked again.
      _cache[key] = pictureUrl ?? '';
      _saveTimer?.cancel();
      _saveTimer = Timer(_saveDelay, _saveCache);
      return pictureUrl;
    } catch (e) {
      _backOff('$e');
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  void _backOff(String reason) {
    _retryAfter = DateTime.now().toUtc().add(_failureBackoff);
    WiretuneLog.debug(
      'ArtistPicture',
      'Artist picture lookup failed ($reason); pausing lookups for ${_failureBackoff.inMinutes} minutes.',
    );
  }

  void _loadCache() {
    final file = _cacheFile;
    if (_isLoaded || file == null) return;
    _isLoaded = true;
    try {
      if (!File(file).existsSync()) return;
      final decoded = jsonDecode(File(file).readAsStringSync());
      if (decoded is Map) {
        decoded.forEach((name, url) {
          if (name is String && url is String) _cache[_key(name)] = url;
        });
      }
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', 'Failed to load artist cache: $e');
    }
  }

  void _saveCache() {
    _saveTimer?.cancel();
    final file = _cacheFile;
    if (file == null) return;
    try {
      final temp = '$file.tmp';
      File(temp).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_cache));
      File(temp).renameSync(file); // never leave a half-written cache behind
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', 'Failed to save artist cache: $e');
    }
  }

  /// Saves what is still to be saved, and lets go of the connection.
  void close() {
    if (_saveTimer?.isActive ?? false) _saveCache();
    _queue.clear();
    if (_ownsClient) _http.close();
  }
}
