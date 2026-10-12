// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/protocol.dart';
import '../models/remote.dart';
import '../util/event.dart';
import 'server_session.dart';
import 'wiretune_log.dart';

/// One connection to the server's remote-control hub: text messages both ways.
class RemoteChannel {
  RemoteChannel({required this.messages, required this.send, required this.close, required this.closeCode});

  /// What the server sends; done when the connection closes.
  final Stream<Object?> messages;
  final void Function(String message) send;
  final Future<void> Function() close;

  /// The close code the server gave, once the connection is closed.
  final int? Function() closeCode;
}

/// Opens a [RemoteChannel] to [uri], signed in with [token]. Throws [RemoteRefusedException] when the server refuses
/// the token or has no remote control.
typedef RemoteConnector = Future<RemoteChannel> Function(Uri uri, String token);

class RemoteRefusedException implements Exception {
  const RemoteRefusedException(this.message, [this.statusCode]);

  final String message;

  /// The HTTP status of the refusal: 404 from a server without remote control, 401 or 403 for the token.
  final int? statusCode;

  @override
  String toString() => message;
}

/// Why remote control isn't running although it is switched on and the session is signed in.
enum RemoteProblem {
  /// The server has no remote control (an older version).
  unsupported,

  /// The account has as many devices connected as it may.
  tooManyDevices,

  /// The same device connected again over another connection, which took over.
  replaced,

  /// The server ended it: the sign-in no longer stands, or it didn't accept a message.
  ended,
}

/// This player's link to the other players of the signed-in account (docs/api.md#remote-control): it tells them what
/// plays here, learns what plays there, and carries commands both ways. It is connected while it is enabled and the
/// session is signed in, and reconnects, waiting longer each time, when the connection drops.
class RemoteClient {
  RemoteClient(this._session, {RemoteConnector? connector}) : _connector = connector ?? _connectWebSocket {
    _unsubscribe = _session.stateChanged.listen((_) => _update());
  }

  static const Duration _firstRetry = Duration(seconds: 2);
  static const Duration _lastRetry = Duration(minutes: 1);
  static const Duration _publishInterval = Duration(milliseconds: 150);

  /// Closed for good: see [RemoteRules.closeReplaced]; 1008 and 1009 say the server did not accept a message, which
  /// sending it again would not change.
  static const Set<int> _final = {
    RemoteRules.closeReplaced,
    RemoteRules.closeTooManyDevices,
    RemoteRules.closeSignedOut,
    1008,
    1009,
  };

  final ServerSession _session;
  final RemoteConnector _connector;
  late final void Function() _unsubscribe;

  String _deviceId = '';
  String _deviceName = '';
  DeviceKind _deviceKind = DeviceKind.desktop;
  bool _enabled = false;

  RemoteChannel? _channel;
  String? _channelUrl;
  bool _connecting = false;
  (String url, String token)? _refusedFor;
  Timer? _retry;
  Duration _retryDelay = _firstRetry;
  final Map<String, RemoteDevice> _devices = {};
  RemotePlayback? _playback;
  Timer? _publishTimer;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  /// Raised when a device comes or goes or tells what it plays, and when the connection opens or closes.
  final Event<void> devicesChanged = Event<void>();

  /// A command from another player, for this one.
  final Event<(String from, RemoteCommand command)> commandReceived = Event();

  /// The account's favourites, playlists or hidden items may have changed elsewhere: another player changed them, or
  /// the connection was lost for a while (and with it what was said meanwhile).
  final Event<void> accountDataChanged = Event<void>();
  bool _connectedBefore = false;

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  bool get isEnabled => _enabled;
  bool get isConnected => _channel != null;

  /// The other players of the account that are online.
  List<RemoteDevice> get devices => List.unmodifiable(_devices.values);

  RemoteDevice? device(String id) => _devices[id];

  /// Why it isn't connected although it should be; null while it is, or is trying to be. Told through [devicesChanged].
  RemoteProblem? get problem => _problem;
  RemoteProblem? _problem;

  void _setProblem(RemoteProblem? problem) {
    if (_problem == problem) return;
    _problem = problem;
    devicesChanged.emit(null);
  }

