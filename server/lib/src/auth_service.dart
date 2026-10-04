import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'jwt.dart';

/// The identity a validated token carries.
class Principal {
  const Principal(this.userId, this.username, this.role, {this.isStreamToken = false});

  final String userId;
  final String username;
  final String role;

  /// A stream token opens the audio and cover routes and nothing else.
  final bool isStreamToken;

  bool get isAdmin => role == 'admin';
}

/// Accounts, passwords (bcrypt, work factor 12) and tokens (HS256 JWTs).
class AuthService {
  AuthService(this._db, String signingSecret) : _jwt = Jwt(signingSecret) {
    _db.initializeSchema();
  }

  static const String issuer = 'WiretuneServer';
  static const String audience = 'WiretuneClient';

  /// Audience of the short-lived tokens that stream URLs carry; they open the media routes only.
  static const String streamAudience = 'WiretuneStream';
  static const String scopeClaim = 'wt_scope';
  static const String streamScope = 'stream';

  // The claim names .NET writes for ClaimTypes.NameIdentifier, Name and Role. Tokens carry exactly these, as the C#
  // server issued them, so a token signed by either server is valid on the other.
  static const String nameIdClaim = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier';
  static const String nameClaim = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name';
  static const String roleClaim = 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role';

  /// Long enough for a multi-hour track to be seeked in; the player asks for a new one well before that.
  static const Duration streamTokenLifetime = Duration(hours: 8);
  static const int _bcryptWorkFactor = 12;

  final DatabaseManager _db;
  final Jwt _jwt;
  Future<String>? _dummyHash;

  /// 64 random bytes, Base64: the key tokens are signed with (kept in the server's database).
  static String generateSecret() {
    final random = Random.secure();
    return base64.encode(List<int>.generate(64, (_) => random.nextInt(256)));
  }

  /// Null when [username] and [password] may be used for an account, otherwise the reason.
  static String? validateCredentials(String? username, String? password) {
    if (isBlank(username) || password == null || password.isEmpty) return 'Username and password are required.';
    final trimmed = username!.trim();
    if (trimmed.length > AuthRules.maxUsernameLength || hasControlCharacters(trimmed)) {
      return 'Username must be at most ${AuthRules.maxUsernameLength} printable characters.';
    }
    return validatePassword(password);
  }

  /// Null when [password] may be used, otherwise the reason.
  static String? validatePassword(String password) {
    if (password.length < AuthRules.minPasswordLength) {
      return 'Password must be at least ${AuthRules.minPasswordLength} characters.';
    }
    if (utf8.encode(password).length > AuthRules.maxPasswordBytes) {
      return 'Password must be at most ${AuthRules.maxPasswordBytes} bytes.';
    }
    return null;
  }

  /// Sets a new password when [current] is the account's present one. False when it is not (or the account is gone).
  /// Tokens already issued stay valid until they expire; the server has no token revocation.
  Future<bool> changePassword(String userId, String current, String replacement) async {
    final rows = _db.connection.select('SELECT password_hash FROM users WHERE id = ?', [userId]);
    if (rows.isEmpty || !await _verify(current, rows.first['password_hash'] as String)) return false;
    final hash = await _hash(replacement);
    _db.connection.execute('UPDATE users SET password_hash = ? WHERE id = ?', [hash, userId]);
    return _db.connection.updatedRows > 0;
  }

  static Future<String> _hash(String password) => _hashInIsolate(password, _bcryptWorkFactor);

  static Future<bool> _verify(String password, String hash) => _verifyInIsolate(password, hash);

  bool hasAnyUsers() => (_db.connection.select('SELECT COUNT(*) AS n FROM users').first['n'] as int) > 0;

  Future<AuthResponse?> login(String username, String password, {bool rememberMe = false}) async {
    final rows = _db.connection.select(
      'SELECT id, username, password_hash, is_admin, created_at, last_login FROM users WHERE username = ? COLLATE NOCASE',
      [username.trim()],
    );

    if (rows.isEmpty) {
      // Equalise timing so the response time does not reveal whether the user name exists.
      await _verify(password, await (_dummyHash ??= _hash(newId())));
      return null;
    }

    final row = rows.first;
    if (!await _verify(password, row['password_hash'] as String)) return null;

    final now = DateTime.now().toUtc();
    _db.connection.execute('UPDATE users SET last_login = ? WHERE id = ?', [formatIsoUtc(now), row['id']]);

    final user = _toUserInfo(row).copyWith(lastLogin: now);
    final expiry = rememberMe ? const Duration(days: 90) : const Duration(hours: 24);
    return AuthResponse(_generateToken(user, expiry), user, now.add(expiry));
  }

