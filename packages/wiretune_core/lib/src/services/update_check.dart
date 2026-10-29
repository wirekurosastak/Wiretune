// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../about.dart';

/// The check or the download failed: no connection, an error from GitHub, or a file that isn't the one the release
/// lists.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A published release of Wiretune: its version (the tag without its "v") and where each of its files downloads from.
class Release {
  const Release(this.version, this.files);

  final String version;
  final Map<String, Uri> files;

  /// The name of the file that [pattern] matches as a whole, or null when the release has none.
  String? fileMatching(RegExp pattern) {
    for (final name in files.keys) {
      if (pattern.matchAsPrefix(name)?.end == name.length) return name;
    }
    return null;
  }
}

/// Asks GitHub for the latest release of Wiretune, and downloads its files.
///
/// What leaves the device is a request to GitHub's API with the `Wiretune/<version>` user agent, and, when the user
/// updates, the download of one file and of the release's checksums. The environment variable
/// `WIRETUNE_NO_UPDATE_CHECK=1` switches it off for the whole process, whatever the setting says.
class UpdateCheck {
  /// [client] sends the requests (null creates one); [latestUrl] answers as GitHub's latest-release route does.
  UpdateCheck({http.Client? client, Uri? latestUrl})
    : _ownsClient = client == null,
      _http = client ?? http.Client(),
      _latestUrl = latestUrl ?? defaultLatestUrl;

  static final Uri defaultLatestUrl = Uri.parse('https://api.github.com/repos/wirekurosastak/Wiretune/releases/latest');
  static const String disableEnvironmentVariable = 'WIRETUNE_NO_UPDATE_CHECK';

  /// The release lists the SHA-256 of every file in this one, as `sha256sum` writes them.
  static const String checksumsFile = 'SHA256SUMS.txt';

  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxAnswerBytes = 1024 * 1024;
  static const int _maxFileBytes = 512 * 1024 * 1024;

  /// The version this build is, as its release is tagged: [WiretuneInfo.version] without its build number.
  static String get currentVersion => WiretuneInfo.version.substring(0, WiretuneInfo.version.lastIndexOf('.'));

  final http.Client _http;
  final bool _ownsClient;
  final Uri _latestUrl;

  /// True unless the check was switched off for the whole process.
  static bool get isAllowedByEnvironment {
    final value = Platform.environment[disableEnvironmentVariable];
    return value == null || value.isEmpty || value == '0';
  }

  /// The latest release when it is newer than [current], else null (also when nothing has been released yet).
  Future<Release?> newer([String? current]) async {
    final answer = await _get(_latestUrl, accept: 'application/vnd.github+json', maxBytes: _maxAnswerBytes);
    if (answer == null) return null;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(answer));
    } on FormatException {
      throw const UpdateException('GitHub sent an unreadable answer.');
    }
    final release = _parse(json);
    if (release == null) throw const UpdateException('GitHub sent an answer that names no release.');
    return compareVersions(release.version, current ?? currentVersion) > 0 ? release : null;
  }

  /// Downloads the file [name] of [release] into [folder] and checks it against the release's checksums, reporting
  /// what share of it has arrived (0 to 1) to [onProgress]. A file that doesn't match is deleted.
  Future<File> download(
    Release release,
    String name,
    String folder, {
    void Function(double progress)? onProgress,
  }) async {
    final address = release.files[name];
    final checksums = release.files[checksumsFile];
    if (address == null) throw UpdateException('The release has no $name.');
    if (checksums == null) throw UpdateException('The release has no $checksumsFile to check $name against.');
    final expected = _checksumOf(name, utf8.decode(await _get(checksums, maxBytes: _maxAnswerBytes) ?? const []));
    if (expected == null) throw UpdateException('$checksumsFile lists no $name.');

    await Directory(folder).create(recursive: true);
    final file = File(p.join(folder, name));
    await _save(address, file, onProgress);
    final actual = '${await sha256.bind(file.openRead()).first}';
    if (actual != expected) {
      await file.delete();
      throw UpdateException('$name is not the file the release lists: its checksum differs.');
    }
    return file;
  }

  void close() {
    if (_ownsClient) _http.close();
  }

  /// Compares two versions part by part (`1.0.2026` < `1.1.2026` < `1.10.2026`); a missing part counts as 0.
  static int compareVersions(String a, String b) {
    final left = _parts(a);
    final right = _parts(b);
    for (var i = 0; i < left.length || i < right.length; i++) {
      final difference = (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
      if (difference != 0) return difference.sign;
    }
    return 0;
  }

  static List<int> _parts(String version) => [for (final part in version.split('.')) int.tryParse(part) ?? 0];

  /// A release from GitHub's answer: its tag (`v1.2.3`) and its files. Null when the answer isn't one.
  static Release? _parse(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || !RegExp(r'^v[0-9]+(\.[0-9]+)*$').hasMatch(tag)) return null;
    final files = <String, Uri>{};
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'];
        final url = asset['browser_download_url'];
        final uri = url is String ? Uri.tryParse(url) : null;
        if (name is String && uri != null && uri.isScheme('https')) files[name] = uri;
      }
    }
    return Release(tag.substring(1), files);
  }

  /// The checksum `sha256sum` wrote for [name] in [listing] (`<hex>  <name>`, or `<hex> *<name>` in binary mode).
  static String? _checksumOf(String name, String listing) {
    for (final line in const LineSplitter().convert(listing)) {
      final match = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line.trim());
      if (match != null && match.group(2) == name) return match.group(1)!.toLowerCase();
    }
    return null;
  }

  /// The body of [uri], or null for a 404 (no release yet). Throws for anything else that isn't a success.
  Future<List<int>?> _get(Uri uri, {String accept = '*/*', required int maxBytes}) async {
    final response = await _send(uri, accept);
    if (response.statusCode == 404) {
      await response.stream.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in _body(response, maxBytes)) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<void> _save(Uri uri, File file, void Function(double)? onProgress) async {
    final response = await _send(uri, 'application/octet-stream');
    if (response.statusCode == 404) {
      await response.stream.drain<void>();
      throw UpdateException('${file.uri.pathSegments.last} is missing from the release.');
    }
    final total = response.contentLength;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in _body(response, _maxFileBytes)) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) onProgress?.call((received / total).clamp(0, 1).toDouble());
      }
    } finally {
      await sink.close();
    }
  }

  Future<http.StreamedResponse> _send(Uri uri, String accept) async {
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = WiretuneInfo.userAgent
        ..headers['Accept'] = accept;
      return await _http.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const UpdateException('GitHub did not answer in time.');
    } on Exception catch (e) {
      throw UpdateException('GitHub cannot be reached: $e');
    }
  }

  /// The body of a successful [response], at most [maxBytes] of it; an error status or a stall throws.
  Stream<List<int>> _body(http.StreamedResponse response, int maxBytes) async* {
    if (response.statusCode < 200 || response.statusCode > 299) {
      await response.stream.drain<void>();
      throw UpdateException('GitHub answered HTTP ${response.statusCode}.');
    }
    const tooLarge = UpdateException('GitHub sent an unexpectedly large file.');
    if ((response.contentLength ?? 0) > maxBytes) throw tooLarge;
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(_timeout)) {
        received += chunk.length;
        if (received > maxBytes) throw tooLarge;
        yield chunk;
      }
    } on UpdateException {
      rethrow;
    } on Exception catch (e) {
      throw UpdateException('The download stopped: $e');
    }
  }
}
