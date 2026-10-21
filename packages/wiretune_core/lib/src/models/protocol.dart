// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

// The request and response bodies of the server's HTTP API (see docs/api.md): camelCase JSON, dates in ISO 8601.

import '../util/text.dart';
import '../util/time.dart';

class UserInfo {
  const UserInfo(this.id, this.username, this.isAdmin, this.createdAt, this.lastLoginAt);

  final String id;
  final String username;
  final bool isAdmin;
  final DateTime createdAt;
  final DateTime? lastLoginAt;

  UserInfo copyWith({DateTime? lastLoginAt}) =>
      UserInfo(id, username, isAdmin, createdAt, lastLoginAt ?? this.lastLoginAt);

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'isAdmin': isAdmin,
    'createdAt': formatIsoUtc(createdAt),
    'lastLoginAt': lastLoginAt == null ? null : formatIsoUtc(lastLoginAt!),
  };

  static UserInfo fromJson(Object? json) {
    final map = _object(json);
    return UserInfo(
      _string(map, 'id'),
      _string(map, 'username'),
      map['isAdmin'] as bool? ?? false,
      parseIsoUtc(map['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      parseIsoUtc(map['lastLoginAt']),
    );
  }
}

class AuthResponse {
  const AuthResponse(this.token, this.user, this.expiresAt);

  final String token;
  final UserInfo user;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {'token': token, 'user': user.toJson(), 'expiresAt': formatIsoUtc(expiresAt)};

  static AuthResponse fromJson(Object? json) {
    final map = _object(json);
    return AuthResponse(
      _string(map, 'token'),
      UserInfo.fromJson(map['user']),
      parseIsoUtc(map['expiresAt']) ?? DateTime.now().toUtc(),
    );
  }
}

/// A short-lived token that opens only the audio and cover routes. Players put it in stream URLs (which end up in
/// decoder arguments and logs) instead of the sign-in token.
class StreamTokenResponse {
  const StreamTokenResponse(this.token, this.expiresAt);

  final String token;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {'token': token, 'expiresAt': formatIsoUtc(expiresAt)};

  static StreamTokenResponse fromJson(Object? json) {
    final map = _object(json);
    return StreamTokenResponse(_string(map, 'token'), parseIsoUtc(map['expiresAt']) ?? DateTime.now().toUtc());
  }
}

class ServerLibraryStatus {
  const ServerLibraryStatus(
    this.trackCount,
    this.albumCount,
    this.artistCount,
    this.isScanning,
    this.lastScanAt,
    this.lastScanError, [
    this.lastScanProblem,
  ]);

  final int trackCount;
  final int albumCount;
  final int artistCount;
  final bool isScanning;
  final DateTime? lastScanAt;

  /// Why the last scan didn't run or failed, in English; null when it went well (or for anyone but an administrator).
  final String? lastScanError;

  /// The same as a code ([ErrorCodes.folderMissing], [ErrorCodes.folderLooksUnmounted], [ErrorCodes.scanFailed]).
  final String? lastScanProblem;

  Map<String, Object?> toJson() => {
    'trackCount': trackCount,
    'albumCount': albumCount,
    'artistCount': artistCount,
    'isScanning': isScanning,
    'lastScanAt': lastScanAt == null ? null : formatIsoUtc(lastScanAt!),
    'lastScanError': lastScanError,
    'lastScanProblem': lastScanProblem,
  };

  static ServerLibraryStatus fromJson(Object? json) {
    final map = _object(json);
    return ServerLibraryStatus(
      (map['trackCount'] as num?)?.toInt() ?? 0,
      (map['albumCount'] as num?)?.toInt() ?? 0,
      (map['artistCount'] as num?)?.toInt() ?? 0,
      map['isScanning'] as bool? ?? false,
      parseIsoUtc(map['lastScanAt']),
      map['lastScanError'] as String?,
      map['lastScanProblem'] as String?,
    );
  }
}

class ServerConfigInfo {
  const ServerConfigInfo(this.musicFolder);

  final String musicFolder;

  Map<String, Object?> toJson() => {'musicFolder': musicFolder};

  static ServerConfigInfo fromJson(Object? json) => ServerConfigInfo(_string(_object(json), 'musicFolder'));
}

/// Play statistics of one track for one account.
class TrackPlayStats {
  const TrackPlayStats(this.trackId, this.playCount, this.lastPlayedAt);

  final String trackId;
  final int playCount;
  final DateTime? lastPlayedAt;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'playCount': playCount,
    'lastPlayedAt': lastPlayedAt == null ? null : formatIsoUtc(lastPlayedAt!),
  };

  static TrackPlayStats fromJson(Object? json) {
    final map = _object(json);
    return TrackPlayStats(
      map['trackId'] as String? ?? '',
      (map['playCount'] as num?)?.toInt() ?? 0,
      parseIsoUtc(map['lastPlayedAt']),
    );
  }
}

