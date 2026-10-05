// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

// The request and response bodies of the server's HTTP API (see docs/api.md): camelCase JSON, dates in ISO 8601.

import '../util/text.dart';
import '../util/time.dart';

class UserInfo {
  const UserInfo(this.id, this.username, this.isAdmin, this.createdAt, this.lastLogin);

  final String id;
  final String username;
  final bool isAdmin;
  final DateTime createdAt;
  final DateTime? lastLogin;

  UserInfo copyWith({DateTime? lastLogin}) => UserInfo(id, username, isAdmin, createdAt, lastLogin ?? this.lastLogin);

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'isAdmin': isAdmin,
    'createdAt': formatIsoUtc(createdAt),
    'lastLogin': lastLogin == null ? null : formatIsoUtc(lastLogin!),
  };

  static UserInfo fromJson(Object? json) {
    final map = _object(json);
    return UserInfo(
      _string(map, 'id'),
      _string(map, 'username'),
      map['isAdmin'] as bool? ?? false,
      parseIsoUtc(map['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      parseIsoUtc(map['lastLogin']),
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
    this.lastScanCompletedUtc,
    this.lastScanError,
  );

  final int trackCount;
  final int albumCount;
  final int artistCount;
  final bool isScanning;
  final DateTime? lastScanCompletedUtc;
  final String? lastScanError;

  Map<String, Object?> toJson() => {
    'trackCount': trackCount,
    'albumCount': albumCount,
    'artistCount': artistCount,
    'isScanning': isScanning,
    'lastScanCompletedUtc': lastScanCompletedUtc == null ? null : formatIsoUtc(lastScanCompletedUtc!),
    'lastScanError': lastScanError,
  };

  static ServerLibraryStatus fromJson(Object? json) {
    final map = _object(json);
    return ServerLibraryStatus(
      (map['trackCount'] as num?)?.toInt() ?? 0,
      (map['albumCount'] as num?)?.toInt() ?? 0,
      (map['artistCount'] as num?)?.toInt() ?? 0,
      map['isScanning'] as bool? ?? false,
      parseIsoUtc(map['lastScanCompletedUtc']),
      map['lastScanError'] as String?,
    );
  }
}

class ServerConfigInfo {
  const ServerConfigInfo(this.libraryPath);

  final String libraryPath;

  Map<String, Object?> toJson() => {'libraryPath': libraryPath};

  static ServerConfigInfo fromJson(Object? json) => ServerConfigInfo(_string(_object(json), 'libraryPath'));
}

/// Play statistics of one track for one account.
class TrackPlayStats {
  const TrackPlayStats(this.trackId, this.playCount, this.lastPlayed);

  final String trackId;
  final int playCount;
  final DateTime? lastPlayed;

  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'playCount': playCount,
    'lastPlayed': lastPlayed == null ? null : formatIsoUtc(lastPlayed!),
  };

  static TrackPlayStats fromJson(Object? json) {
    final map = _object(json);
    return TrackPlayStats(
      map['trackId'] as String? ?? '',
      (map['playCount'] as num?)?.toInt() ?? 0,
      parseIsoUtc(map['lastPlayed']),
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

/// Everything the server keeps for one account besides the account itself: favourites, play statistics and playlists.
class UserDataSnapshot {
  const UserDataSnapshot(this.favorites, this.plays, this.playlists);

  final List<String> favorites;
  final List<TrackPlayStats> plays;
  final List<PlaylistData> playlists;

  Map<String, Object?> toJson() => {
    'favorites': favorites,
    'plays': plays.map((p) => p.toJson()).toList(),
    'playlists': playlists.map((p) => p.toJson()).toList(),
  };

  static UserDataSnapshot fromJson(Object? json) {
    final map = _object(json);
    return UserDataSnapshot(
      _stringList(map['favorites']),
      (map['plays'] as List? ?? const []).map(TrackPlayStats.fromJson).toList(),
      (map['playlists'] as List? ?? const []).map(PlaylistData.fromJson).toList(),
    );
  }
}

/// Limits the server enforces on per-account data.
abstract final class UserDataRules {
  static const int maxIdLength = 128;
  static const int maxPlaylistNameLength = 200;
  static const int maxPlaylistDescriptionLength = 1000;
  static const int maxPlaylistTracks = 20000;
  static const int maxPlaylists = 500;
  static const int maxFavorites = 100000;
  static const int maxTrackStats = 100000;

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
