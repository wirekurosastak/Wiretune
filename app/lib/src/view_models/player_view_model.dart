// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Where the lyrics shown for the current track come from.
enum LyricsOrigin {
  /// There are no lyrics.
  none,

  /// The track's own tags (the file, or the server's copy of the file's tags).
  tags,

  /// The internet lookup (LRCLIB).
  online,
}

/// One line of time-synced lyrics as the lyrics panel shows it.
class LyricLine {
  LyricLine(this.time, this.text);

  final Duration time;
  final String text;

  /// An instrumental gap: shown as a small space, never highlighted.
  bool get isBlank => text.isEmpty;

  /// The line being sung right now.
  bool isActive = false;

  /// A line that has already been sung (shown dimmer than the ones still to come).
  bool isPast = false;
}

/// One entry of the queue.
class QueueItem {
  QueueItem(this.track, this.index, this.isCurrent);

  final Track track;
  int index;
  bool isCurrent;

  int get displayIndex => index + 1;
}

typedef LyricsProvider = Future<String?> Function(Track track);

/// The player: the queue, shuffle and repeat, the transport, volume and modes, and the lyrics of the current track.
///
/// With [attachRemote] it also takes part in remote control: the account's other players see what plays here and can
/// control it, and [selectDevice] turns this one into the remote control of another. While it is, the state the
/// interface reads (track, position, queue, volume, shuffle, repeat) is the other device's, and the commands go there;
/// this device's own playback carries on underneath, untouched.
class PlayerViewModel extends ChangeNotifier {
  PlayerViewModel(this._engine, this._library) {
    _subscriptions.addAll([
      _engine.stateChanged.listen((state) {
        _state = state;
        if (state == PlaybackState.playing) errorMessage = null;
        if (state != PlaybackState.playing) spectrum.value = Float32List(SpectrumAnalyzer.numBands);
        notifyListeners();
      }),
      // The player keeps the Track instance it started with; a favourite toggled elsewhere changes the library's one.
      _library.favoriteChanged.listen((changed) {
        final current = _currentTrack;
        if (current != null && current.id == changed.id && !identical(current, changed)) {
          current.isFavorite = changed.isFavorite;
        }
        notifyListeners();
      }),
      _engine.playbackFailed.listen((message) {
        errorMessage = message;
        notifyListeners();
      }),
      _engine.trackEnded.listen((_) => _onTrackEnded()),
      _engine.positionChanged.listen((position) {
        _localPosition = position;
        if (!_isUserSeeking && !isRemote) _setPosition(position);
        _publishIfDrifted(position);
      }),
      _engine.trackChanged.listen(_onEngineTrackChanged),
      _engine.bitperfectChanged.listen((value) {
        _volume = value ? 100 : (_engine.volume * 100).roundToDouble();
        notifyListeners();
      }),
      _engine.exclusiveModeChanged.listen((_) => notifyListeners()),
      _engine.spectrumDataAvailable.listen((bands) {
        if (_state == PlaybackState.playing && !isRemote) spectrum.value = bands;
      }),
    ]);
  }

  final WiretuneAudioEngine _engine;
  final LibraryService _library;
  final List<void Function()> _subscriptions = [];
  final List<Track> _originalQueue = [];
  final List<Track> _playbackQueue = [];
  final math.Random _random = math.Random();
  int _queueIndex = -1;
  bool _isUserSeeking = false;
  Timer? _seekDebounce;
  CancellationToken? _lyricsToken;
  String? _lyricsTrackId;

  // ── State ──────────────────────────────────────────────────────────────────────────────────────
  // This device's own playback; the public getters show the other device's instead while this one controls it.

  Track? _currentTrack;
  PlaybackState _state = PlaybackState.stopped;

  /// This device's own position (the one shown is another device's while it controls one), and where the track being
  /// started begins.
  Duration _localPosition = Duration.zero;
  Duration _startAt = Duration.zero;
  double _volume = 100;
  bool _muted = false;
  bool _shuffle = false;
  RepeatMode _repeat = RepeatMode.off;
  List<Track> _queueTracks = const [];
  List<QueueItem> _queueItems = const [];
  int _queueVersion = 0;

  /// The track that is playing (on the device being controlled).
  Track? get currentTrack => isRemote ? _remoteTrack : _currentTrack;

  /// Shows [value] as this device's current track without playing it.
  set currentTrack(Track? value) {
    if (identical(_currentTrack, value)) return;
    _currentTrack = value;
    _showCurrentTrack();
  }

  PlaybackState get playbackState {
    if (!isRemote) return _state;
    final remote = _remoteState;
    if (remote == null || remote.track == null) return PlaybackState.stopped;
    return remote.playing ? PlaybackState.playing : PlaybackState.paused;
  }

  /// The playback position; updated several times a second, so it has its own notifier.
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// The whole seconds of [position]: what the times show, and what a progress bar has to follow to be drawn once a
  /// second rather than at every position update.
  final ValueNotifier<int> elapsedSeconds = ValueNotifier(0);

  /// The spectrum bands (0..1), about 30 times a second while playing.
  final ValueNotifier<Float32List> spectrum = ValueNotifier(Float32List(SpectrumAnalyzer.numBands));

  double get positionSeconds => position.value.inMicroseconds / 1e6;
  Duration get duration => currentTrack?.duration ?? Duration.zero;
  double get durationSeconds => duration.inMicroseconds / 1e6;

  double get volume => isRemote ? (_remoteVolume ?? _remoteState?.volume ?? 100) : _volume;
  bool get isMuted => isRemote ? (_remoteState?.muted ?? false) : _muted;
  bool get isShuffle => isRemote ? (_remoteState?.shuffle ?? false) : _shuffle;
  RepeatMode get repeatMode => isRemote ? (_remoteState?.repeat ?? RepeatMode.off) : _repeat;

