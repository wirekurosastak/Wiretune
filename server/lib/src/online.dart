// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:wiretune_core/wiretune_core.dart';

/// The online services the server asks about the music (never about the accounts), each as one client for the whole
/// server: its requests go one at a time, spaced as the service allows, however many lookups ask at once.
abstract class _OnlineService {
  _OnlineService(this._client, this.pause);

  final http.Client _client;

  /// Between two requests.
  final Duration pause;

  Future<void> _queue = Future.value();

  /// [request] after the ones asked before it, [pause] after the last one.
  Future<T> _inTurn<T>(Future<T> Function() request) {
    final answer = _queue.then((_) async {
      await Future<void>.delayed(pause);
      return request();
    });
    _queue = answer.then((_) {}, onError: (Object _) {});
    return answer;
  }

  static Map<String, Object?> _decode(http.Response response, String service) {
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, Object?>) throw FormatException('$service answered something else.');
    return body;
  }
}

/// Deezer's public API: albums (genre, label), artists and the artists its listeners also play. It allows 50 requests
/// in 5 seconds.
class Deezer extends _OnlineService {
  Deezer(http.Client client, {Duration pause = const Duration(milliseconds: 250)}) : super(client, pause);

  static const String _api = 'https://api.deezer.com';

  /// The answer at [path], or null when Deezer has nothing there. Throws when it can't be reached or answers something
  /// else.
  Future<Map<String, Object?>?> get(String path) => _inTurn(() async {
    final response = await _client
        .get(
          Uri.parse('$_api$path'),
          // The genres in English, as the interface's other words are not translated data.
          headers: {'accept-language': 'en', 'user-agent': 'Wiretune/${WiretuneInfo.version}'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw http.ClientException('Deezer answered ${response.statusCode}');
    final body = _OnlineService._decode(response, 'Deezer');
    return body.containsKey('error') ? null : body;
  });

  /// The forms a release's barcode is looked up in: as tagged, and as a 13- and a 12-digit code (a tag may hold the
  /// 14-digit GTIN of a 12-digit UPC, with leading zeros Deezer doesn't).
  static List<String> barcodeForms(String barcode) {
    final digits = barcode.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return const [];
    final bare = digits.replaceFirst(RegExp(r'^0+'), '');
    return {digits, bare.padLeft(13, '0'), bare.padLeft(12, '0')}.toList();
  }
}

/// MusicBrainz's API: credits, release groups and artists with their genres. It allows one request a second, and
/// answers "busy" (503) when it has too much to do: then it is asked again after a while.
class MusicBrainz extends _OnlineService {
  MusicBrainz(
    http.Client client, {
    Duration pause = const Duration(milliseconds: 1100),
    this.busyWaits = const [Duration(seconds: 5), Duration(seconds: 20), Duration(minutes: 1)],
  }) : super(client, pause);

  /// How long to wait before asking again when MusicBrainz is busy, once for each; after the last, the request fails.
  final List<Duration> busyWaits;

  static const String _api = 'https://musicbrainz.org/ws/2';

  /// The answer at [path], or null when MusicBrainz has nothing there. Throws when it can't be reached, stays busy or
  /// answers something else.
  Future<Map<String, Object?>?> get(String path) => _inTurn(() async {
    final separator = path.contains('?') ? '&' : '?';
    final uri = Uri.parse('$_api$path${separator}fmt=json');
    for (var attempt = 0; ; attempt++) {
      final response = await _client
          .get(
            uri,
            // MusicBrainz asks every client to say what it is and where to find it.
            headers: {'user-agent': 'Wiretune/${WiretuneInfo.version} ( ${WiretuneInfo.sourceUrl} )'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 503 && attempt < busyWaits.length) {
        await Future<void>.delayed(busyWaits[attempt]);
        continue;
      }
      if (response.statusCode == 404 || response.statusCode == 400) return null;
      if (response.statusCode != 200) throw http.ClientException('MusicBrainz answered ${response.statusCode}');
      return _OnlineService._decode(response, 'MusicBrainz');
    }
  });

  /// [text] as a phrase in a search query: in quotes, with the query language's own characters taken out.
  static String phrase(String text) => '"${text.replaceAll(RegExp(r'[\\"+\-!(){}\[\]^~*?:/&|]'), ' ').trim()}"';
}

/// Whether two names are the same but for case, accents and punctuation.
bool sameName(String a, String b) {
  String plain(String text) => foldForSearch(text).replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return plain(a) == plain(b);
}
