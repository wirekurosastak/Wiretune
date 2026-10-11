// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'jwt.dart';

/// Who a request comes from: the account as the database has it now, and the kind of token it came with.
class Principal {
  const Principal(this.userId, this.username, {this.isAdmin = false, this.isStreamToken = false, this.expiresAt});

  final String userId;
  final String username;
  final bool isAdmin;

  /// A stream token opens the audio and cover routes and nothing else.
  final bool isStreamToken;

  /// When the token runs out: a connection that outlives a request (remote control) ends then.
  final DateTime? expiresAt;
}

/// What [AuthService.authenticate] found: the account, or why the token doesn't open the API ([ErrorCodes.tokenInvalid],
/// [ErrorCodes.sessionExpired], [ErrorCodes.passwordChanged] or [ErrorCodes.accountRemoved]).
class TokenCheck {
  const TokenCheck.valid(Principal this.principal) : refusal = null;
  const TokenCheck.refused(String this.refusal) : principal = null;

  final Principal? principal;
  final String? refusal;
}

/// Accounts, passwords (bcrypt, work factor 12) and tokens (HS256 JWTs).
class AuthService {
  AuthService(this._db, String signingSecret) : _jwt = Jwt(signingSecret) {
    _db.initializeSchema();
  }

  /// The audience of a sign-in token, which opens the whole API.
  static const String audience = 'wiretune';

  /// The audience of a stream token: short-lived, put into audio and cover URLs, and refused everywhere else.
  static const String streamAudience = 'wiretune-stream';

  /// Long enough for a multi-hour track to be seeked in; the player asks for a new one well before that.
  static const Duration streamTokenLifetime = Duration(hours: 8);

  /// A sign-in without "stay signed in", and one with it (the first administrator's is one with it).
  static const Duration _sessionLifetime = Duration(hours: 24);
  static const Duration _rememberedLifetime = Duration(days: 90);
  static const int _bcryptWorkFactor = 12;

  final DatabaseManager _db;
  final Jwt _jwt;
  Future<String>? _dummyHash;

  /// 64 random bytes, Base64: the key tokens are signed with (kept in the server's database).
  static String generateSecret() {
    final random = Random.secure();
    return base64.encode(List<int>.generate(64, (_) => random.nextInt(256)));
  }

  /// Null when [username] and [password] may be used for an account, otherwise the rule they break.
  static RuleViolation? validateCredentials(String? username, String? password) {
    if (isBlank(username) || password == null || password.isEmpty) {
      return const RuleViolation(ErrorCodes.credentialsRequired, 'Username and password are required.');
    }
    final trimmed = username!.trim();
    if (trimmed.length > AuthRules.maxUsernameLength || hasControlCharacters(trimmed)) {
      return const RuleViolation(
        ErrorCodes.usernameInvalid,
        'Username must be at most ${AuthRules.maxUsernameLength} printable characters.',
        {'max': AuthRules.maxUsernameLength},
      );
    }
    return validatePassword(password);
  }

  /// Null when [password] may be used, otherwise the rule it breaks.
  static RuleViolation? validatePassword(String password) {
    if (password.length < AuthRules.minPasswordLength) {
      return const RuleViolation(
        ErrorCodes.passwordTooShort,
        'Password must be at least ${AuthRules.minPasswordLength} characters.',
        {'min': AuthRules.minPasswordLength},
      );
    }
    if (utf8.encode(password).length > AuthRules.maxPasswordBytes) {
      return const RuleViolation(
        ErrorCodes.passwordTooLong,
        'Password must be at most ${AuthRules.maxPasswordBytes} bytes.',
        {'max': AuthRules.maxPasswordBytes},
      );
    }
    return null;
  }

  /// Sets a new password when [current] is the caller's present one, and ends every session signed in before: their
  /// tokens are refused from now on. The caller gets a new token in exchange for theirs, valid as long as the old one
  /// was. Null when [current] is wrong (or the account is gone).
  Future<AuthResponse?> changePassword(Principal caller, String current, String replacement) async {
    final rows = _db.connection.select('SELECT password_hash FROM users WHERE id = ?', [caller.userId]);
    if (rows.isEmpty || !await _verify(current, rows.first['password_hash'] as String)) return null;
    final version = _setPasswordHash(caller.userId, await _hash(replacement));
    final user = version == null ? null : getUser(caller.userId);
    if (user == null) return null;
    final expires = caller.expiresAt ?? DateTime.now().toUtc().add(_sessionLifetime);
    return AuthResponse(_signInToken(user, version!, expires), user, expires);
  }

  /// Sets a new password for [userId] (an administrator's reset) and ends every session of the account. False when
  /// there is no such account.
  Future<bool> resetPassword(String userId, String replacement) async {
    if (!userExists(userId)) return false;
    return _setPasswordHash(userId, await _hash(replacement)) != null;
  }

  /// Stores [hash] and moves the account to a new token version; returns that version, or null without the account.
  int? _setPasswordHash(String userId, String hash) => _db.transaction((db) {
    db.execute('UPDATE users SET password_hash = ?, token_version = token_version + 1 WHERE id = ?', [hash, userId]);
    if (db.updatedRows == 0) return null;
    return db.select('SELECT token_version FROM users WHERE id = ?', [userId]).first['token_version'] as int;
  });

  bool hasAnyUsers() => (_db.connection.select('SELECT COUNT(*) AS n FROM users').first['n'] as int) > 0;

