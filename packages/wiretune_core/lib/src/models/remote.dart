// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

// The messages of remote control (`GET /api/remote`, see docs/api.md#remote-control): the players of one account tell
// each other what they play, and send each other commands, through the server.

import '../util/text.dart';
import 'library_models.dart';
import 'protocol.dart';

/// What kind of player a device is; the others show it with a matching icon.
enum DeviceKind {
  desktop,
  phone,
  tablet,
  tv,

  /// A streamer on the network that isn't a Wiretune player (UPnP): it plays the server's tracks it is given.
  streamer;

  /// The kind [value] names; a desktop for anything else.
  static DeviceKind parse(Object? value) => values.asNameMap()[value] ?? desktop;
}

/// The limits of remote control, which the server enforces.
/// Whether a player lets the server's other accounts play on it (casting to it), and what: none ([off]), only music its
/// own account doesn't hide ([unhidden]), or [any] music. Its own account's players always may.
enum DeviceSharing {
  off,
  unhidden,
  any;

  /// The sharing [value] names; [off] for anything else.
  static DeviceSharing parse(Object? value) => values.asNameMap()[value] ?? off;
}

abstract final class RemoteRules {
  /// The longest message (in characters) either side accepts; a longer one closes the connection.
  static const int maxMessageLength = 64 * 1024;
  static const int maxDeviceNameLength = 64;

  /// The most queue entries a state or a "play these" command carries.
  static const int maxQueueLength = 1000;
  static const int maxDevicesPerAccount = 20;

  /// Listening together: the most players that follow one, and the most accounts it invites.
  static const int maxListeners = 20;
  static const int maxListenInvites = 50;

  /// How long listening together waits for its host to come back after its connection dropped.
  static const Duration listenHostGrace = Duration(seconds: 20);

  /// How often each side pings the other, so that a connection that died is noticed.
  static const Duration pingInterval = Duration(seconds: 25);

  /// The close codes after which reconnecting would not help: this device connected again from elsewhere, the account
  /// has too many devices connected, or the sign-in ended.
  static const int closeReplaced = 4000;
  static const int closeTooManyDevices = 4001;
  static const int closeSignedOut = 4401;

  /// The header a player names itself in (its remote-control device ID) when it changes the account's data, so that the
  /// server tells only the account's other players.
  static const String deviceHeader = 'X-Wiretune-Device';

  /// [value] as a device name: without control characters, trimmed, at most [maxDeviceNameLength] characters.
  static String cleanName(Object? value) {
    if (value is! String) return '';
    final text = withoutControlCharacters(value).trim();
    return text.length <= maxDeviceNameLength ? text : text.substring(0, maxDeviceNameLength).trim();
  }
}

/// Another player of the signed-in account, as the server reports it.
class RemoteDevice {
  RemoteDevice(this.id, this.name, this.kind, {this.account});

  final String id;

  /// The name its user gave it; may be empty.
  final String name;
  final DeviceKind kind;

  /// Whose it is, when it is another account's (one that lets others play on it, [DeviceSharing]); null for this
  /// account's own.
  final AccountInfo? account;

  /// What it plays, and when that arrived here (the position counts on from then while it plays).
  RemotePlayback? playback;
  DateTime? playbackReceivedAt;
}

/// What a player plays, and how, as it tells the other players of the account.
class RemotePlayback {
  const RemotePlayback({
    this.track,
    this.playing = false,
    this.position = Duration.zero,
    this.volume = 100,
    this.muted = false,
    this.volumeLocked = false,
    this.shuffle = false,
    this.repeat = RepeatMode.off,
    this.queue = const [],
    this.queueIndex = -1,
    this.playingFor,
  });

  final Track? track;
  final bool playing;

  /// The position at the moment the state was sent.
  final Duration position;

  /// 0 to 100.
  final double volume;
  final bool muted;

  /// Bit-perfect playback holds the volume at 100 %.
  final bool volumeLocked;
  final bool shuffle;
  final RepeatMode repeat;

  /// The IDs of the queue (at most [RemoteRules.maxQueueLength], around the current entry), and the current one's
  /// index in it; -1 for none.
  final List<String> queue;
  final int queueIndex;

  /// The ID of the account whose music plays, when another account cast it to the device; null for the device's own.
  /// That account's player counts its plays.
  final String? playingFor;

  Map<String, Object?> toJson() => {
    'track': track?.toJson(),
    'playing': playing,
    'positionMs': position.inMilliseconds,
    'volume': volume,
    'muted': muted,
    'volumeLocked': volumeLocked,
    'shuffle': shuffle,
    'repeat': repeat.name,
    'queue': queue,
    'queueIndex': queueIndex,
    if (playingFor != null) 'playingFor': playingFor,
  };

