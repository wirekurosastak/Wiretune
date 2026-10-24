// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC-SHA256 JSON Web Tokens: the header `{"alg":"HS256","typ":"JWT"}` and base64url without padding. The server only
/// verifies tokens it signed itself, so [verifySigned] checks the signature and the audience, [isExpired] the expiry,
/// and nothing else.
class Jwt {
  Jwt(String secret) : _key = utf8.encode(secret);

  final List<int> _key;

  String sign(Map<String, Object?> claims) {
    final header = _encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
    final payload = _encode(utf8.encode(jsonEncode(claims)));
    return '$header.$payload.${_encode(_signature('$header.$payload'))}';
  }

  /// The claims of [token] when it carries this key's signature, its `aud` is one of [audiences] and it has an `exp`,
  /// whether that has passed or not ([isExpired]); null otherwise.
  Map<String, Object?>? verifySigned(String token, {required Set<String> audiences}) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final header = jsonDecode(utf8.decode(_decode(parts[0])));
      if (header is! Map || header['alg'] != 'HS256') return null;
      if (!_constantTimeEquals(_signature('${parts[0]}.${parts[1]}'), _decode(parts[2]))) return null;

      final claims = jsonDecode(utf8.decode(_decode(parts[1])));
      if (claims is! Map<String, Object?> || !audiences.contains(claims['aud']) || claims['exp'] is! int) return null;
      return claims;
    } catch (_) {
      return null;
    }
  }

  /// Whether the `exp` of [claims] (from [verifySigned]) is not ahead of [now].
  static bool isExpired(Map<String, Object?> claims, {DateTime? now}) =>
      (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 >= (claims['exp'] as int);

  List<int> _signature(String signed) => Hmac(sha256, _key).convert(utf8.encode(signed)).bytes;

  static String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _decode(String text) => base64Url.decode(base64Url.normalize(text));

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