  Future<AuthResponse?> login(String username, String password, {bool rememberMe = false}) async {
    final rows = _db.connection.select(
      'SELECT id, username, password_hash, is_admin, created_at, last_login, token_version FROM users '
      'WHERE username = ? COLLATE NOCASE',
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
    _db.connection.execute('UPDATE users SET last_login = ? WHERE id = ?', [toDbTime(now), row['id']]);

    final user = _toUserInfo(row).copyWith(lastLogin: now);
    final expires = now.add(rememberMe ? _rememberedLifetime : _sessionLifetime);
    return AuthResponse(_signInToken(user, row['token_version'] as int, expires), user, expires);
  }

  /// Creates the first administrator. Null if any account already exists (checked atomically).
  Future<AuthResponse?> createAdmin(String username, String password) async {
    final user = _newUser(username, isAdmin: true);
    final hash = await _hash(password);
    _db.connection.execute(
      'INSERT INTO users (id, username, password_hash, is_admin, created_at, last_login) '
      'SELECT ?1, ?2, ?3, 1, ?4, NULL WHERE NOT EXISTS (SELECT 1 FROM users)',
      [user.id, user.username, hash, toDbTime(user.createdAt)],
    );
    if (_db.connection.updatedRows == 0) return null;

    final expires = DateTime.now().toUtc().add(_rememberedLifetime);
    return AuthResponse(_signInToken(user, 0, expires), user, expires);
  }

  /// Creates a regular user. Null if the user name is taken (ignoring case).
  Future<UserInfo?> register(String username, String password) async {
    final user = _newUser(username, isAdmin: false);
    final hash = await _hash(password);
    _db.connection.execute(
      'INSERT OR IGNORE INTO users (id, username, password_hash, is_admin, created_at, last_login) '
      'VALUES (?, ?, ?, 0, ?, NULL)',
      [user.id, user.username, hash, toDbTime(user.createdAt)],
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

  /// Deletes the account together with its favourites, play statistics, playlists and hidden items.
  bool deleteUser(String userId) => _db.transaction((db) {
    db.execute('DELETE FROM users WHERE id = ?', [userId]);
    final count = db.updatedRows;
    db.execute('DELETE FROM user_favorites WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM user_plays WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM user_playlists WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM user_hidden WHERE user_id = ?', [userId]);
    return count > 0;
  });

  /// A token for stream and cover URLs for the signed-in [caller]. The server refuses it on every route but those, so a
  /// URL that leaks (process list, proxy log) cannot manage accounts or the library; and like every token it stops
  /// working when the account's password changes.
  StreamTokenResponse createStreamToken(Principal caller) {
    final version = _tokenVersion(caller.userId) ?? 0;
    final expires = DateTime.now().toUtc().add(streamTokenLifetime);
    return StreamTokenResponse(_sign(caller.userId, caller.username, streamAudience, version, expires), expires);
  }

  /// The account behind [token], when the token still stands: this server signed it, it has not expired, its account
  /// exists, and it was issued since that account's password last changed. The name and the role are the account's
  /// present ones, never what the token was issued with. Otherwise why not, in that order.
  TokenCheck authenticate(String token) {
    final claims = _jwt.verifySigned(token, audiences: const {audience, streamAudience});
    final id = claims?['sub'];
    if (claims == null || id is! String) return const TokenCheck.refused(ErrorCodes.tokenInvalid);
    if (Jwt.isExpired(claims)) return const TokenCheck.refused(ErrorCodes.sessionExpired);
    final rows = _db.connection.select('SELECT username, is_admin, token_version FROM users WHERE id = ?', [id]);
    if (rows.isEmpty) return const TokenCheck.refused(ErrorCodes.accountRemoved);
    final row = rows.first;
    // Tokens from before token versions existed carry none, which stands for the first one.
    final version = claims['ver'];
    if ((version is int ? version : 0) != row['token_version']) {
      return const TokenCheck.refused(ErrorCodes.passwordChanged);
    }
    return TokenCheck.valid(
      Principal(
        id,
        row['username'] as String,
        isAdmin: (row['is_admin'] as int) != 0,
        isStreamToken: claims['aud'] == streamAudience,
        expiresAt: DateTime.fromMillisecondsSinceEpoch((claims['exp'] as int) * 1000, isUtc: true),
      ),
    );
  }

  int? _tokenVersion(String userId) =>
      _db.connection.select('SELECT token_version FROM users WHERE id = ?', [userId]).firstOrNull?['token_version']
          as int?;

  static UserInfo _newUser(String username, {required bool isAdmin}) =>
      UserInfo(newId(), username.trim(), isAdmin, DateTime.now().toUtc(), null);

  String _signInToken(UserInfo user, int version, DateTime expires) =>
      _sign(user.id, user.username, audience, version, expires);

  String _sign(String userId, String username, String audience, int version, DateTime expires) => _jwt.sign({
    'sub': userId,
    'name': username,
    'aud': audience,
    'ver': version,
    'exp': expires.millisecondsSinceEpoch ~/ 1000,
  });

  static UserInfo _toUserInfo(Map<String, Object?> row) => UserInfo(
    row['id'] as String,
    row['username'] as String,
    (row['is_admin'] as int) != 0,
    fromDbTime(row['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    fromDbTime(row['last_login']),
  );
}

// bcrypt is slow on purpose; it runs in a background isolate so that other requests are not held up meanwhile. The
// isolate entries are top-level so that their closures capture nothing but their arguments.

Future<String> _hash(String password) =>
    Isolate.run(() => BCrypt.hashpw(password, BCrypt.gensalt(logRounds: AuthService._bcryptWorkFactor)));

Future<bool> _verify(String password, String hash) => Isolate.run(() {
  try {
    return BCrypt.checkpw(password, hash);
  } catch (_) {
    return false;
  }
});