  /// Null when [json] is not a playback state.
  static RemotePlayback? fromJson(Object? json) {
    if (json is! Map) return null;
    Track? track;
    if (json['track'] != null) {
      try {
        track = Track.fromJson(json['track']);
      } on FormatException {
        return null;
      }
    }
    final queue = _ids(json['queue']);
    final position = json['positionMs'];
    final volume = json['volume'];
    final index = json['queueIndex'];
    if (queue == null || position is! int || volume is! num || index is! int) return null;
    return RemotePlayback(
      track: track,
      playing: json['playing'] == true,
      position: Duration(milliseconds: position.clamp(0, 1 << 40)),
      volume: volume.toDouble().clamp(0, 100),
      muted: json['muted'] == true,
      volumeLocked: json['volumeLocked'] == true,
      shuffle: json['shuffle'] == true,
      repeat: RepeatMode.values.asNameMap()[json['repeat']] ?? RepeatMode.off,
      queue: queue,
      queueIndex: index >= 0 && index < queue.length ? index : -1,
      playingFor: json['playingFor'] is String ? json['playingFor'] as String : null,
    );
  }
}

/// What one player can ask another to do.
enum RemoteAction {
  play,
  pause,
  toggle,
  stop,
  next,
  previous,
  seek,
  volume,
  mute,
  shuffle,
  repeat,
  playTracks,
  playIndex,
  moveTrack,
  removeTrack,
  clearQueue,

  /// [RemoteCommand.trackIds] go right after the current track.
  playNext,

  /// [RemoteCommand.trackIds] go to the end of the queue.
  addToQueue,
}

/// A command for another player. Each action reads only its own fields: [position] (seek; where playTracks starts),
/// [volume] (0 to 100), [on] (mute, shuffle), [repeat], [trackIds] (playTracks, playNext, addToQueue) and [index]
/// (playTracks, where -1 lets the player choose the first track as it would itself; playIndex; moveTrack from-index;
/// removeTrack index), and [toIndex] (moveTrack to-index).
class RemoteCommand {
  const RemoteCommand(
    this.action, {
    this.position = Duration.zero,
    this.volume = 0,
    this.on = false,
    this.repeat = RepeatMode.off,
    this.trackIds = const [],
    this.index = 0,
    this.toIndex = 0,
  });

  final RemoteAction action;
  final Duration position;
  final double volume;
  final bool on;
  final RepeatMode repeat;
  final List<String> trackIds;
  final int index;
  final int toIndex;

  Map<String, Object?> toJson() => {
    'action': action.name,
    if (action == RemoteAction.seek || action == RemoteAction.playTracks) 'positionMs': position.inMilliseconds,
    if (action == RemoteAction.volume) 'volume': volume,
    if (action == RemoteAction.mute || action == RemoteAction.shuffle) 'on': on,
    if (action == RemoteAction.repeat) 'repeat': repeat.name,
    if (action == RemoteAction.playTracks || action == RemoteAction.playNext || action == RemoteAction.addToQueue)
      'trackIds': trackIds,
    if (action == RemoteAction.playTracks ||
        action == RemoteAction.playIndex ||
        action == RemoteAction.moveTrack ||
        action == RemoteAction.removeTrack)
      'index': index,
    if (action == RemoteAction.moveTrack) 'toIndex': toIndex,
  };