  bool get isExclusiveMode => _engine.isExclusiveMode;
  bool get isBitperfect => _engine.isBitperfect;
  String? errorMessage;

  QualityTier get currentTier => currentTrack?.format.tier ?? QualityTier.silver;
  String get currentTagSpec => currentTrack?.format.tagSpec ?? '';

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
  bool get isPlaying => playbackState == PlaybackState.playing;

  /// Bit-perfect pins the volume at 100 % (also on the device being controlled).
  bool get isVolumeLocked => isRemote ? (_remoteState?.volumeLocked ?? false) : isBitperfect;
  bool get isVolumeDisabledOrMuted => isMuted || isVolumeLocked;
  String get volumeToolTip =>
      Localizer.get(isMuted ? 'VolumeUnmute' : (isVolumeLocked ? 'VolumeLocked' : 'VolumeMute'));

  /// Title of the current track, or a hint when nothing is loaded.
  String get nowPlayingTitle => currentTrack?.title ?? Localizer.get('NothingPlaying');

  /// Artist of the current track, or a hint when nothing is loaded.
  String get nowPlayingArtist => currentTrack?.artist ?? Localizer.get('ChooseMusic');

  // ── Queue ──────────────────────────────────────────────────────────────────────────────────────

  bool _isQueueOpen = false;

  /// Whether the queue (and lyrics) panel is open. Lyrics are only looked for while it is.
  bool get isQueueOpen => _isQueueOpen;
  set isQueueOpen(bool value) {
    if (_isQueueOpen == value) return;
    _isQueueOpen = value;
    if (value) {
      _updateQueueState();
      _refreshLyrics();
    }
    notifyListeners();
  }

  List<Track> get queueTracks => isRemote ? [for (final item in _remoteQueue) item.track] : _queueTracks;
  List<QueueItem> get queueItems => isRemote ? _remoteQueue : _queueItems;
  int get currentQueueIndex => isRemote ? _remoteQueue.indexWhere((item) => item.isCurrent) : _queueIndex;

  void toggleQueue() => isQueueOpen = !isQueueOpen;

  void closeQueue() => isQueueOpen = false;

  /// Plays a track of the queue; a track that is not queued yet starts the library.
  void playQueueTrack(Track track) {
    if (isRemote) {
      final item = _remoteQueue.where((item) => identical(item.track, track)).firstOrNull;
      _sendRemote(
        item != null
            ? RemoteCommand(RemoteAction.playIndex, index: item.index)
            : RemoteCommand(RemoteAction.playTracks, trackIds: [_library.sharedId(track)]),
      );
      return;
    }
    final index = _playbackQueue.indexOf(track);
    if (index >= 0) {
      _playAt(index);
    } else {
      _playQueueInternal(_library.tracks.isNotEmpty ? _library.tracks : [track], track);
    }
  }

  void moveQueueTrack(int oldIndex, int newIndex) {
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex == newIndex) return;

    if (isRemote) {
      if (oldIndex >= _remoteQueue.length || newIndex >= _remoteQueue.length) return;
      final item = _remoteQueue.removeAt(oldIndex);
      _remoteQueue.insert(newIndex, item);
      notifyListeners();
      _sendRemote(RemoteCommand(RemoteAction.moveTrack, index: oldIndex, toIndex: newIndex));
      return;
    }

    if (oldIndex >= _playbackQueue.length || newIndex >= _playbackQueue.length) return;

    final track = _playbackQueue.removeAt(oldIndex);
    _playbackQueue.insert(newIndex, track);
    if (!_shuffle) {
      _originalQueue
        ..clear()
        ..addAll(_playbackQueue);
    }