/// A playlist as the server stores it for one account.
class PlaylistData {
  const PlaylistData(this.id, this.name, this.description, this.trackIds, this.createdAt, this.modifiedAt);

  final String id;
  final String name;
  final String? description;
  final List<String> trackIds;
  final DateTime createdAt;
  final DateTime modifiedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'trackIds': trackIds,
    'createdAt': formatIsoUtc(createdAt),
    'modifiedAt': formatIsoUtc(modifiedAt),
  };

  static PlaylistData fromJson(Object? json) {
    final map = _object(json);
    return PlaylistData(
      map['id'] as String? ?? '',
      map['name'] as String? ?? '',
      map['description'] as String?,
      _stringList(map['trackIds']),
      parseIsoUtc(map['createdAt']) ?? DateTime.now().toUtc(),
      parseIsoUtc(map['modifiedAt']) ?? DateTime.now().toUtc(),
    );
  }
}

/// Body of `PUT /api/me/playlists/{id}`: the whole playlist, replacing what the server holds.
class PlaylistUpdate {
  const PlaylistUpdate(this.name, this.description, this.trackIds);

  final String? name;
  final String? description;
  final List<String>? trackIds;

  Map<String, Object?> toJson() => {'name': name, 'description': description, 'trackIds': trackIds};

  static PlaylistUpdate fromJson(Object? json) {
    final map = _object(json);
    final ids = map['trackIds'];
    return PlaylistUpdate(map['name'] as String?, map['description'] as String?, ids == null ? null : _stringList(ids));
  }
}

/// Everything the server keeps for one account besides the account itself: favourites, play statistics, playlists,
/// and hidden items.
/// What kind of thing someone hid: its name is the `{type}` of `/api/me/hidden/{type}/{itemId}`, and what the databases
/// store.
enum HiddenKind {
  artist,
  album,
  track;

  /// The kind called [name]; null for anything else.
  static HiddenKind? parse(Object? name) => values.asNameMap()[name];
}

class UserDataSnapshot {
  const UserDataSnapshot(
    this.favorites,
    this.plays,
    this.playlists, [
    this.favoritedAt = const {},
    this.hiddenArtists = const [],
    this.hiddenAlbums = const [],
    this.hiddenTracks = const [],
  ]);

  /// The favourite track IDs, the earliest marked first.
  final List<String> favorites;
  final List<TrackPlayStats> plays;
  final List<PlaylistData> playlists;

  /// When each favourite was marked (a server from before this field sends none).
  final Map<String, DateTime> favoritedAt;

  /// IDs of artists, albums, and tracks hidden by this user.
  final List<String> hiddenArtists;
  final List<String> hiddenAlbums;
  final List<String> hiddenTracks;

  Map<HiddenKind, List<String>> get hidden => {
    HiddenKind.artist: hiddenArtists,
    HiddenKind.album: hiddenAlbums,
    HiddenKind.track: hiddenTracks,
  };

  Map<String, Object?> toJson() => {
    'favorites': favorites,
    'favoritedAt': {for (final MapEntry(:key, :value) in favoritedAt.entries) key: formatIsoUtc(value)},
    'plays': plays.map((p) => p.toJson()).toList(),
    'playlists': playlists.map((p) => p.toJson()).toList(),
    'hiddenArtists': hiddenArtists,
    'hiddenAlbums': hiddenAlbums,
    'hiddenTracks': hiddenTracks,
  };

  static UserDataSnapshot fromJson(Object? json) {
    final map = _object(json);
    final times = map['favoritedAt'];
    return UserDataSnapshot(
      _stringList(map['favorites']),
      (map['plays'] as List? ?? const []).map(TrackPlayStats.fromJson).toList(),
      (map['playlists'] as List? ?? const []).map(PlaylistData.fromJson).toList(),
      {
        if (times is Map)
          for (final MapEntry(:key, :value) in times.entries)
            if (key is String) key: ?parseIsoUtc(value),
      },
      _stringList(map['hiddenArtists']),
      _stringList(map['hiddenAlbums']),
      _stringList(map['hiddenTracks']),
    );
  }
}

