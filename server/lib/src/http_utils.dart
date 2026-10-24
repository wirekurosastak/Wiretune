// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:wiretune_core/wiretune_core.dart';

const Map<String, String> _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// A JSON response.
Response jsonResponse(Object? body, {int status = 200, Map<String, String>? headers}) =>
    Response(status, body: utf8.encode(jsonEncode(body)), headers: {..._jsonHeaders, ...?headers});

/// A JSON [body] (already encoded) with its version as the ETag, or "not modified" without a body when the request
/// names that version: a player that has the data already downloads nothing.
Response versionedJson(Request request, List<int> body) {
  final headers = {'etag': '"${sha1.convert(body)}"', 'cache-control': 'no-cache'};
  if (request.headers['if-none-match'] == headers['etag']) return Response.notModified(headers: headers);
  return Response.ok(body, headers: {..._jsonHeaders, ...headers});
}

/// `{ "error": message, "code": code, ...details }` with [status]: [code] (one of `ErrorCodes`) for a player to tell
/// the user in their language, [message] in English for whoever reads the exchange, [details] the numbers or path the
/// message names.
Response errorResponse(int status, String code, String message, [Map<String, Object?> details = const {}]) =>
    jsonResponse({'error': message, 'code': code, ...details}, status: status);

/// A rule the request broke, as a 400 (or [status]).
Response violationResponse(RuleViolation violation, {int status = 400}) =>
    errorResponse(status, violation.code, violation.message, violation.details);

/// 401 with a bearer challenge, saying why ([code]: no token, or why the one sent no longer opens the API).
Response unauthorized(String code) => errorResponse(401, code, switch (code) {
  ErrorCodes.sessionExpired => 'The sign-in has expired.',
  ErrorCodes.passwordChanged => 'The password was changed since this sign-in.',
  ErrorCodes.accountRemoved => 'The account no longer exists.',
  ErrorCodes.wrongCredentials => 'The user name or the password is wrong.',
  ErrorCodes.tokenInvalid => 'The token is not valid here.',
  _ => 'Sign in first.',
}).change(headers: {'www-authenticate': 'Bearer'});

/// 403: only an administrator may do this.
Response forbidden() => errorResponse(403, ErrorCodes.adminOnly, 'Only an administrator can do this.');

/// 404: there is no such thing.
Response notFound() => errorResponse(404, ErrorCodes.notFound, 'Not found.');

/// The request body was larger than allowed.
class BodyTooLargeException implements Exception {
  const BodyTooLargeException();
}

/// Reads the body as JSON, at most [limit] bytes. Null for an empty body; throws [FormatException] for invalid JSON
/// and [BodyTooLargeException] past the limit.
Future<Object?> readJsonBody(Request request, int limit) async {
  final declared = request.contentLength;
  if (declared != null && declared > limit) throw const BodyTooLargeException();

  final bytes = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (bytes.length + chunk.length > limit) throw const BodyTooLargeException();
    bytes.add(chunk);
  }
  if (bytes.isEmpty) return null;
  return jsonDecode(utf8.decode(bytes.takeBytes()));
}

/// Compresses a JSON response with gzip when the client accepts it. Audio and images are never compressed (they are
/// compressed already, and a ranged response must keep its byte offsets).
Future<Response> compressJson(Request request, Response response) async {
  final type = response.headers['content-type'] ?? '';
  if (!type.startsWith('application/json')) return response;
  final accepts = request.headers['accept-encoding'] ?? '';
  if (!accepts.split(',').any((e) => e.trim().split(';').first.trim().toLowerCase() == 'gzip')) return response;
  if (response.headers.containsKey('content-encoding')) return response;

  final body = await response.read().fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk));
  final bytes = body.takeBytes();
  if (bytes.length < 256) return response.change(body: bytes);
  final compressed = gzip.encode(bytes);
  return response.change(
    body: compressed,
    headers: {'content-encoding': 'gzip', 'vary': 'Accept-Encoding', 'content-length': '${compressed.length}'},
  );
}

/// Serves [file] with HTTP range support (a single `bytes=` range; anything else gets the whole file).
Future<Response> fileResponse(Request request, File file, String contentType, {Map<String, String>? headers}) async {
  final stat = await file.stat();
  final length = stat.size;
  final lastModified = HttpDate.format(stat.modified);
  final base = <String, String>{
    'content-type': contentType,
    'accept-ranges': 'bytes',
    'last-modified': lastModified,
    ...?headers,
  };

  final ifModifiedSince = request.headers['if-modified-since'];
  if (ifModifiedSince != null && request.headers['range'] == null) {
    try {
      final since = HttpDate.parse(ifModifiedSince);
      if (!stat.modified.toUtc().isAfter(since.add(const Duration(seconds: 1)))) {
        return Response.notModified(headers: base);
      }
    } catch (_) {
      // A date that can't be read sets no condition: the file is sent.
    }
  }

  final range = request.headers['range'];
  final ifRange = request.headers['if-range'];
  final rangeAllowed = ifRange == null || ifRange == lastModified;
  if (range != null && rangeAllowed) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (match != null && (match.group(1)!.isNotEmpty || match.group(2)!.isNotEmpty)) {
      // A number too large for an int is past the end of any file.
      int offset(String digits) => int.tryParse(digits) ?? length;
      int start, end;
      if (match.group(1)!.isEmpty) {
        // A suffix: the last N bytes.
        final suffix = offset(match.group(2)!);
        start = suffix >= length ? 0 : length - suffix;
        end = length - 1;
      } else {
        start = offset(match.group(1)!);
        end = match.group(2)!.isEmpty ? length - 1 : offset(match.group(2)!);
        if (end >= length) end = length - 1;
      }
      if (start >= length || start > end || length == 0) {
        return Response(416, headers: {...base, 'content-range': 'bytes */$length'});
      }
      final count = end - start + 1;
      return Response(
        206,
        body: request.method == 'HEAD' ? null : file.openRead(start, end + 1),
        headers: {...base, 'content-range': 'bytes $start-$end/$length', 'content-length': '$count'},
      );
    }
  }

  return Response.ok(
    request.method == 'HEAD' ? null : file.openRead(),
    headers: {...base, 'content-length': '$length'},
  );
}
