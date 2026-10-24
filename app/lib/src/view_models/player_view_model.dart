// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// One entry of the queue.
class QueueItem {
  QueueItem(this.track, this.index, this.isCurrent);

  final Track track;

  /// Where the entry stands in the queue of the device that plays it. Another device's queue is shown only as far as
  /// this library knows its tracks, so there this is not always the entry's place in [PlayerViewModel.queueItems].
  int index;
  bool isCurrent;

  int get displayIndex => index + 1;
}

/// The player: the queue, shuffle and repeat, the transport, volume and modes.
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
      // The heart of the playing track follows the library's (a refresh brings another device's changes).
      _library.libraryChanged.listen((_) => notifyListeners()),
      _library.favoriteChanged.listen((_) => notifyListeners()),
      _engine.playbackFailed.listen((message) {
        errorMessage = message;
        notifyListeners();
      }),
      _engine.trackEnded.listen((_) => _onTrackEnded()),
      _engine.advanced.listen(_onAdvanced),
      _engine.positionChanged.listen((position) {
        _localPosition = position;
        if (!_isUserSeeking && !isRemote) _setPosition(position);
        _publishIfDrifted(position);
        if (_sessionRestored &&
            _state == PlaybackState.playing &&
            DateTime.now().difference(_placeSavedAt) > _placeSaveInterval) {
          _save(_savePlace);
        }
      }),
      _engine.trackChanged.listen(_onEngineTrackChanged),
      _engine.bitPerfectChanged.listen((value) {
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
    notifyListeners();
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

  /// What plays: the current track, whether it plays and the queue it is in. Told only when one of them changes, for
  /// what marks the playing track (rows, tiles, their Plays) and needs nothing else of the player (its volume, its
  /// modes).
  final ValueNotifier<({String? track, bool playing, Object queue})> nowPlaying = ValueNotifier((
    track: null,
    playing: false,
    queue: const <Track>[],
  ));

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
  bool get isBitPerfect => _engine.isBitPerfect;
  String? errorMessage;

  QualityTier get currentTier => currentTrack?.format.tier ?? QualityTier.silver;
  String get currentTagSpec => currentTrack?.format.tagSpec ?? '';

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
  bool get isPlaying => playbackState == PlaybackState.playing;

  /// Bit-perfect pins the volume at 100 % (also on the device being controlled).
  bool get isVolumeLocked => isRemote ? (_remoteState?.volumeLocked ?? false) : isBitPerfect;
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
    if (value) _updateQueueState();
    notifyListeners();
  }

  List<Track> get queueTracks => isRemote ? [for (final item in _remoteQueue) item.track] : _queueTracks;
  List<QueueItem> get queueItems => isRemote ? _remoteQueue : _queueItems;
  int get currentQueueIndex => isRemote ? _remoteQueue.indexWhere((item) => item.isCurrent) : _queueIndex;

  /// Whether the queue is [tracks] (an album, an artist, a playlist, a list page) in any order, as their Play, their
  /// menu's Shuffle or one of their rows started it, with a track loaded: their Play button then pauses and resumes it.
  /// A single track is whenever it is the one loaded, whatever the queue. A device being controlled holds at most
  /// [RemoteRules.maxQueueLength] of a longer list.
  bool isQueueOf(List<Track> tracks) {
    final current = currentTrack;
    if (tracks.isEmpty || current == null) return false;
    if (tracks.length == 1) return tracks.single.id == current.id;
    final queue = isRemote ? queueTracks : _originalQueue;
    final length = isRemote ? math.min(tracks.length, RemoteRules.maxQueueLength) : tracks.length;
    if (queue.length != length) return false;
    final ids = {for (final track in tracks) track.id};
    return queue.every((track) => ids.contains(track.id));
  }

  void toggleQueue() => isQueueOpen = !isQueueOpen;

  void closeQueue() => isQueueOpen = false;

  /// Plays a track of the queue; a track that is not queued yet starts the library.
  /// Plays [item], the entry itself: the same track may be queued more than once.
  void playQueueItem(QueueItem item) {
    if (isRemote) {
      _sendRemote(RemoteCommand(RemoteAction.playIndex, index: item.index));
    } else if (_isEntry(item)) {
      _playAt(item.index);
    }
  }

  /// Whether [item] is still the entry of this device's queue it was made for.
  bool _isEntry(QueueItem item) =>
      item.index >= 0 && item.index < _playbackQueue.length && identical(_playbackQueue[item.index], item.track);

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

  /// Moves the entry at [oldIndex] of [queueItems] to [newIndex], counted after it has been taken out.
  void moveQueueTrack(int oldIndex, int newIndex) {
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex == newIndex) return;

    if (isRemote) {
      if (oldIndex >= _remoteQueue.length || newIndex >= _remoteQueue.length) return;
      // The device counts in its whole queue, with the tracks this library doesn't know (and doesn't list): the entry
      // goes to where the one listed at [newIndex] stands there.
      final from = _remoteQueue[oldIndex].index;
      final to = _remoteQueue[newIndex].index;
      final item = _remoteQueue.removeAt(oldIndex);
      _remoteQueue.insert(newIndex, item);
      _shiftRemoteIndices(removed: from, inserted: to);
      item.index = to;
      notifyListeners();
      _sendRemote(RemoteCommand(RemoteAction.moveTrack, index: from, toIndex: to));
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

    // By position: the same track may be queued more than once.
    if (_queueIndex >= 0) {
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
    final at = item == null ? -1 : queueItems.indexOf(item);
    if (at > 0) moveQueueTrack(at, at - 1);
  }

  void moveQueueTrackDown(QueueItem? item) {
    final at = item == null ? -1 : queueItems.indexOf(item);
    if (at >= 0 && at < queueItems.length - 1) moveQueueTrack(at, at + 1);
  }

  /// Takes [item], the entry itself, out of the queue.
  void removeQueueItem(QueueItem item) {
    if (isRemote) {
      if (!_remoteQueue.remove(item)) return;
      _shiftRemoteIndices(removed: item.index);
      notifyListeners();
      _sendRemote(RemoteCommand(RemoteAction.removeTrack, index: item.index));
    } else if (_isEntry(item)) {
      _removeAt(item.index);
    }
  }

  void _removeAt(int index) {
    final removedCurrent = index == _queueIndex;
    final track = _playbackQueue.removeAt(index);
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

  /// Counts the other device's queue as it will after taking out the entry at [removed] (and putting it back at
  /// [inserted]), so that a second change before its next state still names the right entries.
  void _shiftRemoteIndices({required int removed, int? inserted}) {
    for (final other in _remoteQueue) {
      if (other.index > removed) other.index--;
      if (inserted != null && other.index >= inserted) other.index++;
    }
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
    _offerNext();
  }

  // ── Gapless ────────────────────────────────────────────────────────────────────────────────────
  // The engine always knows the entry that comes after the current one, so the driver can start it the moment the
  // current track ends; every change of the queue, repeat or sleep timer tells it again.

  /// The entry given to the engine as the next one; -1 for none.
  int _nextIndex = -1;
  Track? _nextOffered;
  bool _isGaplessEnabled = true;

  /// Whether the next entry starts without a gap; on by default. Off, each track is opened after the last one ended.
  bool get isGaplessEnabled => _isGaplessEnabled;
  set isGaplessEnabled(bool value) {
    if (_isGaplessEnabled == value) return;
    _isGaplessEnabled = value;
    _offerNext();
  }

  /// The entry that plays after the current one: the same one again with repeat one, the first after the last with
  /// repeat all; none when gapless playback is off or the sleep timer waits for the end of the track.
  int _followingIndex() {
    if (!_isGaplessEnabled || _sleepAtTrackEnd || _queueIndex < 0 || _queueIndex >= _playbackQueue.length) return -1;
    if (_repeat == RepeatMode.one) return _queueIndex;
    if (_queueIndex + 1 < _playbackQueue.length) return _queueIndex + 1;
    return _repeat == RepeatMode.all ? 0 : -1;
  }

  void _offerNext() {
    _nextIndex = _followingIndex();
    final track = _nextIndex < 0 ? null : _playbackQueue[_nextIndex];
    if (identical(track, _nextOffered)) return;
    _nextOffered = track;
    _runSafe(() => _engine.setNextTrack(track));
  }

  /// The driver went on to the next entry without a gap: it is the current one now.
  void _onAdvanced(Track track) {
    // The entry offered, or (the queue changed in the same moment) the track's entry after the current one.
    var index = _nextIndex >= 0 && identical(_playbackQueue[_nextIndex], track) ? _nextIndex : -1;
    if (index < 0) index = _playbackQueue.indexWhere((t) => identical(t, track), math.max(0, _queueIndex + 1));
    if (index < 0) index = _playbackQueue.indexWhere((t) => identical(t, track));
    if (index < 0) return;
    _queueIndex = index;
    _nextOffered = null; // offered again for the new current entry
    _updateQueueState();
    notifyListeners();
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

  /// Puts [tracks] right after the current track, also while shuffling; with nothing queued they simply play.
  void playNext(List<Track> tracks) => _addToQueue(tracks, next: true);

  /// Puts [tracks] at the end of the queue; with nothing queued they simply play.
  void addToQueue(List<Track> tracks) => _addToQueue(tracks, next: false);

  void _addToQueue(List<Track> tracks, {required bool next}) {
    if (tracks.isEmpty) return;
    if (isRemote) {
      final ids = [for (final track in tracks.take(RemoteRules.maxQueueLength)) _library.sharedId(track)];
      _sendRemote(RemoteCommand(next ? RemoteAction.playNext : RemoteAction.addToQueue, trackIds: ids));
      return;
    }
    _queueLocal(tracks, next: next);
  }

  void _queueLocal(List<Track> tracks, {required bool next}) {
    if (_playbackQueue.isEmpty) {
      _playQueueInternal(tracks, null);
      notifyListeners();
      return;
    }
    if (next) {
      // After the current entry (or, past the end, where playing goes on); in the unshuffled order after its track.
      final at = math.min(_queueIndex + 1, _playbackQueue.length);
      _playbackQueue.insertAll(math.max(0, at), tracks);
      final current = _queueIndex >= 0 && _queueIndex < _playbackQueue.length ? _playbackQueue[_queueIndex] : null;
      final original = current == null ? -1 : _originalQueue.indexOf(current);
      _originalQueue.insertAll(original < 0 ? _originalQueue.length : original + 1, tracks);
    } else {
      _playbackQueue.addAll(tracks);
      _originalQueue.addAll(tracks);
    }
    _updateQueueState();
    notifyListeners();
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
    _resumeAt = null;
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

  /// Restarts the current track when more than three seconds have played, otherwise goes to the previous one; with
  /// [restart] false (a swipe, which shows the track before coming in) it always goes to the previous one.
  void previousTrack({bool restart = true}) =>
      isRemote ? _sendRemote(const RemoteCommand(RemoteAction.previous)) : _previousTrackLocal(restart: restart);

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
    _offerNext();
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
          _playAt(_queueIndex, start: _resumeAt ?? Duration.zero);
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

  void _previousTrackLocal({required bool restart}) {
    if (_playbackQueue.isEmpty) return;
    // The position shown is this device's own, except while it controls another one.
    final at = isRemote ? _localPosition : position.value;
    if (restart && at > const Duration(seconds: 3)) {
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
    _library.toggleFavorite(current.id);
  }

  Future<void> toggleBitPerfect() => _engine.setBitPerfectMode(!isBitPerfect);

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
    if (!isRemote && _resumeAt != null) {
      // The queue picked up after a restart has not started yet: play will start from here.
      _resumeAt = target;
      _localPosition = target;
      return;
    }
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
    if (!isBitPerfect) _engine.setVolume(_volume / 100.0);
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
    if (isBitPerfect || _muted == muted) return;
    _muted = muted;
    _engine.setMuted(_muted);
    notifyListeners();
  }

  // ── Sleep timer ────────────────────────────────────────────────────────────────────────────────

  Timer? _sleepTimer;
  DateTime? _sleepAt;
  bool _sleepAtTrackEnd = false;

  /// When the sleep timer pauses the music; null while it is off or waits for the end of the track.
  DateTime? get sleepAt => _sleepAt;

  /// Whether the sleep timer pauses this device's music when its track ends.
  bool get sleepsAtTrackEnd => _sleepAtTrackEnd;

  /// Pauses the music (of the device being controlled, while one is) after [after]; null turns the timer off.
  void setSleepTimer(Duration? after) {
    _cancelSleep();
    if (after != null) {
      _sleepAt = DateTime.now().add(after);
      _sleepTimer = Timer(after, () {
        _cancelSleep();
        unawaited(pause());
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Pauses this device's music when the track that plays ends; the next one waits for play.
  void sleepAtTrackEnd() {
    _cancelSleep();
    _sleepAtTrackEnd = true;
    _offerNext();
    notifyListeners();
  }

  void _cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    if (!_sleepAtTrackEnd) return;
    _sleepAtTrackEnd = false;
    _offerNext();
  }

  // ── Resuming after a restart ───────────────────────────────────────────────────────────────────
  // The queue (both orders, as track IDs) is saved when it changes, the place in it (the entry, its position, shuffle and
  // repeat) when that changes and every half minute while playing: a restart, even one the system forced, picks up
  // close to where the music was.

  static const String _queuePreference = 'session_queue';
  static const String _placePreference = 'session_place';
  static const Duration _placeSaveInterval = Duration(seconds: 30);
  int _savedQueueVersion = -1;
  (int, bool, RepeatMode, PlaybackState)? _savedPlace;
  DateTime _placeSavedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Nothing is saved before the saved queue was looked at, so that it is not overwritten by the empty one.
  bool _sessionRestored = false;

  /// Where the queue picked up after a restart starts when played; null once something played.
  Duration? _resumeAt;

  /// Picks up the queue saved before the app last closed, as far as this library still has its tracks: the entry that
  /// played is shown paused where it was, and play goes on from there. Does nothing once something is queued.
  void restoreSession() {
    try {
      final queueJson = _library.getPreference(_queuePreference);
      final placeJson = _library.getPreference(_placePreference);
      if (queueJson == null || queueJson.isEmpty || _playbackQueue.isNotEmpty) return;
      final queue = jsonDecode(queueJson) as Map<String, Object?>;
      final place = placeJson == null || placeJson.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(placeJson) as Map<String, Object?>;
      List<String> ids(Object? list) => [for (final id in list as List? ?? const []) '$id'];
      final playing = ids(queue['playing']);
      final index = (place['index'] as num?)?.toInt() ?? -1;
      // A track the library no longer has is left out; the entry that played keeps its place among the others.
      final kept = <Track>[];
      var at = index >= playing.length ? -2 : -1;
      var keptCurrent = false;
      for (var i = 0; i < playing.length; i++) {
        final track = _library.getTrack(playing[i]);
        if (i == index) {
          at = kept.length;
          keptCurrent = track != null;
        }
        if (track != null) kept.add(track);
      }
      if (kept.isEmpty) return;
      final original = [for (final id in ids(queue['original'])) ?_library.getTrack(id)];

      _shuffle = place['shuffle'] == true;
      _repeat = RepeatMode.values.asNameMap()[place['repeat']] ?? RepeatMode.off;
      _playbackQueue.addAll(kept);
      _originalQueue.addAll(original.isEmpty ? kept : original);
      // Past the end (the queue had finished), at its start when nothing was chosen.
      _queueIndex = at == -2 ? kept.length : math.min(math.max(at, 0), kept.length - 1);
      _updateQueueState();
      _savedQueueVersion = _queueVersion;
      if (_queueIndex < kept.length) {
        final track = kept[_queueIndex];
        final saved = Duration(milliseconds: (place['position'] as num?)?.toInt() ?? 0);
        final start = keptCurrent && saved < track.duration - const Duration(seconds: 2) ? saved : Duration.zero;
        _resumeAt = start;
        _localPosition = start;
        _setPosition(start);
        currentTrack = track;
      }
      _savedPlace = _place;
      notifyListeners();
    } catch (e) {
      WiretuneLog.warn('PlayerViewModel', 'The saved queue could not be picked up: $e');
    } finally {
      _sessionRestored = true;
    }
  }

  /// Saves the queue and the place in it now (the window is closing).
  void saveSession() {
    if (!_sessionRestored) return;
    try {
      _saveQueue();
      _savePlace();
    } catch (e) {
      WiretuneLog.warn('PlayerViewModel', 'The queue could not be saved: $e');
    }
  }

  (int, bool, RepeatMode, PlaybackState) get _place => (_queueIndex, _shuffle, _repeat, _state);

  /// Saves what changed since the last save; called at each change of the player's state.
  void _saveChanges() {
    if (!_sessionRestored) return;
    if (_queueVersion != _savedQueueVersion) _save(_saveQueue);
    if (_place != _savedPlace) _save(_savePlace);
  }

  /// Bookkeeping: a failure is logged, never shown.
  static void _save(void Function() write) {
    try {
      write();
    } catch (e) {
      WiretuneLog.debug('PlayerViewModel', 'Saving the queue failed: $e');
    }
  }

  void _saveQueue() {
    _savedQueueVersion = _queueVersion;
    _library.setPreference(
      _queuePreference,
      _playbackQueue.isEmpty
          ? ''
          : jsonEncode({
              'playing': [for (final track in _playbackQueue) track.id],
              'original': [for (final track in _originalQueue) track.id],
            }),
    );
  }

  void _savePlace() {
    _savedPlace = _place;
    _placeSavedAt = DateTime.now();
    _library.setPreference(
      _placePreference,
      jsonEncode({
        'index': _queueIndex,
        'position': _localPosition.inMilliseconds,
        'shuffle': _shuffle,
        'repeat': _repeat.name,
      }),
    );
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
      try {
        _library.recordPlay(track.id);
      } catch (e) {
        WiretuneLog.debug('PlayerViewModel', 'Recording a play failed: $e');
      }
    }
    notifyListeners();
  }

  void _onTrackEnded() {
    if (_sleepAtTrackEnd) {
      // The sleep timer: the next entry waits, shown paused at its start, for play.
      _cancelSleep();
      final next = _queueIndex + 1 < _playbackQueue.length ? _queueIndex + 1 : (_repeat == RepeatMode.all ? 0 : -1);
      if (next >= 0 && _repeat != RepeatMode.one) {
        _queueIndex = next;
        _updateQueueState();
        _resumeAt = Duration.zero;
        _localPosition = Duration.zero;
        _setPosition(Duration.zero);
        currentTrack = _playbackQueue[next];
      }
      notifyListeners();
      return;
    }
    if (_repeat == RepeatMode.one && _queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
      _playAt(_queueIndex);
    } else if (_queueIndex < _playbackQueue.length - 1 || _repeat == RepeatMode.all) {
      _nextTrackLocal();
    }
  }

  void _setPosition(Duration value) {
    position.value = value;
    elapsedSeconds.value = value.inSeconds;
  }

  /// Whether [track] is the one playing (on the device being controlled): the lists highlight it.
  bool isCurrent(Track track) => currentTrack?.id == track.id;

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
      notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
        _previousTrackLocal(restart: true);
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
        if (command.index >= 0 && command.index < _playbackQueue.length) _removeAt(command.index);
      case RemoteAction.clearQueue:
        clearQueue();
      case RemoteAction.playNext || RemoteAction.addToQueue:
        // The tracks this library has, in their order; one it lacks is left out.
        _queueLocal(_library.resolveTracks(command.trackIds), next: command.action == RemoteAction.playNext);
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
      isBitPerfect,
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
        volumeLocked: isBitPerfect,
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
    _saveChanges();
    nowPlaying.value = (track: currentTrack?.id, playing: isPlaying, queue: isRemote ? _remoteQueue : _queueTracks);
    super.notifyListeners();
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
    _remoteTicker?.cancel();
    _remoteLost?.cancel();
    _remoteVolumeTimer?.cancel();
    _sleepTimer?.cancel();
    position.dispose();
    elapsedSeconds.dispose();
    nowPlaying.dispose();
    spectrum.dispose();
    super.dispose();
  }
}
