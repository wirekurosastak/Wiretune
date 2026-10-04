import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC-SHA256 JSON Web Tokens: the header `{"alg":"HS256","typ":"JWT"}`, Base64url without padding, and `iss`, `aud`
/// and `exp` checked with two minutes of clock skew, as the C# server's JwtBearer did. The claims are chosen by
/// [AuthService].
class Jwt {
  Jwt(String secret) : _key = utf8.encode(secret);

  final List<int> _key;

  /// The allowed difference between this server's clock and the one that issued a token.
  static const Duration clockSkew = Duration(minutes: 2);

  String sign(Map<String, Object?> claims) {
    final header = _encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
    final payload = _encode(utf8.encode(jsonEncode(claims)));
    final signature = _encode(Hmac(sha256, _key).convert(utf8.encode('$header.$payload')).bytes);
    return '$header.$payload.$signature';
  }

  /// The claims of [token] when its signature, issuer, audience and lifetime are valid; null otherwise.
  Map<String, Object?>? verify(String token, {required String issuer, required Set<String> audiences, DateTime? now}) {
    final parts = token.split('.');
    if (parts.length != 3) return null;

    try {
      final header = jsonDecode(utf8.decode(_decode(parts[0])));
      if (header is! Map || header['alg'] != 'HS256') return null;

      final expected = Hmac(sha256, _key).convert(utf8.encode('${parts[0]}.${parts[1]}')).bytes;
      if (!_constantTimeEquals(expected, _decode(parts[2]))) return null;

      final claims = jsonDecode(utf8.decode(_decode(parts[1])));
      if (claims is! Map<String, Object?>) return null;
      if (claims['iss'] != issuer) return null;

      final aud = claims['aud'];
      final tokenAudiences = aud is List ? aud.whereType<String>().toSet() : {if (aud is String) aud};
      if (!tokenAudiences.any(audiences.contains)) return null;

      final seconds = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      final exp = claims['exp'];
      if (exp is! num || seconds > exp + clockSkew.inSeconds) return null;
      final nbf = claims['nbf'];
      if (nbf is num && seconds < nbf - clockSkew.inSeconds) return null;
      return claims;
    } on FormatException {
      return null;
    }
  }

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