  /// Who this player is and whether it takes part; connects or disconnects as needed.
  void configure({required String id, required String name, required DeviceKind kind, required bool enabled}) {
    final changed = id != _deviceId || name != _deviceName || kind != _deviceKind;
    _deviceId = id;
    _deviceName = RemoteRules.cleanName(name);
    _deviceKind = kind;
    _enabled = enabled;
    if (changed && _channel != null) _sendHello();
    _update();
  }

  /// Tells the other players what plays here. Sent at most every 150 ms (the latest state winning), and again after a
  /// reconnection.
  void publish(RemotePlayback playback) {
    _playback = playback;
    if (_channel == null) return;
    final wait = _publishInterval - DateTime.now().difference(_lastPublish);
    if (wait <= Duration.zero) {
      _sendState(playback);
    } else {
      _publishTimer ??= Timer(wait, () {
        _publishTimer = null;
        final latest = _playback;
        if (latest != null && _channel != null) _sendState(latest);
      });
    }
  }

  /// Sends [command] to the player [deviceId]; false when it is not online.
  bool send(String deviceId, RemoteCommand command) {
    if (_channel == null || !_devices.containsKey(deviceId)) return false;
    _send({'type': 'command', 'to': deviceId, 'command': command.toJson()});
    return true;
  }

  // ── The connection ─────────────────────────────────────────────────────────────────────────────

  void _update() {
    if (_disposed) return;
    final token = _session.authToken;
    final url = _session.serverUrl;
    if (!_enabled || _deviceId.isEmpty || !_session.isLoggedIn || token == null || token.isEmpty) {
      _disconnect();
      return;
    }
    if (_channel != null && _channelUrl != url) _disconnect(); // another server now
    if (_channel != null || _connecting || _retry != null || _refusedFor == (url, token)) return;
    unawaited(_connect(url, token));
  }

  Future<void> _connect(String url, String token) async {
    _connecting = true;
    RemoteChannel channel;
    try {
      channel = await _connector(_remoteUri(url), token);
    } on RemoteRefusedException catch (e) {
      _connecting = false;
      WiretuneLog.warn('RemoteClient', 'The server refused remote control: $e');
      if (e.statusCode == 429) {
        // The account's connections are all taken; one may close, so asked again later.
        _setProblem(RemoteProblem.tooManyDevices);
        _retryLater();
        return;
      }
      _refusedFor = (url, token);
      _setProblem(e.statusCode == 404 ? RemoteProblem.unsupported : RemoteProblem.ended);
      return;
    } catch (e) {
      _connecting = false;
      WiretuneLog.debug('RemoteClient', 'Could not connect for remote control: $e');
      _retryLater();
      return;
    }
    _connecting = false;
    if (_disposed || !_enabled || !_session.isLoggedIn || _session.serverUrl != url) {
      await channel.close();
      _update();
      return;
    }
    _channel = channel;
    _channelUrl = url;
    _setProblem(null);
    channel.messages.listen(_onMessage, onDone: () => _onClosed(channel, url, token), onError: (Object _) {});
    _sendHello();
    final playback = _playback;
    if (playback != null) _sendState(playback);
    if (_connectedBefore) accountDataChanged.emit(null);
    _connectedBefore = true;
  }

  void _onClosed(RemoteChannel channel, String url, String token) {
    if (!identical(_channel, channel)) return;
    _channel = null;
    _channelUrl = null;
    _devices.clear();
    devicesChanged.emit(null);
    final code = channel.closeCode();
    if (_final.contains(code)) {
      // Until the session signs in again (or to another server): retrying would only be refused again.
      _refusedFor = (url, token);
      _setProblem(switch (code) {
        RemoteRules.closeReplaced => RemoteProblem.replaced,
        RemoteRules.closeTooManyDevices => RemoteProblem.tooManyDevices,
        _ => RemoteProblem.ended,
      });
      WiretuneLog.info('RemoteClient', 'The server ended remote control (code $code).');
      // A password change ends the connection and hands the session a new token at about the same time: with that
      // one, connect again.
      _update();
      return;
    }
    _retryLater();
  }

