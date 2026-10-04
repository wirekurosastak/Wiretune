import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/library_models.dart';
import '../util/event.dart';
import 'app_paths.dart';
import 'metadata_scanner.dart';
import 'wiretune_log.dart';

/// Fetches artist pictures from the internet (Deezer's public artist search) and caches the answers on disk and in
/// memory. Artist names are sent to api.deezer.com; set `WIRETUNE_NO_ARTIST_PICTURES=1` to keep the library offline.
class ArtistPictureService {
  ArtistPictureService._();

  static final ArtistPictureService instance = ArtistPictureService._();

  static const String disableEnvironmentVariable = 'WIRETUNE_NO_ARTIST_PICTURES';

  /// After a network or server failure no further requests are made for this long (and nothing is cached).
  static const Duration _failureBackoff = Duration(minutes: 5);
  static const Duration _saveDelay = Duration(seconds: 2);

  final Map<String, String> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};
  bool _isLoaded = false;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Timer? _saveTimer;
  int _batchRunning = 0;

  /// Raised (with the artist) when a picture was found and set.
  final Event<Artist> pictureResolved = Event<Artist>();

  /// Replaceable by tests, so nothing needs the real network or the real profile folder.
  http.Client client = http.Client();
  String? cacheFileOverride;

  static bool get _isDisabled {
    final value = Platform.environment[disableEnvironmentVariable];
    return value != null && value.isNotEmpty && value != '0';
  }

  void resetForTests() {
    _cache.clear();
    _inFlight.clear();
    _retryAfter = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    _isLoaded = true;
  }

  bool isCached(String artistName) => _cache.containsKey(_key(artistName));

  static String _key(String name) => name.trim().toLowerCase();

  /// The cached or fetched picture URL of the artist; null if there is none or on error.
  Future<String?> getArtistPictureUrl(String? artistName) async {
    if (artistName == null || artistName.trim().isEmpty || MetadataScanner.isUnknownArtist(artistName)) return null;
    _loadCache();

    final key = _key(artistName);
    final cached = _cache[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    if (_isDisabled || DateTime.now().toUtc().isBefore(_retryAfter)) return null;

    // Callers asking for the same artist at once share one request.
    return _inFlight[key] ??= _fetch(artistName.trim(), key);
  }

  /// Resolves the picture of one artist in the background and sets [Artist.picturePath] when one is found.
  void resolveArtistPicture(Artist? artist) {
    if (artist == null || artist.name.trim().isEmpty) return;
    if (artist.picturePath?.toLowerCase().startsWith('http') ?? false) return;
    unawaited(() async {
      try {
        final url = await getArtistPictureUrl(artist.name);
        if (url != null && url.isNotEmpty) {
          artist.picturePath = url;
          pictureResolved.emit(artist);
        }
      } catch (e) {
        WiretuneLog.debug('ArtistPicture', "Error resolving picture for '${artist.name}': $e");
      }
    }());
  }

  /// Resolves the pictures of [artists] in the background, two requests at a time and politely spaced.
  void resolveArtistPictures(Iterable<Artist> artists) {
    final list = artists.toList();
    if (list.isEmpty) return;
    unawaited(() async {
      _loadCache();
      for (final artist in list) {
        if (artist.name.trim().isEmpty) continue;
        if (artist.picturePath?.toLowerCase().startsWith('http') ?? false) continue;

        final cached = _cache[_key(artist.name)];
        if (cached != null) {
          if (cached.isNotEmpty) {
            artist.picturePath = cached;
            pictureResolved.emit(artist);
          }
          continue;
        }
        if (_isDisabled || DateTime.now().toUtc().isBefore(_retryAfter)) return;

        while (_batchRunning >= 2) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        _batchRunning++;
        try {
          final url = await getArtistPictureUrl(artist.name);
          if (url != null && url.isNotEmpty) {
            artist.picturePath = url;
            pictureResolved.emit(artist);
          }
          // Gentle delay between requests to be polite to the public API.
          await Future<void>.delayed(const Duration(milliseconds: 80));
        } catch (e) {
          WiretuneLog.debug('ArtistPicture', "Batch error for '${artist.name}': $e");
        } finally {
          _batchRunning--;
        }
      }
    }());
  }

  Future<String?> _fetch(String artistName, String key) async {
    try {
      final uri = Uri.https('api.deezer.com', '/search/artist', {'q': artistName, 'limit': '1'});
      final response = await client
          .get(uri, headers: {'User-Agent': 'Wiretune/1.0 (Audiophile Music Player)'})
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

  String _cacheFilePath() => cacheFileOverride ?? p.join(AppPaths.getDataDirectory(), 'artist_pictures.json');

  void _loadCache() {
    if (_isLoaded) return;
    _isLoaded = true;
    try {
      final file = File(_cacheFilePath());
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
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
    try {
      final path = _cacheFilePath();
      final temp = '$path.tmp';
      File(temp).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_cache));
      File(temp).renameSync(path); // never leave a half-written cache behind
    } catch (e) {
      WiretuneLog.debug('ArtistPicture', 'Failed to save artist cache: $e');
    }
  }
}