    if (_currentTrack != null) {
      _queueIndex = _playbackQueue.indexOf(_currentTrack!);
    } else if (_queueIndex >= 0) {
      if (oldIndex == _queueIndex) {
        _queueIndex = newIndex;
      } else if (oldIndex < _queueIndex && newIndex >= _queueIndex) {
        _queueIndex--;
      } else if (oldIndex > _queueIndex && newIndex <= _queueIndex) {
        _queueIndex++;
      }
    }
    _updateQueueState();
    notifyListeners();
  }

  void moveQueueTrackUp(QueueItem? item) {
    if (item == null || item.index <= 0) return;
    moveQueueTrack(item.index, item.index - 1);
  }

  void moveQueueTrackDown(QueueItem? item) {
    final count = isRemote ? _remoteQueue.length : _playbackQueue.length;
    if (item == null || item.index >= count - 1) return;
    moveQueueTrack(item.index, item.index + 1);
  }

  void removeQueueTrack(Track? track) {
    if (track == null) return;
    if (isRemote) {
      final index = _remoteQueue.indexWhere((item) => item.track.id == track.id);
      if (index >= 0) {
        _remoteQueue.removeAt(index);
        notifyListeners();
        _sendRemote(RemoteCommand(RemoteAction.removeTrack, index: index));
      }
      return;
    }
    final index = _playbackQueue.indexOf(track);
    if (index < 0) return;

    final removedCurrent = index == _queueIndex;
    _playbackQueue.removeAt(index);
    _originalQueue.remove(track); // also while shuffled, or turning shuffle off would bring the track back

    if (removedCurrent) {
      // The playing track was taken out of the queue: carry on with whatever followed it (or stop at the end).
      _queueIndex = index - 1;
      _updateQueueState();
      if (_playbackQueue.isNotEmpty) {
        _nextTrackLocal();
      } else {
        _runSafe(_engine.stop);
      }
      notifyListeners();
      return;
    }

    if (index < _queueIndex) _queueIndex--;
    _updateQueueState();
    notifyListeners();
  }

  void clearQueue() {
    if (isRemote) {
      final current = _remoteQueue.where((item) => item.isCurrent).firstOrNull;
      _remoteQueue = current != null ? [current] : [];
      notifyListeners();
      _sendRemote(const RemoteCommand(RemoteAction.clearQueue));
      return;
    }
    final current =
        _currentTrack ?? (_queueIndex >= 0 && _queueIndex < _playbackQueue.length ? _playbackQueue[_queueIndex] : null);
    _playbackQueue.clear();
    _originalQueue.clear();
    if (current != null) {
      _playbackQueue.add(current);
      _originalQueue.add(current);
      _queueIndex = 0;
    } else {
      _queueIndex = -1;
    }
    _updateQueueState();
    notifyListeners();
  }

  void _updateQueueState() {
    _queueVersion++;
    _queueTracks = List.unmodifiable(_playbackQueue);
    _queueItems = [for (var i = 0; i < _playbackQueue.length; i++) QueueItem(_playbackQueue[i], i, i == _queueIndex)];
  }

  /// Replaces the queue with [tracks] and starts [startTrack] (the first track, or a random one when shuffling).
  void playQueue(Iterable<Track> tracks, [Track? startTrack]) {
    if (isRemote) {
      final list = tracks.toList();
      if (list.isEmpty) return;
      final start = startTrack == null ? -1 : list.indexOf(startTrack);
      final (ids, index) = _window(list, math.max(0, start));
      // No start track: the device picks one, as it would itself (a random one while it shuffles).
      _sendRemote(RemoteCommand(RemoteAction.playTracks, trackIds: ids, index: start < 0 ? -1 : index));
      return;
    }
    _playQueueInternal(tracks, startTrack);
    notifyListeners();
  }

  /// Switches shuffle on and plays [tracks] from a random one: the "Shuffle" button of a list.
  void shuffleQueue(List<Track> tracks) {
    if (tracks.isEmpty) return;
    setShuffle(true);
    playQueue(tracks);
  }

  void _playQueueInternal(Iterable<Track> tracks, Track? startTrack, {Duration start = Duration.zero}) {
    final list = tracks.toList();
    if (list.isEmpty) return;
    _originalQueue
      ..clear()
      ..addAll(list);

    final first = startTrack != null && _originalQueue.contains(startTrack) ? startTrack : null;
    _playbackQueue.clear();
    if (_shuffle) {
      final lead = first ?? _originalQueue[_random.nextInt(_originalQueue.length)];
      _playbackQueue
        ..add(lead)
        ..addAll(_originalQueue.where((t) => !identical(t, lead)).toList()..shuffle(_random));
      _playAt(0, start: start);
    } else {
      _playbackQueue.addAll(_originalQueue);
      _playAt(first != null ? _playbackQueue.indexOf(first) : 0, start: start);
    }
    _updateQueueState();
  }

  void _playAt(int index, {Duration start = Duration.zero}) {
    if (index < 0 || index >= _playbackQueue.length) return;
    _queueIndex = index;
    _updateQueueState();
    errorMessage = null;
    final track = _playbackQueue[index];
    _startAt = start;
    _runSafe(() => _engine.playTrack(track, start: start));
    notifyListeners();
  }

  // ── Transport ──────────────────────────────────────────────────────────────────────────────────
  // Each command goes to the device being controlled, or runs here; what another device asks of this one runs here.

  Future<void> togglePlayPause() =>
      isRemote ? _sendRemote(const RemoteCommand(RemoteAction.toggle)) : _togglePlayPauseLocal();

  Future<void> play() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.play)) : _playLocal();

  Future<void> pause() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.pause)) : _pauseLocal();

  Future<void> stop() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.stop)) : _runSafe(_engine.stop);

  void nextTrack() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.next)) : _nextTrackLocal();

  /// Restarts the current track when more than three seconds have played, otherwise goes to the previous one.
  void previousTrack() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.previous)) : _previousTrackLocal();

  void toggleShuffle() => setShuffle(!isShuffle);

  /// Reorders the rest of the running queue without interrupting the current track.
  void setShuffle(bool value) =>
      isRemote ? _sendRemote(RemoteCommand(RemoteAction.shuffle, on: value)) : _setShuffleLocal(value);

  void toggleRepeat() => setRepeatMode(switch (repeatMode) {
    RepeatMode.off => RepeatMode.all,
    RepeatMode.all => RepeatMode.one,
    RepeatMode.one => RepeatMode.off,
  });

  void setRepeatMode(RepeatMode mode) {
    if (isRemote) {
      _sendRemote(RemoteCommand(RemoteAction.repeat, repeat: mode));
      return;
    }
    _repeat = mode;
    notifyListeners();
  }

  Future<void> _togglePlayPauseLocal() async {
    switch (_state) {
      case PlaybackState.playing:
        await _engine.pause();
      case PlaybackState.paused:
        await _engine.resume();
      default:
        if (_queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
          _playAt(_queueIndex);
        } else if (_currentTrack != null) {
          _playQueueInternal([_currentTrack!], _currentTrack);
          notifyListeners();
        } else if (_library.tracks.isNotEmpty) {
          _playQueueInternal(_library.tracks, null);
          notifyListeners();
        }
    }
  }

  Future<void> _playLocal() async {
    if (_state != PlaybackState.playing) await _togglePlayPauseLocal();
  }

  Future<void> _pauseLocal() async {
    if (_state == PlaybackState.playing) await _engine.pause();
  }

  void _nextTrackLocal() {
    if (_playbackQueue.isEmpty) return;
    if (_queueIndex + 1 < _playbackQueue.length) {
      _playAt(_queueIndex + 1);
    } else if (_repeat == RepeatMode.all) {
      _playAt(0);
    } else {
      _queueIndex = _playbackQueue.length; // past the end: nothing is current any more
      _updateQueueState();
      _runSafe(_engine.stop);
      notifyListeners();
    }
  }

  void _previousTrackLocal() {
    if (_playbackQueue.isEmpty) return;
    // The position shown is this device's own, except while it controls another one.
    final at = isRemote ? _localPosition : position.value;
    if (at > const Duration(seconds: 3)) {
      _runSafe(() => _engine.seek(Duration.zero));
      return;
    }
    var previous = _queueIndex - 1;
    if (previous < 0) previous = _repeat == RepeatMode.all ? _playbackQueue.length - 1 : 0;
    _playAt(math.min(previous, _playbackQueue.length - 1));
  }

  void _setShuffleLocal(bool value) {
    if (_shuffle == value) return;
    _shuffle = value;
    if (_playbackQueue.length >= 2 && _queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
      final current = _playbackQueue[_queueIndex];
      final rest = value
          ? (_originalQueue.where((t) => !identical(t, current)).toList()..shuffle(_random))
          : _originalQueue.skipWhile((t) => !identical(t, current)).skip(1).toList();
      _playbackQueue
        ..clear()
        ..add(current)
        ..addAll(rest);
      _queueIndex = 0;
      _updateQueueState();
    }
    notifyListeners();
  }

  Future<void> toggleFavoriteCurrent() async {
    final current = currentTrack;
    if (current == null) return;
    await _library.toggleFavorite(current.id);
    // A server refresh replaces the library's Track objects while the player keeps the one it started playing: mirror
    // the change so the heart in the player bar follows.
    final inLibrary = _library.getTrack(current.id);
    if (inLibrary != null && !identical(inLibrary, current)) current.isFavorite = inLibrary.isFavorite;
    notifyListeners();
  }

  Future<void> toggleBitperfect() => _engine.setBitperfectMode(!isBitperfect);

  Future<void> toggleExclusiveMode() => _engine.setExclusiveMode(!isExclusiveMode);

  void dismissError() {
    errorMessage = null;
    notifyListeners();
  }

  /// Shows a failure that happened outside playback (an unhandled exception) in the player's error line.
  void showError(String message) {
    errorMessage = message;
    notifyListeners();
  }

  /// The user moved the position slider: the display follows at once, the seek itself is debounced so that dragging
  /// produces a single seek.
  void seekTo(Duration target) {
    if (currentTrack == null) return;
    if (target < Duration.zero) target = Duration.zero;
    _setPosition(target);
    _isUserSeeking = true;

    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 200), () async {
      if (isRemote) {
        _isUserSeeking = false;
        // Shown at once; the device's own state confirms it a moment later.
        _remoteBase = (target, DateTime.now());
        await _sendRemote(RemoteCommand(RemoteAction.seek, position: target));
        return;
      }
      try {
        await _engine.seek(target);
      } catch (e) {
        WiretuneLog.warn('PlayerViewModel', 'Seek failed: $e');
      } finally {
        _isUserSeeking = false;
      }
    });
  }

  void setVolume(double value) {
    final level = value.clamp(0.0, 100.0);
    if (isRemote) {
      // The slider follows the finger; the device hears of it at most every 100 ms, and the last value always.
      _remoteVolume = level;
      _remoteVolumeAt = DateTime.now();
      _remoteVolumeTimer ??= Timer(const Duration(milliseconds: 100), () {
        _remoteVolumeTimer = null;
        final latest = _remoteVolume;
        if (latest != null) _sendRemote(RemoteCommand(RemoteAction.volume, volume: latest));
      });
      notifyListeners();
      return;
    }
    _setVolumeLocal(level);
  }

  void _setVolumeLocal(double value) {
    _volume = value.clamp(0, 100);
    if (!isBitperfect) _engine.setVolume(_volume / 100.0);
    notifyListeners();
  }

  void toggleMute() {
    if (isRemote) {
      if (!isVolumeLocked) _sendRemote(RemoteCommand(RemoteAction.mute, on: !isMuted));
      return;
    }
    _setMutedLocal(!_muted);
  }

  void _setMutedLocal(bool muted) {
    if (isBitperfect || _muted == muted) return;
    _muted = muted;
    _engine.setMuted(_muted);
    notifyListeners();
  }

  // ── Engine callbacks ───────────────────────────────────────────────────────────────────────────

  void _onEngineTrackChanged(Track? track) {
    if (!isRemote) {
      _seekDebounce?.cancel();
      _seekDebounce = null;
      _isUserSeeking = false;
    }

    _localPosition = track == null ? Duration.zero : _startAt;
    _startAt = Duration.zero;
    currentTrack = track;
    if (!isRemote) _setPosition(_localPosition);
    if (track != null) {
      // Bookkeeping only: no error banner when it fails.
      unawaited(
        _library.recordPlay(track.id).catchError((Object e) {
          WiretuneLog.debug('PlayerViewModel', 'Recording a play failed: $e');
        }),
      );
    }
    notifyListeners();
  }

  void _onTrackEnded() {
    if (_repeat == RepeatMode.one && _queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
      _playAt(_queueIndex);
    } else if (_queueIndex < _playbackQueue.length - 1 || _repeat == RepeatMode.all) {
      _nextTrackLocal();
    }
  }

  void _setPosition(Duration value) {
    position.value = value;
    elapsedSeconds.value = value.inSeconds;
    _updateLyricPosition(value);
  }

  /// The track shown changed: the lists highlight the new one, and its lyrics are looked for.
  void _showCurrentTrack() {
    final shown = currentTrack;
    final old = _marked;
    if (!identical(old, shown)) {
      _marked = shown;
      if (old != null) {
        old.isPlaying = false;
        final inLibrary = _library.getTrack(old.id);
        if (inLibrary != null && !identical(inLibrary, old)) inLibrary.isPlaying = false;
      }
      if (shown != null) {
        shown.isPlaying = true;
        final inLibrary = _library.getTrack(shown.id);
        if (inLibrary != null && !identical(inLibrary, shown)) inLibrary.isPlaying = true;
        if (shown.bpm == null || shown.bpm == 0) {
          _loadTrackBpm(shown);
        }
      }
    }
    if (_lyricsTrackId != shown?.id) {
      _lyricsTrackId = null;
      _refreshLyrics();
    }
    notifyListeners();
  }

  void _loadTrackBpm(Track track) {
    final path = track.filePath;
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final tags = TagReader.read(path);
      final bpm = tags?.bpm;
      if (bpm != null && bpm > 0) {
        track.bpm = bpm;
        final inLibrary = _library.getTrack(track.id);
        if (inLibrary != null && !identical(inLibrary, track)) {
          inLibrary.bpm = bpm;
        }
        _library.updateTrackBpm(track.id, bpm);
        notifyListeners();
      }
    } catch (_) {}
  }

  Track? _marked;

  // ── Other devices (remote control) ─────────────────────────────────────────────────────────────

  /// How long the device being controlled may be out of sight (a dropped connection) before control returns here.
  /// Tests shorten it.
  static Duration remoteGrace = const Duration(seconds: 15);

  RemoteClient? _remote;
  String? _remoteId;
  String _remoteName = '';
  DeviceKind _remoteKind = DeviceKind.desktop;
  RemotePlayback? _remoteState;
  (Duration, DateTime)? _remoteBase;
  Track? _remoteTrack;
  List<QueueItem> _remoteQueue = const [];
  Timer? _remoteTicker;
  Timer? _remoteLost;
  double? _remoteVolume;
  DateTime? _remoteVolumeAt;
  Timer? _remoteVolumeTimer;

  // What this device last told the others, so that it tells them only of changes.
  Object? _published;
  (Duration, DateTime, bool)? _publishedPosition;

  /// Joins the account's other players: they see what plays here and can control it, and this player can control them.
  void attachRemote(RemoteClient remote) {
    _remote = remote;
    _subscriptions.addAll([
      remote.devicesChanged.listen((_) => _onDevicesChanged()),
      remote.commandReceived.listen((received) => _execute(received.$2)),
    ]);
    _publish();
  }

  /// This player controls another device.
  bool get isRemote => _remoteId != null;

  /// The other players of the account that are online.
  List<RemoteDevice> get otherDevices => _remote?.devices ?? const [];

  /// Whether other devices can be reached (connected to the server's remote control).
  bool get canReachDevices => _remote?.isConnected ?? false;

  /// The device being controlled, null for this one.
  String? get remoteDeviceId => _remoteId;
  String get remoteDeviceName => _remoteName;
  DeviceKind get remoteDeviceKind => _remoteKind;

  /// Plays on another player of the account, or (null) on this one again. Music that is playing moves along: started
  /// here, it continues there where it was (and stops here); playing there, it continues here when control comes back.
  void selectDevice(String? deviceId) {
    if (deviceId == _remoteId) return;
    final remote = _remote;
    if (remote == null) return;
    final from = _remoteId;
    final fromState = _remoteState;
    final fromPosition = _remotePosition();

    if (deviceId == null) {
      _leaveRemote();
      if (from != null && fromState != null && fromState.playing) {
        final tracks = _library.resolveTracks(fromState.queue);
        if (tracks.isNotEmpty) {
          remote.send(from, const RemoteCommand(RemoteAction.pause));
          final current = fromState.track == null ? null : _library.resolveTracks([fromState.track!.id]).firstOrNull;
          final found = current != null && tracks.contains(current);
          _playQueueInternal(tracks, found ? current : null, start: found ? fromPosition : Duration.zero);
        }
      }
      notifyListeners();
      return;
    }

    if (remote.device(deviceId) == null) return;
    // What plays (here, or on the device controlled so far) goes along to the new one.
    if (from != null && fromState != null && fromState.playing) {
      final tracks = _library.resolveTracks(fromState.queue);
      final index = fromState.track == null ? -1 : tracks.indexWhere((t) => t.id == fromState.track!.id);
      if (tracks.isNotEmpty) {
        final (ids, start) = _window(tracks, math.max(0, index));
        remote.send(
          deviceId,
          RemoteCommand(RemoteAction.playTracks, trackIds: ids, index: start, position: fromPosition),
        );
        remote.send(from, const RemoteCommand(RemoteAction.pause));
      }
    } else if (from == null && _state == PlaybackState.playing && _queueIndex >= 0) {
      final (ids, start) = _window(_playbackQueue, _queueIndex);
      remote.send(
        deviceId,
        RemoteCommand(RemoteAction.playTracks, trackIds: ids, index: start, position: _localPosition),
      );
      unawaited(_engine.pause());
    }
    _enterRemote(deviceId);
  }

  /// Stops controlling another device, leaving its music as it is (signing out, remote control switched off).
  void releaseRemote() {
    if (!isRemote) return;
    _leaveRemote();
    notifyListeners();
  }

  /// At most [RemoteRules.maxQueueLength] IDs of [tracks] around [index], and [index] within them.
  (List<String>, int) _window(List<Track> tracks, int index) {
    if (tracks.isEmpty) return (const [], -1);
    const max = RemoteRules.maxQueueLength;
    final first = tracks.length <= max ? 0 : (index - 100).clamp(0, tracks.length - max);
    final ids = [for (final track in tracks.skip(first).take(max)) _library.sharedId(track)];
    return (ids, (index - first).clamp(0, ids.length - 1));
  }

  void _enterRemote(String deviceId) {
    _remoteId = deviceId;
    _remoteState = null;
    _remoteBase = null;
    _remoteTrack = null;
    _remoteQueue = const [];
    _remoteVolume = null;
    _seekDebounce?.cancel();
    _isUserSeeking = false;
    spectrum.value = Float32List(SpectrumAnalyzer.numBands);
    final device = _remote?.device(deviceId);
    _remoteName = device?.name ?? '';
    _remoteKind = device?.kind ?? DeviceKind.desktop;
    final playback = device?.playback;
    if (playback != null) {
      _applyRemote(playback, device!.playbackReceivedAt ?? DateTime.now());
    } else {
      _setPosition(Duration.zero);
      _showCurrentTrack();
    }
  }

  void _leaveRemote() {
    _remoteId = null;
    _remoteState = null;
    _remoteBase = null;
    _remoteTrack = null;
    _remoteQueue = const [];
    _remoteVolume = null;
    _remoteTicker?.cancel();
    _remoteTicker = null;
    _remoteLost?.cancel();
    _remoteLost = null;
    _remoteVolumeTimer?.cancel();
    _remoteVolumeTimer = null;
    _seekDebounce?.cancel();
    _isUserSeeking = false;
    _setPosition(_currentTrack == null ? Duration.zero : _localPosition);
    _showCurrentTrack();
  }

  void _onDevicesChanged() {
    final id = _remoteId;
    if (id != null) {
      final device = _remote?.device(id);
      if (device == null) {
        // Out of sight: a dropped connection comes back within moments; a device that was switched off does not.
        _remoteTicker?.cancel();
        _remoteTicker = null;
        _remoteLost ??= Timer(remoteGrace, () {
          final name = _remoteName;
          _leaveRemote();
          showError(Localizer.format('RemoteDeviceGone', [name.isEmpty ? Localizer.get('RemoteAnotherDevice') : name]));
        });
      } else {
        _remoteLost?.cancel();
        _remoteLost = null;
        _remoteName = device.name;
        _remoteKind = device.kind;
        final playback = device.playback;
        if (playback != null && !identical(playback, _remoteState)) {
          _applyRemote(playback, device.playbackReceivedAt ?? DateTime.now());
        }
      }
    }
    notifyListeners();
  }

  /// Shows what the device being controlled plays: its track (this library's copy of it when there is one, for the
  /// cover and the lyrics), its queue as far as this library knows the tracks, and its position, counted on here.
  void _applyRemote(RemotePlayback playback, DateTime receivedAt) {
    _remoteState = playback;
    _remoteBase = (playback.position, receivedAt);
    final volumeEdited = _remoteVolumeAt;
    if (volumeEdited == null || DateTime.now().difference(volumeEdited) > const Duration(seconds: 1)) {
      _remoteVolume = null; // the device's own value again, once the slider has rested
    }

    // This library's copy of the track when it has one (its cover, its lyrics, its heart); else the device's own
    // description of it, kept while it stays the same track, with the cover of the album here if there is one.
    final told = playback.track;
    final previous = _remoteTrack;
    final Track? shown = told == null
        ? null
        : (_library.resolveTracks([told.id]).firstOrNull ??
              (previous != null && previous.id == told.id
                  ? previous
                  : (told..coverArtPath = _library.getAlbum(told.albumId)?.coverArtPath)));
    final trackChanged = shown?.id != _remoteTrack?.id;
    _remoteTrack = shown;

    final known = <QueueItem>[];
    for (var i = 0; i < playback.queue.length; i++) {
      final track = _library.resolveTracks([playback.queue[i]]).firstOrNull;
      if (track != null) known.add(QueueItem(track, i, i == playback.queueIndex));
    }
    _remoteQueue = known;

    if (!_isUserSeeking) _setPosition(_remotePosition());
    _remoteTicker?.cancel();
    _remoteTicker = playback.playing
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (!_isUserSeeking) _setPosition(_remotePosition());
          })
        : null;
    if (trackChanged) {
      _showCurrentTrack();
    } else {
      notifyListeners();
    }
  }

  /// The position of the device being controlled: the one it told, counted on since while it plays.
  Duration _remotePosition() {
    final base = _remoteBase;
    final state = _remoteState;
    if (base == null || state == null) return Duration.zero;
    var at = base.$1;
    if (state.playing) at += DateTime.now().difference(base.$2);
    final length = _remoteTrack?.duration ?? Duration.zero;
    return length > Duration.zero && at > length ? length : at;
  }

  Future<void> _sendRemote(RemoteCommand command) async {
    final id = _remoteId;
    if (id == null) return;
    if (!(_remote?.send(id, command) ?? false)) {
      showError(
        Localizer.format('RemoteDeviceUnreachable', [
          _remoteName.isEmpty ? Localizer.get('RemoteAnotherDevice') : _remoteName,
        ]),
      );
    }
  }

  /// A command from another device of the account, for this one's own player.
  void _execute(RemoteCommand command) {
    switch (command.action) {
      case RemoteAction.play:
        unawaited(_playLocal());
      case RemoteAction.pause:
        unawaited(_pauseLocal());
      case RemoteAction.toggle:
        unawaited(_togglePlayPauseLocal());
      case RemoteAction.stop:
        unawaited(_runSafe(_engine.stop));
      case RemoteAction.next:
        _nextTrackLocal();
      case RemoteAction.previous:
        _previousTrackLocal();
      case RemoteAction.seek:
        if (_currentTrack != null) _runSafe(() => _engine.seek(command.position));
      case RemoteAction.volume:
        _setVolumeLocal(command.volume);
      case RemoteAction.mute:
        _setMutedLocal(command.on);
      case RemoteAction.shuffle:
        _setShuffleLocal(command.on);
      case RemoteAction.repeat:
        _repeat = command.repeat;
        notifyListeners();
      case RemoteAction.playTracks:
        // Music from another device: it plays here now, and this player shows it. The track it was on starts where it
        // was; one this library lacks gives way to the next one it has, from its beginning.
        final tracks = _library.resolveTracks(command.trackIds);
        if (tracks.isEmpty) return;
        final index = command.index;
        final wanted = index < 0 ? null : _library.resolveTracks([command.trackIds[index]]).firstOrNull;
        final start =
            wanted ?? (index < 0 ? null : _library.resolveTracks(command.trackIds.skip(index + 1)).firstOrNull);
        if (isRemote) _leaveRemote();
        _playQueueInternal(tracks, start, start: wanted != null ? command.position : Duration.zero);
        notifyListeners();
      case RemoteAction.playIndex:
        if (command.index < _playbackQueue.length) _playAt(command.index);
      case RemoteAction.moveTrack:
        moveQueueTrack(command.index, command.toIndex);
      case RemoteAction.removeTrack:
        if (command.index >= 0 && command.index < _playbackQueue.length) {
          removeQueueTrack(_playbackQueue[command.index]);
        }
      case RemoteAction.clearQueue:
        clearQueue();
    }
  }

  /// Tells the other devices about this one's playback when something they show changed.
  void _publish() {
    final remote = _remote;
    if (remote == null) return;
    final track = _currentTrack;
    final playing = _state == PlaybackState.playing;
    final signature = (
      track == null ? null : _library.sharedId(track),
      playing,
      _state == PlaybackState.stopped,
      _volume,
      _muted,
      isBitperfect,
      _shuffle,
      _repeat,
      _queueVersion,
    );
    if (signature == _published) return;
    _published = signature;
    _publishNow(remote);
  }

  /// A position that is not where the others count it to be (a seek, a stall) is told; one that keeps pace is not.
  void _publishIfDrifted(Duration at) {
    final remote = _remote;
    final told = _publishedPosition;
    if (remote == null || told == null) return;
    final (toldPosition, toldAt, toldPlaying) = told;
    final expected = toldPlaying ? toldPosition + DateTime.now().difference(toldAt) : toldPosition;
    if ((at - expected).abs() > const Duration(seconds: 2)) _publishNow(remote);
  }

  void _publishNow(RemoteClient remote) {
    final track = _currentTrack;
    final playing = _state == PlaybackState.playing;
    final at = track == null ? Duration.zero : _localPosition;
    final (queue, index) = _queueIndex >= 0 && _queueIndex < _playbackQueue.length
        ? _window(_playbackQueue, _queueIndex)
        : (<String>[], -1);
    _publishedPosition = (at, DateTime.now(), playing);
    remote.publish(
      RemotePlayback(
        track: track == null ? null : Track.fromJson({...track.toJson(), 'id': _library.sharedId(track)}),
        playing: playing,
        position: at,
        volume: _volume,
        muted: _muted,
        volumeLocked: isBitperfect,
        shuffle: _shuffle,
        repeat: _repeat,
        queue: queue,
        queueIndex: index,
      ),
    );
  }

  @override
  void notifyListeners() {
    _publish();
    super.notifyListeners();
  }

  // ── Lyrics ─────────────────────────────────────────────────────────────────────────────────────

  // Lyrics in LRC form ("[01:23.45] text") are shown line by line: the line being sung is highlighted and the panel
  // scrolls along. The position arrives a few times a second, so the current line is looked up slightly ahead.
  static const Duration _lyricLead = Duration(milliseconds: 200);
  List<LrcLine> _lrcLines = const [];

  /// Finds the lyrics a track carries itself (tag of a local file, server request for a server track).
  LyricsProvider? lyricsProvider;

  /// Looks lyrics up on the internet; asked only for a track without lyrics of its own, and only while
  /// [isOnlineLyricsEnabled]. Throws when the lookup could not be made.
  LyricsProvider? onlineLyricsProvider;

  String? _currentLyrics;
  bool get hasLyrics => _currentLyrics != null && _currentLyrics!.trim().isNotEmpty;

  /// The lines of time-synced lyrics; empty for plain lyrics or none.
  List<LyricLine> lyricLines = const [];

  /// Index into [lyricLines] of the line being sung; -1 before the first line.
  final ValueNotifier<int> currentLyricIndex = ValueNotifier(-1);

  bool get hasSyncedLyrics => lyricLines.isNotEmpty;
  String? get plainLyricsText => hasSyncedLyrics ? null : _currentLyrics;

  bool isLoadingLyrics = false;
  LyricsOrigin lyricsOrigin = LyricsOrigin.none;

  /// True when the internet lookup could not be made (no connection, service down), as opposed to "nothing found".
  bool lyricsLookupFailed = false;

  bool _isOnlineLyricsEnabled = true;

  /// Whether tracks without lyrics of their own are looked up online (the Settings switch).
  bool get isOnlineLyricsEnabled => _isOnlineLyricsEnabled;
  set isOnlineLyricsEnabled(bool value) {
    if (_isOnlineLyricsEnabled == value) return;
    _isOnlineLyricsEnabled = value;
    // Switched on while a track without lyrics is open: look now. Switched off while internet lyrics are shown: remove.
    if ((value && !hasLyrics) || (!value && lyricsOrigin == LyricsOrigin.online)) {
      _lyricsTrackId = null;
      _refreshLyrics();
    }
    notifyListeners();
  }

  /// True when the panel has neither lyrics nor a search in progress.
  bool get showLyricsEmptyState => !hasLyrics && !isLoadingLyrics;

  /// Why there are no lyrics, in the active language.
  String get lyricsEmptyText => lyricsLookupFailed
      ? Localizer.get('LyricsLookupFailed')
      : (isOnlineLyricsEnabled && onlineLyricsProvider != null
            ? Localizer.get('NoLyrics')
            : Localizer.get('NoLyricsInTags'));

  /// "Source: LRCLIB" or "Source: the track's own tags"; empty while there are no lyrics.
  String get lyricsSourceText => switch (lyricsOrigin) {
    LyricsOrigin.online => Localizer.format('LyricsSource', [OnlineLyrics.sourceName]),
    LyricsOrigin.tags => Localizer.get('LyricsSourceTags'),
    LyricsOrigin.none => '',
  };

  void _setLyrics(String? text) {
    _currentLyrics = text;
    _lrcLines = LrcParser.parse(text);
    currentLyricIndex.value = -1;
    lyricLines = [for (final l in _lrcLines) LyricLine(l.time, l.text)];
    // The panel may open (or the lyrics arrive) in the middle of the song: start at the right line.
    _updateLyricPosition(position.value);
  }

  /// Moves the highlight to the line that is current at [at]; cheap when nothing changed.
  void _updateLyricPosition(Duration at) {
    if (_lrcLines.isEmpty) return;
    final index = LrcParser.indexAt(_lrcLines, at + _lyricLead);
    final old = currentLyricIndex.value;
    if (index == old) return;
    for (var i = math.max(0, math.min(old, index)); i <= math.min(lyricLines.length - 1, math.max(old, index)); i++) {
      lyricLines[i].isPast = i < index;
      lyricLines[i].isActive = i == index && !lyricLines[i].isBlank;
    }
    currentLyricIndex.value = index;
  }

  /// Jumps the song to the start of a lyric line (the user tapped it).
  void seekToLyric(LyricLine? line) {
    if (line == null || currentTrack == null) return;
    seekTo(line.time);
  }

  /// Loads the lyrics of the current track, but only while the panel that shows them is open.
  void _refreshLyrics() {
    final track = currentTrack;
    if (track == null) {
      _lyricsToken?.cancel();
      _lyricsTrackId = null;
      _clearLyrics();
      return;
    }
    if (_lyricsTrackId == track.id) return; // already loaded, or loading, for this track

    _lyricsToken?.cancel();
    _clearLyrics();
    if (!_isQueueOpen || (lyricsProvider == null && onlineLyricsProvider == null)) return;

    _lyricsTrackId = track.id;
    isLoadingLyrics = true;
    final token = _lyricsToken = CancellationToken();
    unawaited(_loadLyrics(track, token));
  }

  void _clearLyrics() {
    _setLyrics(null);
    lyricsOrigin = LyricsOrigin.none;
    lyricsLookupFailed = false;
    isLoadingLyrics = false;
  }

  /// The lyrics the track carries itself come first (they are instant and belong to this very file); only when it has
  /// none, and the user allows it, the internet is asked.
  Future<void> _loadLyrics(Track track, CancellationToken ct) async {
    String? text;
    var origin = LyricsOrigin.none;
    var failed = false;

    final own = lyricsProvider;
    if (own != null) {
      try {
        text = await own(track);
      } catch (e) {
        if (!ct.isCancelled) WiretuneLog.debug('PlayerViewModel', "Lyrics unavailable for '${track.title}': $e");
      }
    }
    if (ct.isCancelled) return;

    if (text != null && text.trim().isNotEmpty) {
      origin = LyricsOrigin.tags;
    } else {
      text = null;
      final online = onlineLyricsProvider;
      if (_isOnlineLyricsEnabled && online != null) {
        try {
          text = await online(track);
          if (text != null && text.trim().isNotEmpty) {
            origin = LyricsOrigin.online;
          } else {
            text = null;
          }
        } catch (e) {
          // Not reaching the service is not the same as "no lyrics exist": say so, and ask again next time.
          if (!ct.isCancelled) {
            failed = true;
            WiretuneLog.debug('PlayerViewModel', "Online lyrics unavailable for '${track.title}': $e");
          }
        }
      }
    }

    if (ct.isCancelled || !identical(currentTrack, track)) return;
    _setLyrics(text);
    lyricsOrigin = origin;
    lyricsLookupFailed = failed;
    isLoadingLyrics = false;
    if (failed) _lyricsTrackId = null; // opening the panel again tries once more
    notifyListeners();
  }

  /// Re-renders the texts that are read in the active language.
  void refreshLocalizedTexts() => notifyListeners();

  Future<void> _runSafe(Future<void> Function() action) async {
    try {
      await action();
    } catch (e, s) {
      WiretuneLog.error('PlayerViewModel', 'Playback command failed: $e', e, s);
      errorMessage = '$e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final unsubscribe in _subscriptions) {
      unsubscribe();
    }
    _seekDebounce?.cancel();
    _lyricsToken?.cancel();
    _remoteTicker?.cancel();
    _remoteLost?.cancel();
    _remoteVolumeTimer?.cancel();
    position.dispose();
    elapsedSeconds.dispose();
    spectrum.dispose();
    currentLyricIndex.dispose();
    super.dispose();
  }
}