  void _retryLater() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(_retryDelay, () {
      _retry = null;
      _update();
    });
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > _lastRetry ? _lastRetry : doubled;
  }

  void _disconnect() {
    _retry?.cancel();
    _retry = null;
    _publishTimer?.cancel();
    _publishTimer = null;
    _setProblem(null); // switched off, signed out or another server: what went wrong before no longer applies
    final channel = _channel;
    _channel = null;
    _channelUrl = null;
    if (channel == null && _devices.isEmpty) return;
    if (channel != null) unawaited(channel.close());
    _devices.clear();
    devicesChanged.emit(null);
  }

  static Uri _remoteUri(String serverUrl) {
    final base = Uri.parse(serverUrl);
    final cleanPath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '$cleanPath/api/remote');
  }

  /// The real connection: a WebSocket with the token in its header (never in the URL), pinged so that a dead
  /// connection is noticed.
  static Future<RemoteChannel> _connectWebSocket(Uri uri, String token) async {
    WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
    } on WebSocketException catch (e) {
      // The token turned away, or a server from before remote control: asking again would not change the answer.
      final status = e.httpStatusCode;
      if (status == 401 || status == 403 || status == 404) throw RemoteRefusedException(e.message, status);
      if (status == 429) throw RemoteRefusedException(e.message, status);
      rethrow;
    }
    socket.pingInterval = RemoteRules.pingInterval;
    return RemoteChannel(messages: socket, send: socket.add, close: socket.close, closeCode: () => socket.closeCode);
  }

  // ── Messages ───────────────────────────────────────────────────────────────────────────────────

  void _sendHello() => _send({
    'type': 'hello',
    'device': {'id': _deviceId, 'name': _deviceName, 'kind': _deviceKind.name},
  });

  void _sendState(RemotePlayback playback) {
    _lastPublish = DateTime.now();
    _send({'type': 'state', 'state': playback.toJson()});
  }

  void _send(Map<String, Object?> message) {
    final text = jsonEncode(message);
    if (text.length > RemoteRules.maxMessageLength) {
      WiretuneLog.warn('RemoteClient', "A '${message['type']}' message was too long to send.");
      return;
    }
    try {
      _channel?.send(text);
    } catch (e) {
      WiretuneLog.debug('RemoteClient', 'Sending failed: $e'); // the connection is closing; the close handles it
    }
  }

  void _onMessage(Object? data) {
    if (data is! String || data.length > RemoteRules.maxMessageLength) return;
    Object? message;
    try {
      message = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    switch (message['type']) {
      case 'devices':
        _onDevices(message['devices']);
      case 'state':
        _onState(message['device'], message['state']);
      case 'command':
        _onCommand(message['from'], message['command']);
      case 'dataChanged':
        accountDataChanged.emit(null);
    }
  }

  void _onDevices(Object? list) {
    if (list is! List) return;
    _retryDelay = _firstRetry; // the server took this player in
    final online = <String, RemoteDevice>{};
    for (final entry in list) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || UserDataRules.validateId(id) != null || id == _deviceId) continue;
      final device = RemoteDevice(id, RemoteRules.cleanName(entry['name']), DeviceKind.parse(entry['kind']));
      final known = _devices[id];
      if (known != null) {
        device
          ..playback = known.playback
          ..playbackReceivedAt = known.playbackReceivedAt;
      }
      online[id] = device;
    }
    _devices
      ..clear()
      ..addAll(online);
    devicesChanged.emit(null);
  }

  void _onState(Object? id, Object? state) {
    final device = id is String ? _devices[id] : null;
    final playback = RemotePlayback.fromJson(state);
    if (device == null || playback == null) return;
    device
      ..playback = playback
      ..playbackReceivedAt = DateTime.now();
    devicesChanged.emit(null);
  }

  void _onCommand(Object? from, Object? json) {
    final command = RemoteCommand.fromJson(json);
    if (from is! String || !_devices.containsKey(from) || command == null) return;
    commandReceived.emit((from, command));
  }

  void dispose() {
    _disposed = true;
    _unsubscribe();
    _disconnect();
  }
}