  /// Creates the first administrator. Null if any account already exists (checked atomically).
  Future<AuthResponse?> createAdmin(String username, String password) async {
    final user = _newUser(username, isAdmin: true);
    final hash = await _hash(password);
    _db.connection.execute(
      'INSERT INTO users (id, username, password_hash, is_admin, created_at, last_login) '
      'SELECT ?1, ?2, ?3, 1, ?4, NULL WHERE NOT EXISTS (SELECT 1 FROM users)',
      [user.id, user.username, hash, formatIsoUtc(user.createdAt)],
    );
    if (_db.connection.updatedRows == 0) return null;

    const expiry = Duration(days: 90);
    return AuthResponse(_generateToken(user, expiry), user, DateTime.now().toUtc().add(expiry));
  }

  /// Creates a regular user. Null if the user name is taken (ignoring case).
  Future<UserInfo?> register(String username, String password) async {
    final user = _newUser(username, isAdmin: false);
    final hash = await _hash(password);
    _db.connection.execute(
      'INSERT OR IGNORE INTO users (id, username, password_hash, is_admin, created_at, last_login) '
      'VALUES (?, ?, ?, 0, ?, NULL)',
      [user.id, user.username, hash, formatIsoUtc(user.createdAt)],
    );
    return _db.connection.updatedRows == 0 ? null : user;
  }

  bool userExists(String userId) => _db.connection.select('SELECT 1 FROM users WHERE id = ?', [userId]).isNotEmpty;

  UserInfo? getUser(String userId) {
    final rows = _db.connection.select(
      'SELECT id, username, password_hash, is_admin, created_at, last_login FROM users WHERE id = ?',
      [userId],
    );
    return rows.isEmpty ? null : _toUserInfo(rows.first);
  }

  List<UserInfo> getAllUsers() => _db.connection
      .select('SELECT id, username, password_hash, is_admin, created_at, last_login FROM users ORDER BY username ASC')
      .map(_toUserInfo)
      .toList();

  /// Deletes the account together with its favourites, play statistics and playlists.
  bool deleteUser(String userId) => _db.transaction((db) {
    db.execute('DELETE FROM users WHERE id = ?', [userId]);
    final count = db.updatedRows;
    db.execute('DELETE FROM user_favorites WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM user_plays WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM user_playlists WHERE user_id = ?', [userId]);
    return count > 0;
  });

  /// A token for stream and cover URLs. It never carries the administrator role, and the server refuses it on every
  /// other route, so a URL that leaks (process list, proxy log) cannot manage accounts or the library.
  StreamTokenResponse createStreamToken(String userId, String username) {
    final expires = DateTime.now().toUtc().add(streamTokenLifetime);
    final token = _jwt.sign({
      nameIdClaim: userId,
      nameClaim: username,
      roleClaim: 'user',
      scopeClaim: streamScope,
      'exp': expires.millisecondsSinceEpoch ~/ 1000,
      'iss': issuer,
      'aud': streamAudience,
    });
    return StreamTokenResponse(token, expires);
  }

  /// The identity in [token] when it is valid; null otherwise. Does not check that the account still exists.
  Principal? validate(String token) {
    final claims = _jwt.verify(token, issuer: issuer, audiences: {audience, streamAudience});
    if (claims == null) return null;
    final id = claims[nameIdClaim] ?? claims['nameid'] ?? claims['sub'];
    final name = claims[nameClaim] ?? claims['unique_name'] ?? claims['name'];
    if (id is! String || name is! String) return null;
    final role = claims[roleClaim] ?? claims['role'];
    return Principal(
      id,
      name,
      role is String ? role : (role is List && role.contains('admin') ? 'admin' : 'user'),
      isStreamToken: claims[scopeClaim] == streamScope,
    );
  }

  static UserInfo _newUser(String username, {required bool isAdmin}) =>
      UserInfo(newId(), username.trim(), isAdmin, DateTime.now().toUtc(), null);

  String _generateToken(UserInfo user, Duration expiry) => _jwt.sign({
    nameIdClaim: user.id,
    nameClaim: user.username,
    roleClaim: user.isAdmin ? 'admin' : 'user',
    'exp': DateTime.now().toUtc().add(expiry).millisecondsSinceEpoch ~/ 1000,
    'iss': issuer,
    'aud': audience,
  });

  static UserInfo _toUserInfo(Map<String, Object?> row) => UserInfo(
    row['id'] as String,
    row['username'] as String,
    (row['is_admin'] as int) != 0,
    parseIsoUtc(row['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    parseIsoUtc(row['last_login']),
  );
}

// bcrypt is slow on purpose; it runs in a background isolate so that other requests are not held up meanwhile. The
// isolate entries are top-level so that their closures capture nothing but their arguments.

Future<String> _hashInIsolate(String password, int workFactor) =>
    Isolate.run(() => BCrypt.hashpw(password, BCrypt.gensalt(logRounds: workFactor)));

Future<bool> _verifyInIsolate(String password, String hash) => Isolate.run(() {
  try {
    return BCrypt.checkpw(password, hash);
  } catch (_) {
    return false;
  }
});
