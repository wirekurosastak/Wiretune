// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../models/remote.dart';
import 'library_service.dart';
import 'remote_client.dart';
import 'server_session.dart';
import 'upnp.dart';
import 'wiretune_log.dart';

/// The streamers on the network (UPnP renderers: hi-fi streamers, amplifiers), among the devices this player plays on
/// ([RemoteClient.addLocal]) while it is signed in: they play the server's tracks straight from the server, in their
/// original quality. Found by [search], which runs at each sign-in too; a streamer that stops answering goes from the
/// list.
class Streamers {
  Streamers(this._remote, this._session, this._library, this._upnp) {
    _unsubscribe = _session.stateChanged.listen((_) {
      final signedIn = _session.isLoggedIn;
      if (signedIn == _signedIn) return;
      _signedIn = signedIn;
      signedIn ? unawaited(search()) : _forgetAll();
    });
  }

  bool _signedIn = false;

  final RemoteClient _remote;
  final ServerSession _session;
  final LibraryService _library;
  final UpnpClient _upnp;
  late final void Function() _unsubscribe;
  final Map<String, StreamerDevice> _found = {};
  Future<void>? _searching;

  /// Looks for streamers on the network; at most one search at a time, and one in [_pause]. Only while signed in: they
  /// play the server's tracks.
  Future<void> search() {
    final last = _lastSearch;
    if (last != null && DateTime.now().difference(last) < _pause) return _searching ?? Future.value();
    _lastSearch = DateTime.now();
    return _searching ??= _search().whenComplete(() => _searching = null);
  }

  static const Duration _pause = Duration(seconds: 10);
  DateTime? _lastSearch;

  Future<void> _search() async {
    if (!_session.isLoggedIn) return;
    try {
      final locations = await _upnp.search();
      final renderers = await Future.wait([
        for (final location in locations)
          _upnp.describe(location).catchError((Object e) {
            WiretuneLog.debug('Streamers', 'No renderer at $location: $e');
            return null;
          }),
      ]);
      if (!_session.isLoggedIn) return;
      for (final renderer in renderers.nonNulls) {
        if (_found.containsKey(renderer.id)) continue;
        final device = _found[renderer.id] = StreamerDevice(
          renderer,
          _upnp,
          trackOf: (id) => _library.resolveTracks([id]).where((t) => !t.isLocal).firstOrNull,
          sourceOf: _sourceOf,
          played: (track) => _library.recordPlay(track.id),
          changed: _remote.localChanged,
          gone: () => _forget(renderer.id),
        );
        _remote.addLocal(device);
        unawaited(device.refresh());
      }
    } catch (e) {
      WiretuneLog.warn('Streamers', 'Could not look for streamers: $e');
    }
  }

  /// What a streamer fetches for [track]: its stream (the original file) and its cover, each with a stream token,
  /// which opens nothing but the media.
  Future<({String url, String? cover})> _sourceOf(Track track) async {
    final token = await _session.getStreamToken();
    String withToken(String url) => token == null || token.isEmpty
        ? url
        : '$url${url.contains('?') ? '&' : '?'}token=${Uri.encodeQueryComponent(token)}';
    final cover = track.coverArtPath;
    return (
      url: withToken(track.streamUrl!),
      cover: cover != null && cover.startsWith('http') ? withToken(cover) : null,
    );
  }

  void _forget(String id) {
    _found.remove(id)?.dispose();
    _remote.removeLocal(id);
  }

  void _forgetAll() {
    for (final id in [..._found.keys]) {
      _forget(id);
    }
  }

  void dispose() {
    _unsubscribe();
    _forgetAll();
  }
}

/// A streamer as a device this player plays on: it takes the commands another Wiretune player would
/// ([RemoteCommand]) and tells what it plays ([RemotePlayback]). A streamer has no queue of its own, so this keeps
/// it: one track at a time is handed over, and the next when it ends. Its own buttons (pause, volume) show here at the
/// next look ([refresh], every second while it has music).
class StreamerDevice implements LocalDevice {
  StreamerDevice(
    this.renderer,
    this._upnp, {
    required this.trackOf,
    required this.sourceOf,
    required this.played,
    required this.changed,
    required this.gone,
  });

  final UpnpRenderer renderer;
  final UpnpClient _upnp;

  /// The track the server's ID stands for, when this library has it as a server track; null for anything a streamer
  /// can't fetch.
  final Track? Function(String id) trackOf;
  final Future<({String url, String? cover})> Function(Track track) sourceOf;

  /// A track began: it counts as played.
  final void Function(Track track) played;

  /// What it plays changed.
  final void Function() changed;

  /// It stopped answering.
  final void Function() gone;

  @override
  late final RemoteDevice device = RemoteDevice(renderer.id, renderer.name, DeviceKind.streamer)
    ..playback = const RemotePlayback()
    ..playbackReceivedAt = DateTime.now();

  /// Looks this often while it has music.
  static Duration pollInterval = const Duration(seconds: 1);