  /// Null when [json] is not a command this player understands.
  static RemoteCommand? fromJson(Object? json) {
    if (json is! Map) return null;
    final action = RemoteAction.values.asNameMap()[json['action']];
    if (action == null) return null;
    final position = json['positionMs'];
    final volume = json['volume'];
    final on = json['on'];
    final index = json['index'];
    final toIndex = json['toIndex'];
    switch (action) {
      case RemoteAction.seek:
        if (position is! int || position < 0) return null;
        return RemoteCommand(action, position: Duration(milliseconds: position));
      case RemoteAction.volume:
        if (volume is! num || volume.isNaN) return null;
        return RemoteCommand(action, volume: volume.toDouble().clamp(0, 100));
      case RemoteAction.mute || RemoteAction.shuffle:
        return on is bool ? RemoteCommand(action, on: on) : null;
      case RemoteAction.repeat:
        final mode = RepeatMode.values.asNameMap()[json['repeat']];
        return mode == null ? null : RemoteCommand(action, repeat: mode);
      case RemoteAction.playTracks:
        final ids = _ids(json['trackIds']);
        if (ids == null || ids.isEmpty || index is! int || index < -1 || index >= ids.length) return null;
        if (position is! int || position < 0) return null;
        return RemoteCommand(
          action,
          trackIds: ids,
          index: index,
          position: Duration(milliseconds: position),
        );
      case RemoteAction.playIndex:
        return index is int && index >= 0 ? RemoteCommand(action, index: index) : null;
      case RemoteAction.moveTrack:
        return index is int && index >= 0 && toIndex is int && toIndex >= 0
            ? RemoteCommand(action, index: index, toIndex: toIndex)
            : null;
      case RemoteAction.removeTrack:
        return index is int && index >= 0 ? RemoteCommand(action, index: index) : null;
      case RemoteAction.clearQueue:
        return RemoteCommand(action);
      case RemoteAction.playNext || RemoteAction.addToQueue:
        final ids = _ids(json['trackIds']);
        return ids == null || ids.isEmpty ? null : RemoteCommand(action, trackIds: ids);
      default:
        return RemoteCommand(action);
    }
  }
}

/// A list of track IDs within the limits, or null when [value] is not one.
List<String>? _ids(Object? value) {
  if (value is! List || value.length > RemoteRules.maxQueueLength) return null;
  final ids = <String>[];
  for (final id in value) {
    if (id is! String || UserDataRules.validateId(id) != null) return null;
    ids.add(id);
  }
  return ids;
}

// ── Listening together ──────────────────────────────────────────────────────────────────────────

/// A player in a group listening together: whose it is and what it is called.
class ListeningDevice {
  const ListeningDevice(this.accountId, this.username, this.deviceId, this.deviceName);

  final String accountId;
  final String username;
  final String deviceId;
  final String deviceName;

  static ListeningDevice fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Expected a player.');
    final (accountId, username, deviceId) = (json['accountId'], json['username'], json['deviceId']);
    if (accountId is! String || username is! String || deviceId is! String) {
      throw const FormatException('A player needs its account and device.');
    }
    return ListeningDevice(accountId, username, deviceId, RemoteRules.cleanName(json['deviceName']));
  }
}

/// Players listening together: the [host]'s music plays on the [members]' players too.
class ListeningGroup {
  const ListeningGroup(this.id, this.host, this.members);

  final String id;
  final ListeningDevice host;
  final List<ListeningDevice> members;

  /// Null for null (no group) and for anything that is not a group.
  static ListeningGroup? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String || json['members'] is! List) return null;
    try {
      return ListeningGroup(json['id'] as String, ListeningDevice.fromJson(json['host']), [
        for (final member in json['members'] as List) ListeningDevice.fromJson(member),
      ]);
    } on FormatException {
      return null;
    }
  }
}

/// An open invite to listen together: the group, and the account that hosts it.
class ListeningInvite {
  const ListeningInvite(this.groupId, this.host);

  final String groupId;
  final AccountInfo host;
}

/// What the host of a group plays, as its members follow it: the queue (at most [RemoteRules.maxQueueLength] IDs around
/// the current entry, -1 for none), whether it plays, and where it was at [at], by the server's clock.
class ListeningState {
  const ListeningState({
    required this.queue,
    required this.queueIndex,
    required this.playing,
    required this.position,
    required this.at,
  });

  final List<String> queue;
  final int queueIndex;
  final bool playing;
  final Duration position;
  final DateTime at;

  String? get trackId => queueIndex >= 0 && queueIndex < queue.length ? queue[queueIndex] : null;

  /// Where the host is at [now] (by the server's clock): counted on from [at] while it plays.
  Duration positionAt(DateTime now) {
    if (!playing) return position;
    final since = now.difference(at);
    return since.isNegative ? position : position + since;
  }

  Map<String, Object?> toJson() => {
    'queue': queue,
    'queueIndex': queueIndex,
    'playing': playing,
    'positionMs': position.inMilliseconds,
    'at': at.millisecondsSinceEpoch,
  };

  /// Null when [json] is not a state.
  static ListeningState? fromJson(Object? json) {
    if (json is! Map) return null;
    final queue = _ids(json['queue']);
    final (index, position, at) = (json['queueIndex'], json['positionMs'], json['at']);
    if (queue == null || index is! int || position is! int || position < 0 || at is! int) return null;
    return ListeningState(
      queue: queue,
      queueIndex: index >= 0 && index < queue.length ? index : -1,
      playing: json['playing'] == true,
      position: Duration(milliseconds: position.clamp(0, 1 << 40)),
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }
}