/// Limits the server enforces on per-account data.
/// The `code` of the server's error answers (`{ "error", "code" }`, docs/api.md): what went wrong, for a player to
/// say in the user's language. The `error` beside it is the same in English, for people reading the HTTP exchange.
abstract final class ErrorCodes {
  // Requests
  static const String invalidJson = 'invalidJson';
  static const String bodyTooLarge = 'bodyTooLarge';
  static const String notFound = 'notFound';
  static const String internalError = 'internalError';
  static const String rateLimited = 'rateLimited'; // with retryAfter (seconds)

  // Signing in (401 answers carry one of the first five)
  static const String signInRequired = 'signInRequired';
  static const String tokenInvalid = 'tokenInvalid';
  static const String sessionExpired = 'sessionExpired';
  static const String passwordChanged = 'passwordChanged';
  static const String accountRemoved = 'accountRemoved';
  static const String wrongCredentials = 'wrongCredentials';
  static const String adminOnly = 'adminOnly';
  static const String credentialsRequired = 'credentialsRequired';
  static const String usernameInvalid = 'usernameInvalid'; // with max
  static const String passwordTooShort = 'passwordTooShort'; // with min
  static const String passwordTooLong = 'passwordTooLong'; // with max (bytes)
  static const String alreadySetUp = 'alreadySetUp';
  static const String setupCodeWrong = 'setupCodeWrong';
  static const String usernameTaken = 'usernameTaken';
  static const String userNotFound = 'userNotFound';
  static const String cannotDeleteSelf = 'cannotDeleteSelf';
  static const String cannotResetOwnPassword = 'cannotResetOwnPassword';

  // The music folder (with path where there is one)
  static const String folderRequired = 'folderRequired';
  static const String folderInvalid = 'folderInvalid';
  static const String folderMissing = 'folderMissing';
  static const String folderUnreadable = 'folderUnreadable';
  static const String folderWholeDisk = 'folderWholeDisk';
  static const String folderSystem = 'folderSystem';
  static const String folderServerData = 'folderServerData';
  static const String folderLooksUnmounted = 'folderLooksUnmounted';
  static const String scanFailed = 'scanFailed';

  // The account's data (limits with limit)
  static const String invalidId = 'invalidId';
  static const String invalidItemType = 'invalidItemType';
  static const String favoritesLimit = 'favoritesLimit';
  static const String playCountsLimit = 'playCountsLimit';
  static const String playlistsLimit = 'playlistsLimit';
  static const String hiddenLimit = 'hiddenLimit';
  static const String playlistInvalid = 'playlistInvalid';
  static const String playlistNameRequired = 'playlistNameRequired';
  static const String playlistNameTooLong = 'playlistNameTooLong'; // with max
  static const String playlistDescriptionTooLong = 'playlistDescriptionTooLong'; // with max
  static const String playlistTooManyTracks = 'playlistTooManyTracks'; // with max
  static const String playlistNotFound = 'playlistNotFound';

  // Remote control
  static const String notWebSocket = 'notWebSocket';
  static const String originRefused = 'originRefused';
  static const String tooManyConnections = 'tooManyConnections';
}

/// A rule the server's input broke: the code ([ErrorCodes]), the English text, and the numbers the text names.
class RuleViolation {
  const RuleViolation(this.code, this.message, [this.details = const {}]);

  final String code;
  final String message;
  final Map<String, Object> details;
}

abstract final class UserDataRules {
  static const int maxIdLength = 128;
  static const int maxPlaylistNameLength = 200;
  static const int maxPlaylistDescriptionLength = 1000;
  static const int maxPlaylistTracks = 20000;
  static const int maxPlaylists = 500;
  static const int maxFavorites = 100000;
  static const int maxTrackStats = 100000;
  static const int maxHidden = 50000;

  /// Returns null when [id] is acceptable as a track or playlist ID, otherwise the reason.
  static String? validateId(String? id) {
    if (isBlank(id)) return 'The ID must not be empty.';
    if (id!.length > maxIdLength) return 'The ID must be at most $maxIdLength characters.';
    return hasControlCharacters(id) ? 'The ID must not contain control characters.' : null;
  }
}

abstract final class AuthRules {
  static const int minPasswordLength = 8;

  /// bcrypt silently ignores everything past 72 bytes, so longer passwords are rejected instead of truncated.
  static const int maxPasswordBytes = 72;

  static const int maxUsernameLength = 64;
}

Map<Object?, Object?> _object(Object? json) {
  if (json is Map) return json;
  throw const FormatException('Expected a JSON object.');
}

String _string(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is String) return value;
  throw FormatException("Expected the text field '$key'.");
}

List<String> _stringList(Object? value) => value is List ? value.whereType<String>().toList() : <String>[];