  /// Gives up on a track that doesn't start within this.
  static Duration startTimeout = const Duration(seconds: 15);

  List<String> _queue = const [];
  List<String>? _unshuffled;
  int _index = -1;
  bool _playing = false;
  Duration _position = Duration.zero;
  double _volume = 100;
  bool _muted = false;
  bool _shuffle = false;
  RepeatMode _repeat = RepeatMode.off;

  /// A track was handed over and hasn't started yet (it is loading): a stop meanwhile isn't its end.
  DateTime? _starting;

  /// Where to go once it has started (a position handed over from another player).
  Duration? _startAt;
  int _failures = 0;
  Timer? _poll;
  bool _disposed = false;

  /// The streamer's actions, one after the other, in the order they were asked for.
  Future<void> _chain = Future.value();

  void _then(Future<void> Function() action) {
    _chain = _chain.then((_) async {
      if (_disposed) return;
      try {
        await action();
        _failures = 0;
      } catch (e) {
        UpnpClient.logFailure(renderer, e);
        if (++_failures >= 3) {
          gone();
        }
      }
    });
  }

  Track? get _current => _index >= 0 && _index < _queue.length ? trackOf(_queue[_index]) : null;

  void _tell() {
    if (_disposed) return;
    device
      ..playback = RemotePlayback(
        track: _current,
        playing: _playing,
        position: _position,
        volume: _volume,
        muted: _muted,
        shuffle: _shuffle,
        repeat: _repeat,
        queue: _queue,
        queueIndex: _index,
      )
      ..playbackReceivedAt = DateTime.now();
    changed();
  }

  /// Looks at what it does: its volume, whether it plays, and where.
  Future<void> refresh() async {
    final completer = Completer<void>();
    _then(() async {
      try {
        await _look(withVolume: true);
      } finally {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  void execute(RemoteCommand command) {
    switch (command.action) {
      case RemoteAction.play:
        _then(() async {
          if (_current == null) return;
          await _upnp.play(renderer);
          _playing = true;
          _startPolling();
          _tell();
        });
      case RemoteAction.pause || RemoteAction.stop:
        _then(() async {
          if (_current == null) return;
          await _upnp.pause(renderer);
          _playing = false;
          _tell();
        });
      case RemoteAction.toggle:
        execute(RemoteCommand(_playing ? RemoteAction.pause : RemoteAction.play));
      case RemoteAction.next:
        _then(() => _advance(byUser: true));
      case RemoteAction.previous:
        _then(() async {
          if (_position > const Duration(seconds: 3) || _index <= 0) {
            await _start(_index);
          } else {
            await _start(_index - 1);
          }
        });
      case RemoteAction.seek:
        _then(() async {
          if (_current == null) return;
          await _upnp.seek(renderer, command.position);
          _position = command.position;
          _tell();
        });
      case RemoteAction.volume:
        _then(() async {
          await _upnp.setVolume(renderer, command.volume.round());
          if (_muted) await _upnp.setMute(renderer, false);
          _volume = command.volume;
          _muted = false;
          _tell();
        });
      case RemoteAction.mute:
        _then(() async {
          await _upnp.setMute(renderer, command.on);
          _muted = command.on;
          _tell();
        });
      case RemoteAction.shuffle:
        _setShuffle(command.on);
        _tell();
      case RemoteAction.repeat:
        _repeat = command.repeat;
        _tell();
      case RemoteAction.playTracks:
        // What it can fetch: the server's tracks; one this library lacks gives way to the next it has.
        final ids = [
          for (final id in command.trackIds)
            if (trackOf(id) != null) id,
        ];
        final wanted = command.index >= 0 && command.index < command.trackIds.length
            ? command.trackIds[command.index]
            : null;
        var start = wanted == null ? 0 : ids.indexOf(wanted);
        final from = start >= 0 ? command.position : Duration.zero;
        if (start < 0) {
          final later = command.trackIds.skip(command.index + 1).where(ids.contains).firstOrNull;
          start = later == null ? 0 : ids.indexOf(later);
        }
        _queue = ids;
        _unshuffled = null;
        if (_shuffle) _setShuffle(true, keep: start);
        _then(() => _start(_shuffle ? 0 : start, at: from));
      case RemoteAction.playIndex:
        _then(() => _start(command.index));
      case RemoteAction.moveTrack:
        _move(command.index, command.toIndex);
        _tell();
      case RemoteAction.removeTrack:
        _remove(command.index);
      case RemoteAction.clearQueue:
        _then(() async {
          if (_current != null) await _upnp.stop(renderer);
          _queue = const [];
          _unshuffled = null;
          _index = -1;
          _playing = false;
          _position = Duration.zero;
          _poll?.cancel();
          _tell();
        });
      case RemoteAction.playNext || RemoteAction.addToQueue:
        final ids = [
          for (final id in command.trackIds)
            if (trackOf(id) != null) id,
        ];
        if (ids.isEmpty) return;
        final at = command.action == RemoteAction.playNext ? _index + 1 : _queue.length;
        _queue = [..._queue.take(at), ...ids, ..._queue.skip(at)];
        if (_unshuffled case final original?) _unshuffled = [...original, ...ids];
        if (_index < 0) {
          _then(() => _start(at));
        } else {
          _tell();
        }
    }
  }

  /// Hands over the queue's track at [index] (from [at]) and has it play; past the end, stops.
  Future<void> _start(int index, {Duration at = Duration.zero}) async {
    if (index < 0 || index >= _queue.length) {
      if (_current != null) await _upnp.stop(renderer);
      _playing = false;
      _poll?.cancel();
      _tell();
      return;
    }
    _index = index;
    final track = _current!;
    final source = await sourceOf(track);
    await _upnp.setUri(
      renderer,
      source.url,
      UpnpClient.didl(
        url: source.url,
        mimeType: AudioFileTypes.mimeTypeOfCodec(track.format.codec),
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        coverUrl: source.cover,
      ),
    );
    await _upnp.play(renderer);
    _playing = true;
    _position = Duration.zero;
    _starting = DateTime.now();
    _startAt = at > Duration.zero ? at : null;
    played(track);
    _startPolling();
    _tell();
  }

  /// To the next track: when one ends ([byUser] false) as repeat says, or because the user asked.
  Future<void> _advance({bool byUser = false}) async {
    if (!byUser && _repeat == RepeatMode.one) return _start(_index);
    final next = _index + 1;
    if (next < _queue.length) return _start(next);
    if (_repeat == RepeatMode.all && _queue.isNotEmpty) return _start(0);
    // The end of the queue: it stays on the last track, stopped.
    if (byUser) return;
    _playing = false;
    _position = Duration.zero;
    _poll?.cancel();
    _tell();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) {
      if (!_disposed) _then(() => _look());
    });
  }

  /// What it does now; a track that ended moves on to the next.
  Future<void> _look({bool withVolume = false}) async {
    if (withVolume) {
      final volume = await _upnp.volume(renderer);
      if (volume != null) _volume = volume.toDouble();
    }
    if (_current == null) {
      if (withVolume) _tell();
      return;
    }
    final state = await _upnp.transport(renderer);
    final at = await _upnp.position(renderer);
    final starting = _starting;
    if (starting != null) {
      // Playing, or paused already (by the user meanwhile): it has the track.
      if (state == UpnpTransport.playing || state == UpnpTransport.paused) {
        _starting = null;
        if (_startAt case final start?) {
          _startAt = null;
          await _upnp.seek(renderer, start);
          _position = start;
          _tell();
          return;
        }
      } else if (DateTime.now().difference(starting) > startTimeout) {
        _starting = null;
        WiretuneLog.warn('Streamers', '${renderer.name} did not start ${_current?.title}.');
        return _advance();
      } else {
        return; // still loading
      }
    }
    _position = at.position;
    switch (state) {
      case UpnpTransport.playing:
        _playing = true;
      case UpnpTransport.paused:
        _playing = false; // paused on the streamer itself
      case UpnpTransport.stopped || UpnpTransport.noMedia:
        // Stopped while it played: the track ended (or the streamer's own stop button).
        if (_playing) return _advance();
      case UpnpTransport.transitioning:
        break;
    }
    _tell();
  }

  void _setShuffle(bool on, {int? keep}) {
    _shuffle = on;
    if (on) {
      // The current track (or [keep]) first, the rest in a random order after it.
      final first = keep ?? _index;
      final original = _unshuffled ??= _queue;
      final rest = [
        for (var i = 0; i < _queue.length; i++)
          if (i != first) _queue[i],
      ]..shuffle(math.Random());
      _queue = [if (first >= 0 && first < original.length) _queue[first], ...rest];
      if (_index >= 0) _index = 0;
    } else if (_unshuffled case final original?) {
      final current = _index >= 0 && _index < _queue.length ? _queue[_index] : null;
      _queue = original;
      _unshuffled = null;
      _index = current == null ? _index : _queue.indexOf(current);
    }
  }

  void _move(int from, int to) {
    if (from < 0 || from >= _queue.length || to < 0 || to >= _queue.length || from == to) return;
    final current = _index >= 0 ? _queue[_index] : null;
    final queue = [..._queue];
    queue.insert(to, queue.removeAt(from));
    _queue = queue;
    if (current != null) _index = from == _index ? to : _queue.indexOf(current);
  }

  void _remove(int index) {
    if (index < 0 || index >= _queue.length) return;
    final removed = _queue[index];
    _queue = [..._queue]..removeAt(index);
    if (_unshuffled case final original?) _unshuffled = [...original]..remove(removed);
    if (index < _index) {
      _index--;
      _tell();
    } else if (index == _index) {
      // The current one: the next takes its place, or it stops.
      if (_playing && _index < _queue.length) {
        _then(() => _start(_index));
      } else {
        if (_index >= _queue.length) _index = _queue.length - 1;
        _then(() async {
          await _upnp.stop(renderer);
          _playing = false;
          _tell();
        });
      }
    } else {
      _tell();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
  }
}
