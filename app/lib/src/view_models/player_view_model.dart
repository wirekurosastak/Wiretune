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
/// With [attachListenTogether] it can listen together with players of other accounts: as the host, it tells them what
/// it plays; as a member, it plays what the host plays, where the host is, and asks the host to skip, seek and queue.
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
        _localPositionAt = DateTime.now();
        _countWhenPlayed(position);
        if (!_isUserSeeking && !isRemote) _setPosition(position);
        _publishIfDrifted(position);
        _publishGroupIfDrifted(position);
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

  /// Which queue it is: counts up whenever another takes its place (played, cleared, the host's), so that an Undo
  /// leaves the new one alone even where it holds the same tracks.
  int _queueRun = 0;
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

  /// When the engine last told [_localPosition].
  DateTime _localPositionAt = DateTime.now();
  Duration _startAt = Duration.zero;
  double _volume = 100;
  bool _muted = false;

  /// The level the speaker unmutes 0 % to: the last one the volume came to rest at above 0.
  double _restingVolume = 100;
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

  /// The spectrum bands (0..1), about 30 times a second while playing. While something listens (a spectrum on screen),
  /// the engine is told so: a phone analyses only then.
  late final ValueNotifier<Float32List> spectrum = _Spectrum((shown) => _engine.spectrumShown = shown);

  double get positionSeconds => position.value.inMicroseconds / 1e6;
  Duration get duration => currentTrack?.duration ?? Duration.zero;
  double get durationSeconds => duration.inMicroseconds / 1e6;

  double get volume => isRemote ? (_remoteVolume ?? _remoteState?.volume ?? 100) : _volume;

  /// Muted, or at 0 %.
  bool get isMuted => (isRemote ? (_remoteState?.muted ?? false) : _muted) || (volume == 0 && !isVolumeLocked);
  bool get isShuffle => isRemote ? (_remoteState?.shuffle ?? false) : _shuffle;
  RepeatMode get repeatMode => isRemote ? (_remoteState?.repeat ?? RepeatMode.off) : _repeat;

  bool get isExclusiveMode => _engine.isExclusiveMode;
  bool get isBitPerfect => _engine.isBitPerfect;
  String? errorMessage;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
  bool get isPlaying => playbackState == PlaybackState.playing;

  /// Bit-perfect pins the volume at 100 % (also on the device being controlled).
  bool get isVolumeLocked => isRemote ? (_remoteState?.volumeLocked ?? false) : isBitPerfect;
  bool get isVolumeDisabledOrMuted => isMuted || isVolumeLocked;
  String get volumeToolTip =>
      Localizer.get(isMuted ? 'VolumeUnmute' : (isVolumeLocked ? 'VolumeLocked' : 'VolumeMute'));

  /// Title of the current track, or a hint when nothing is loaded.
  String get nowPlayingTitle => currentTrack?.title ?? Localizer.get('NothingPlaying');

  /// The name of what the queue was played from (an album, an artist, a playlist, a page), in the language shown; null
  /// when that isn't known (queued a track at a time, from another device, or before a restart).
  String? get playingFrom => _playingFrom?.call();
  String Function()? _playingFrom;

  /// What the queue was played from, for the way back to it: an [Album], an [Artist], a [Playlist], or the section of a
  /// page of tracks (Tracks, Favorites); null when that isn't known.
  Object? get playingSource => _playingSource;
  Object? _playingSource;

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

  /// Where [queueItems] go on after the playing track: the phone's queue opens there ("Next", 2, 3 …), as Spotify's and
  /// TIDAL's do, and counts what is from there. 0, the whole queue, while none plays.
  int get upcomingQueueStart => queueItems.indexWhere((item) => item.isCurrent) + 1;

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

  /// Plays [item], the entry itself: the same track may be queued more than once.
  void playQueueItem(QueueItem item) {
    if (isFollowingHost) {
      if (_isEntry(item)) _askHost(RemoteCommand(RemoteAction.playIndex, index: _hostIndices[item.index]));
    } else if (isRemote) {
      _sendRemote(RemoteCommand(RemoteAction.playIndex, index: item.index));
    } else if (_isEntry(item)) {
      _playAt(item.index);
    }
  }

  /// Whether [item] is still the entry of this device's queue it was made for.
  bool _isEntry(QueueItem item) =>
      item.index >= 0 && item.index < _playbackQueue.length && identical(_playbackQueue[item.index], item.track);

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
    if (index >= 0 && isFollowingHost) {
      _askHost(RemoteCommand(RemoteAction.playIndex, index: _hostIndices[index]));
    } else if (index >= 0) {
      _playAt(index);
    } else {
      _leaveForOwnMusic();
      _playQueueInternal(_library.tracks.isNotEmpty ? _library.tracks : [track], track);
    }
  }

  /// Moves the entry at [oldIndex] of [queueItems] to [newIndex], counted after it has been taken out.
  void moveQueueTrack(int oldIndex, int newIndex) {
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex == newIndex) return;
    if (isFollowingHost) {
      if (oldIndex < _hostIndices.length && newIndex < _hostIndices.length) {
        _askHost(RemoteCommand(RemoteAction.moveTrack, index: _hostIndices[oldIndex], toIndex: _hostIndices[newIndex]));
      }
      return;
    }

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

  /// Takes [item], the entry itself, out of the queue. Returns what puts it back where it was, for an entry of this
  /// device's own queue that wasn't playing, while that queue lasts; null otherwise (the music has moved on, or another
  /// device's queue).
  VoidCallback? removeQueueItem(QueueItem item) {
    if (isFollowingHost) {
      if (_isEntry(item)) _askHost(RemoteCommand(RemoteAction.removeTrack, index: _hostIndices[item.index]));
    } else if (isRemote) {
      if (!_remoteQueue.remove(item)) return null;
      _shiftRemoteIndices(removed: item.index);
      notifyListeners();
      _sendRemote(RemoteCommand(RemoteAction.removeTrack, index: item.index));
    } else if (_isEntry(item)) {
      return _removeAt(item.index);
    }
    return null;
  }

  VoidCallback? _removeAt(int index) {
    final removedCurrent = index == _queueIndex;
    final track = _playbackQueue.removeAt(index);
    // Also while shuffled, or turning shuffle off would bring the track back.
    final original = _originalQueue.indexOf(track);
    if (original >= 0) _originalQueue.removeAt(original);

    if (removedCurrent) {
      _carryOnFrom(index - 1);
      return null;
    }

    if (index < _queueIndex) _queueIndex--;
    _updateQueueState();
    notifyListeners();
    // Where it goes back: after the entry it followed, or before the one that followed it.
    final (anchor, after) = index > 0 ? (_playbackQueue[index - 1], true) : (_playbackQueue.firstOrNull, false);
    if (anchor == null) return null;
    final originalAnchor = original > 0 ? _originalQueue[original - 1] : null;
    final run = _queueRun;
    return () {
      if (_queueRun == run) _requeue(track, anchor: anchor, after: after, originalAnchor: originalAnchor);
    };
  }

  /// Puts [track] back next to [anchor] (after it, or before it), and in the unshuffled order after [originalAnchor]
  /// (first when null); when [anchor] is no longer queued, nothing.
  void _requeue(Track track, {required Track anchor, required bool after, required Track? originalAnchor}) {
    final place = _playbackQueue.indexWhere((t) => identical(t, anchor));
    if (place < 0) return;
    final at = after ? place + 1 : place;
    _playbackQueue.insert(at, track);
    final original = switch (originalAnchor) {
      null => 0,
      final anchor => switch (_originalQueue.indexWhere((t) => identical(t, anchor))) {
        -1 => _originalQueue.length,
        final i => i + 1,
      },
    };
    _originalQueue.insert(original, track);
    if (at <= _queueIndex) _queueIndex++;
    _updateQueueState();
    notifyListeners();
  }

  /// The playing track was taken out of the queue: carry on with whatever followed it, now after [before] (or stop at
  /// the end).
  void _carryOnFrom(int before) {
    _queueIndex = before;
    _updateQueueState();
    if (_playbackQueue.isNotEmpty) {
      _nextTrackLocal();
    } else {
      _runSafe(_engine.stop);
    }
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
    if (isFollowingHost) return; // the host's queue, which plays for everyone
    if (isRemote) {
      final current = _remoteQueue.where((item) => item.isCurrent).firstOrNull;
      _remoteQueue = current != null ? [current] : [];
      notifyListeners();
      _sendRemote(const RemoteCommand(RemoteAction.clearQueue));
      return;
    }
    final current =
        _currentTrack ?? (_queueIndex >= 0 && _queueIndex < _playbackQueue.length ? _playbackQueue[_queueIndex] : null);
    _queueRun++;
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
  /// Autoplay: when the queue runs out, music like what played last goes on ([autoplayTracks]); on by default.
  bool isAutoplayEnabled = true;

  /// How many tracks autoplay adds at a time.
  static const int autoplayCount = 20;

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

  /// Replaces the queue with [tracks] and starts [startTrack] (the first track, or a random one when shuffling). [from]
  /// names what they are ([playingFrom]), and [source] is what they come from ([playingSource]).
  void playQueue(Iterable<Track> tracks, [Track? startTrack, String Function()? from, Object? source]) {
    _leaveForOwnMusic();
    _playingFor = null; // this account's own music again
    // Music of the listener's choosing: what they skipped of Autoplay's no longer counts against it.
    _autoplayed.clear();
    _skippedArtists.clear();
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
    _playingFrom = from;
    _playingSource = from == null ? null : source;
    notifyListeners();
  }

  /// Switches shuffle on and plays [tracks] from a random one: the "Shuffle" button of a list.
  void shuffleQueue(List<Track> tracks, [String Function()? from]) {
    if (tracks.isEmpty) return;
    setShuffle(true);
    playQueue(tracks, null, from);
  }

  /// Puts [tracks] right after the current track, also while shuffling; with nothing queued they simply play. Returns
  /// what takes them out again ([_unqueue]): null when they started playing, or went to the device being controlled.
  VoidCallback? playNext(List<Track> tracks) => _addToQueue(tracks, next: true);

  /// Puts [tracks] at the end of the queue; with nothing queued they simply play. Returns what takes them out again, as
  /// [playNext] does.
  VoidCallback? addToQueue(List<Track> tracks) => _addToQueue(tracks, next: false);

  VoidCallback? _addToQueue(List<Track> tracks, {required bool next}) {
    if (tracks.isEmpty) return null;
    if (isRemote || isFollowingHost) {
      final ids = [for (final track in tracks.take(RemoteRules.maxQueueLength)) _library.sharedId(track)];
      final command = RemoteCommand(next ? RemoteAction.playNext : RemoteAction.addToQueue, trackIds: ids);
      isFollowingHost ? _askHost(command) : _sendRemote(command);
      return null;
    }
    return _queueLocal(tracks, next: next);
  }

  VoidCallback? _queueLocal(List<Track> tracks, {required bool next}) {
    if (_playbackQueue.isEmpty) {
      _playQueueInternal(tracks, null);
      notifyListeners();
      return null;
    }
    final entries = List.of(tracks);
    final int at, original;
    if (next) {
      // After the current entry (or, past the end, where playing goes on); in the unshuffled order after its track.
      at = math.max(0, math.min(_queueIndex + 1, _playbackQueue.length));
      _playbackQueue.insertAll(at, entries);
      final current = _queueIndex >= 0 && _queueIndex < _playbackQueue.length ? _playbackQueue[_queueIndex] : null;
      final index = current == null ? -1 : _originalQueue.indexOf(current);
      original = index < 0 ? _originalQueue.length : index + 1;
      _originalQueue.insertAll(original, entries);
    } else {
      at = _playbackQueue.length;
      original = _originalQueue.length;
      _playbackQueue.addAll(entries);
      _originalQueue.addAll(entries);
    }
    _updateQueueState();
    notifyListeners();
    return () => _unqueue(entries, at: at, original: original);
  }

  /// Takes [entries], queued together at [at] (in the unshuffled order at [original]), out of the queue again, wherever
  /// they have moved since; when the queue no longer holds them together (shuffled, or changed in between), nothing.
  /// The playing one among them gives way to what follows them.
  void _unqueue(List<Track> entries, {required int at, required int original}) {
    final start = _runOf(_playbackQueue, entries, near: at);
    if (start < 0) return;
    final originalStart = _runOf(_originalQueue, entries, near: original);
    _playbackQueue.removeRange(start, start + entries.length);
    if (originalStart >= 0) _originalQueue.removeRange(originalStart, originalStart + entries.length);
    if (_queueIndex >= start + entries.length) {
      _queueIndex -= entries.length;
    } else if (_queueIndex >= start) {
      _carryOnFrom(start - 1);
      return;
    }
    _updateQueueState();
    notifyListeners();
  }

  /// Where in [queue] [entries] stand together, the run nearest [near]; -1 when nowhere.
  static int _runOf(List<Track> queue, List<Track> entries, {required int near}) {
    bool runsAt(int start) {
      for (var i = 0; i < entries.length; i++) {
        if (!identical(queue[start + i], entries[i])) return false;
      }
      return true;
    }

    var best = -1;
    for (var start = 0; start + entries.length <= queue.length; start++) {
      if (runsAt(start) && (best < 0 || (start - near).abs() < (best - near).abs())) best = start;
    }
    return best;
  }

  void _playQueueInternal(Iterable<Track> tracks, Track? startTrack, {Duration start = Duration.zero}) {
    final list = tracks.toList();
    if (list.isEmpty) return;
    _playingFrom = null;
    _playingSource = null;
    _originalQueue
      ..clear()
      ..addAll(list);

    final first = startTrack != null && _originalQueue.contains(startTrack) ? startTrack : null;
    _queueRun++;
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

  Future<void> togglePlayPause() => isRemote
      ? _sendRemote(const RemoteCommand(RemoteAction.toggle))
      : isFollowingHost
      ? _setPausedHere(!_pausedHere)
      : _togglePlayPauseLocal();

  Future<void> play() => isRemote
      ? _sendRemote(const RemoteCommand(RemoteAction.play))
      : isFollowingHost
      ? _setPausedHere(false)
      : _playLocal();

  Future<void> pause() => isRemote
      ? _sendRemote(const RemoteCommand(RemoteAction.pause))
      : isFollowingHost
      ? _setPausedHere(true)
      : _pauseLocal();

  Future<void> stop() => isRemote ? _sendRemote(const RemoteCommand(RemoteAction.stop)) : _runSafe(_engine.stop);

  void nextTrack() => isRemote
      ? _sendRemote(const RemoteCommand(RemoteAction.next))
      : isFollowingHost
      ? _askHost(const RemoteCommand(RemoteAction.next))
      : _nextTrackLocal();

  /// Restarts the current track when more than three seconds have played, otherwise goes to the previous one; with
  /// [restart] false (a swipe, which shows the track before coming in) it always goes to the previous one.
  void previousTrack({bool restart = true}) => isRemote
      ? _sendRemote(const RemoteCommand(RemoteAction.previous))
      : isFollowingHost
      ? _askHost(const RemoteCommand(RemoteAction.previous))
      : _previousTrackLocal(restart: restart);

  void toggleShuffle() => setShuffle(!isShuffle);

  /// Reorders the rest of the running queue without interrupting the current track.
  void setShuffle(bool value) => isRemote
      ? _sendRemote(RemoteCommand(RemoteAction.shuffle, on: value))
      : isFollowingHost
      ? _askHost(RemoteCommand(RemoteAction.shuffle, on: value))
      : _setShuffleLocal(value);

  void toggleRepeat() => setRepeatMode(switch (repeatMode) {
    RepeatMode.off => RepeatMode.all,
    RepeatMode.all => RepeatMode.one,
    RepeatMode.one => RepeatMode.off,
  });

  void setRepeatMode(RepeatMode mode) => isRemote
      ? _sendRemote(RemoteCommand(RemoteAction.repeat, repeat: mode))
      : isFollowingHost
      ? _askHost(RemoteCommand(RemoteAction.repeat, repeat: mode))
      : _setRepeatLocal(mode);

  /// The entry offered ahead depends on the mode (repeat one: the same track again), so it is offered anew.
  void _setRepeatLocal(RepeatMode mode) {
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
    } else if (_autoplays && _autoplayAppended()) {
      _playAt(_queueIndex + 1);
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
      if (isFollowingHost) {
        // The host seeks, and everyone follows it there.
        _isUserSeeking = false;
        _askHost(RemoteCommand(RemoteAction.seek, position: target));
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

  /// A volume set, by the slider or another device, unmutes.
  void _setVolumeLocal(double value) {
    _volume = value.clamp(0, 100);
    if (!isBitPerfect) _engine.setVolume(_volume / 100.0);
    _setMutedLocal(false);
    notifyListeners();
  }

  /// Turns the volume by [by], as a key or the mouse's wheel does.
  void stepVolume(double by) {
    if (isVolumeLocked) return;
    setVolume(volume + by);
    settleVolume();
  }

  /// The volume at rest (the slider let go, a step taken): above 0, it is the level unmuting 0 % brings back.
  void settleVolume() {
    if (volume > 0) _restingVolume = volume;
  }

  void toggleMute() {
    if (volume == 0 && !isVolumeLocked) {
      setVolume(_restingVolume);
      return;
    }
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
    _localPositionAt = DateTime.now();
    _startAt = Duration.zero;
    currentTrack = track;
    if (!isRemote) _setPosition(_localPosition);
    // An Autoplay track left before it counted: a skip, which steers Autoplay away from its artists.
    final left = _uncounted;
    if (left != null && _autoplayed.contains(left.id)) {
      _skippedArtists.addAll([
        for (final name in [...left.artistNames, ...left.albumArtistNames]) RelatedMusic.key(name),
      ]);
    }
    // Music another account cast here counts for that account (its player counts it), not for this one.
    _uncounted = _playingFor == null ? track : null;
    _listenedFor = Duration.zero;
    _listenedFrom = _localPosition;
    _countWhenPlayed(_localPosition);
    notifyListeners();
  }

  /// The track that plays here and hasn't counted as played yet, how much of it was heard, and where it stood last.
  Track? _uncounted;
  Duration _listenedFor = Duration.zero;
  Duration _listenedFrom = Duration.zero;

  /// The track now stands at [position]: once enough of it was heard ([Track.countsAfter]) it counts as played. A jump
  /// in it isn't listening.
  void _countWhenPlayed(Duration position) {
    final track = _uncounted;
    if (track == null) return;
    final step = position - _listenedFrom;
    _listenedFrom = position;
    if (step > Duration.zero && step < const Duration(seconds: 3)) _listenedFor += step;
    if (_listenedFor < track.countsAfter) return;
    _uncounted = null;
    // Bookkeeping only: no error banner when it fails.
    try {
      _library.recordPlay(track.id);
    } catch (e) {
      WiretuneLog.debug('PlayerViewModel', 'Recording a play failed: $e');
    }
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
    } else if (_autoplays && _autoplayAppended()) {
      // The queue ran out: music like it goes on. With nothing like it, the last track stays, stopped.
      _playAt(_queueIndex + 1);
    }
  }

  /// Adds autoplay's tracks to the end of the queue and says it plays from Autoplay; false when there are none.
  bool _autoplayAppended() {
    final tracks = autoplayTracks(_playbackQueue);
    if (tracks.isEmpty) return false;
    _playbackQueue.addAll(tracks);
    _originalQueue.addAll(tracks);
    _autoplayed.addAll([for (final track in tracks) track.id]);
    _updateQueueState();
    _playingFrom = () => Localizer.get('Autoplay');
    _playingSource = null;
    return true;
  }

  /// Whether the end of the queue goes on with autoplay: it is on, and the queue is this account's own (not a group's
  /// that another player leads, nor another account's playing here).
  bool get _autoplays => isAutoplayEnabled && _hostState == null && _playingFor == null;

  /// Tracks like the last ones of [queue] to go on with, up to [autoplayCount], as the library's [RelatedMusic] picks
  /// them for this account: leaning towards what it loves and plays, away from what it played lately and the artists it
  /// skipped since the music went on by itself.
  List<Track> autoplayTracks(List<Track> queue, {math.Random? random}) => _library.related.autoplay(
    queue,
    random: random,
    count: autoplayCount,
    taste: Taste(
      isFavorite: (track) => _library.isFavorite(track.id),
      playCount: (track) => _library.playCount(track.id),
      lastPlayedAt: (track) => _library.lastPlayedAt(track.id),
      isHidden: _library.isTrackHidden,
      skippedArtists: _skippedArtists,
    ),
  );

  /// The tracks Autoplay added, and the artists of those skipped before they counted as played: Autoplay keeps away
  /// from them until the listener plays music of their own choosing.
  final Set<String> _autoplayed = {};
  final Set<String> _skippedArtists = {};

  void _setPosition(Duration value) {
    position.value = value;
    elapsedSeconds.value = value.inSeconds;
  }

  /// Whether [track] is the one playing (on the device being controlled): the lists highlight it.
  bool isCurrent(Track track) => currentTrack?.id == track.id;

  // ── Listening together ─────────────────────────────────────────────────────────────────────────

  /// How far a member may be from the host before it seeks to it, how often it looks, and how often a host that plays
  /// tells its position anyway. Tests change them.
  static Duration followTolerance = const Duration(milliseconds: 150);
  static Duration followCheckInterval = const Duration(seconds: 2);
  static Duration hostBeatInterval = const Duration(seconds: 5);

  ListenTogether? _together;

  /// A member: what the host last told, and the host's place of each entry of the queue here (the host's queue as far
  /// as this library has its tracks).
  ListeningState? _hostState;
  List<int> _hostIndices = const [];

  /// A member paused here while the host plays on: play catches up with it.
  bool _pausedHere = false;

  /// Following paused it (the host paused): following plays on by itself, unlike after any other pause.
  bool _pausedForHost = false;
  Timer? _followTimer;

  /// How far ahead of the host a member seeks, for the moment the seek takes; learnt from how far behind it still was.
  Duration _seekLead = Duration.zero;
  DateTime? _caughtUpAt;

  // A host: what it last told, and its heartbeat.
  Object? _groupSignature;
  (Duration, DateTime, bool)? _groupAnchor;
  Timer? _hostBeat;

  /// A member asked the host for tracks (with the member's name and the tracks), for a notice.
  final Event<(String from, List<Track> tracks)> listenerQueued = Event();

  /// The player left listening together to play music of its own.
  final Event<void> leftForOwnMusic = Event<void>();

  /// Another account started music here (casting to this player, [DeviceSharing]).
  final Event<AccountInfo> castHere = Event<AccountInfo>();

  /// Whose music plays here when another account cast it ([castHere]); null while it is this account's own. Its plays
  /// count for that account (its player counts them), not for this one.
  AccountInfo? get playingFor => _playingFor;
  AccountInfo? _playingFor;

  /// Takes part in listening together through [together].
  void attachListenTogether(ListenTogether together) {
    _together = together;
    _subscriptions.addAll([
      together.changed.listen((_) => _onGroupChanged()),
      together.stateReceived.listen((state) {
        _hostState = state;
        _followHost();
      }),
      together.requestReceived.listen((request) => _onListenerRequest(request.$1, request.$2)),
    ]);
  }

  /// The group this player hosts or listens in.
  ListeningGroup? get listeningGroup => _together?.group;

  /// This player plays what another one hosts.
  bool get isFollowingHost => _together?.isMember ?? false;
  bool get isHostingGroup => _together?.isHost ?? false;

  /// The position of this device now: the engine's last, counted on while it plays (by at most a second: an engine
  /// that stopped telling is not playing on).
  Duration _positionNow() {
    if (_state != PlaybackState.playing) return _localPosition;
    final since = DateTime.now().difference(_localPositionAt);
    return _localPosition + (since > const Duration(seconds: 1) ? const Duration(seconds: 1) : since);
  }

  void _onGroupChanged() {
    final together = _together!;
    if (together.isMember) {
      if (_followTimer == null) {
        // Joined: what played here gives way to the host's music, which comes with its first state. Joining is
        // playing along, so a pause from before doesn't hold.
        _pausedHere = false;
        _pausedForHost = true;
        if (_hostState == null) _pauseForHost();
        _followTimer = Timer.periodic(followCheckInterval, (_) => _followHost());
      }
    } else {
      _followTimer?.cancel();
      _followTimer = null;
      _hostState = null;
      _hostIndices = const [];
      _pausedHere = false;
      _pausedForHost = false;
    }
    if (together.isHost) {
      _groupSignature = null; // told again: someone may have joined
      _publishGroup();
      _hostBeat ??= Timer.periodic(hostBeatInterval, (_) {
        if (_state == PlaybackState.playing) _publishGroupNow();
      });
    } else {
      _hostBeat?.cancel();
      _hostBeat = null;
      _groupAnchor = null;
    }
    notifyListeners();
  }

  /// A member plays music of its own: it leaves the group first.
  void _leaveForOwnMusic() {
    final together = _together;
    if (together == null || !together.isMember) return;
    together.leave();
    leftForOwnMusic.emit(null);
  }

  void _askHost(RemoteCommand command) => _together?.request(command);

  // The host.

  void _publishGroup() {
    final together = _together;
    if (together == null || !together.isHost) return;
    final track = _currentTrack;
    final signature = (
      track == null ? null : _library.sharedId(track),
      _state == PlaybackState.playing,
      _queueVersion,
      _queueIndex,
    );
    if (signature == _groupSignature) return;
    _groupSignature = signature;
    _publishGroupNow();
  }

  void _publishGroupNow() {
    final together = _together;
    if (together == null || !together.isHost) return;
    final (queue, index) = _queueIndex >= 0 && _queueIndex < _playbackQueue.length
        ? _window(_playbackQueue, _queueIndex)
        : (<String>[], -1);
    final playing = _state == PlaybackState.playing;
    final at = _positionNow();
    _groupAnchor = (at, DateTime.now(), playing);
    together.publish(
      ListeningState(queue: queue, queueIndex: index, playing: playing, position: at, at: together.serverNow()),
    );
  }

  /// A seek (or a stall) moves the host off where the members count it to be: they are told.
  void _publishGroupIfDrifted(Duration at) {
    final anchor = _groupAnchor;
    if (anchor == null || !isHostingGroup) return;
    final (told, toldAt, playing) = anchor;
    final expected = playing ? told + DateTime.now().difference(toldAt) : told;
    if ((at - expected).abs() > const Duration(milliseconds: 400)) _publishGroupNow();
  }

  /// What a member asked of the host: skipping, seeking and the queue, which everyone hears. Playing, pausing and the
  /// volume are each player's own.
  void _onListenerRequest(String from, RemoteCommand command) {
    switch (command.action) {
      case RemoteAction.next ||
          RemoteAction.previous ||
          RemoteAction.seek ||
          RemoteAction.playIndex ||
          RemoteAction.moveTrack ||
          RemoteAction.removeTrack ||
          RemoteAction.shuffle ||
          RemoteAction.repeat:
        _execute(command);
      case RemoteAction.playNext || RemoteAction.addToQueue:
        final tracks = _library.resolveTracks(command.trackIds);
        if (tracks.isEmpty) return;
        _execute(command);
        listenerQueued.emit((from, tracks));
      default:
        break;
    }
  }

  // A member.

  Future<void> _setPausedHere(bool paused) async {
    _pausedHere = paused;
    if (paused) {
      _pausedForHost = false;
      await _pauseLocal();
    } else {
      _pausedForHost = true; // to be played on, as following would
      _followHost(); // catches up with the host
    }
    notifyListeners();
  }

  /// Plays here what the host plays, where the host is: its queue, its entry, playing or paused, and its position,
  /// seeking when this one is more than [followTolerance] off.
  void _followHost() {
    final state = _hostState;
    final together = _together;
    if (state == null || together == null || !together.isMember) return;
    // Paused by something else than following (a call, headphones unplugged): it stays so until play.
    if (_state == PlaybackState.paused && !_pausedForHost) _pausedHere = true;

    final tracks = <Track>[];
    final hostIndices = <int>[];
    var current = -1;
    for (var i = 0; i < state.queue.length; i++) {
      final track = _library.resolveTracks([state.queue[i]]).firstOrNull;
      if (track == null) continue;
      if (i == state.queueIndex) current = tracks.length;
      tracks.add(track);
      hostIndices.add(i);
    }
    _hostIndices = hostIndices;
    if (current < 0) {
      // The host plays nothing, or a track this library doesn't have: quiet here meanwhile.
      _pauseForHost();
      return;
    }

    final same =
        tracks.length == _playbackQueue.length &&
        [for (var i = 0; i < tracks.length; i++) identical(tracks[i], _playbackQueue[i])].every((same) => same);
    if (!same) {
      // The host's order is the order: not shuffled again here.
      _queueRun++;
      _originalQueue
        ..clear()
        ..addAll(tracks);
      _playbackQueue
        ..clear()
        ..addAll(tracks);
      _queueIndex = -1;
      _updateQueueState();
    }

    final target = state.positionAt(together.serverNow());
    final playing = state.playing && !_pausedHere;
    // Gone on to the next entry a moment before the host, which follows any moment: not taken back.
    if (playing && _queueIndex == current + 1 && tracks[current].duration - target < const Duration(seconds: 2)) return;
    if (_queueIndex != current || (playing && _state == PlaybackState.stopped)) {
      if (playing) {
        _pausedForHost = false;
        _caughtUpAt = DateTime.now();
        _playAt(current, start: target + _seekLead);
      } else {
        // Shown paused where the host is, as a queue picked up after a restart is.
        if (_state != PlaybackState.stopped) unawaited(_runSafe(_engine.stop));
        _queueIndex = current;
        _updateQueueState();
        _resumeAt = target;
        _localPosition = target;
        _setPosition(target);
        currentTrack = tracks[current];
        notifyListeners();
      }
      return;
    }

    if (!playing) {
      _pauseForHost();
      // Paused by the host somewhere else: there, ready for when it plays on.
      if (!state.playing && (_positionNow() - target).abs() > followTolerance) {
        unawaited(_runSafe(() => _engine.seek(target)));
      }
      return;
    }
    if (_state == PlaybackState.paused) {
      _pausedForHost = false;
      _caughtUpAt = DateTime.now();
      unawaited(
        _runSafe(() async {
          await _engine.seek(target + _seekLead);
          await _engine.resume();
        }),
      );
      return;
    }
    if (_state != PlaybackState.playing || !together.hasClock || _isUserSeeking) return;

    final off = _positionNow() - target; // ahead of the host, or behind it (negative)
    if (off.abs() <= followTolerance) return;
    final last = _caughtUpAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < followCheckInterval) return; // the last seek may still be settling
    if (last != null && now.difference(last) < followCheckInterval * 3 && off.abs() < const Duration(seconds: 1)) {
      // A little off right after a seek: the seek itself takes that long, so the next one aims that much further.
      final lead = _seekLead - off;
      _seekLead = lead.isNegative
          ? Duration.zero
          : (lead > const Duration(seconds: 1) ? const Duration(seconds: 1) : lead);
    }
    _caughtUpAt = now;
    unawaited(_runSafe(() => _engine.seek(target + _seekLead)));
  }

  /// Pauses because the host did (or plays what this library lacks): following plays on by itself later.
  void _pauseForHost() {
    if (_state != PlaybackState.playing) return;
    _pausedForHost = true;
    unawaited(_engine.pause());
  }

  // ── Other devices (remote control) ─────────────────────────────────────────────────────────────

  /// How long the device being controlled may be out of sight (a dropped connection) before control returns here.
  /// Tests shorten it.
  static Duration remoteGrace = const Duration(seconds: 15);

  RemoteClient? _remote;
  String? _remoteId;
  String _remoteName = '';
  DeviceKind _remoteKind = DeviceKind.desktop;
  RemotePlayback? _remoteState;

  /// The track that plays on another account's player this one cast to ([_applyRemote]), and whether it has counted
  /// as played.
  String? _castTrack;
  bool _castCounted = false;
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
      remote.commandReceived.listen((received) => _execute(received.command, from: received.account)),
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
    // Music this account cast to another account's player counts here, as that player doesn't count it: once per
    // track it starts, when enough of it has played.
    final account = _remote?.accountId;
    if (told != null && account != null && playback.playingFor == account) {
      if (told.id != _castTrack) {
        _castTrack = told.id;
        _castCounted = false;
      }
      _countCastWhenPlayed();
    } else {
      _castTrack = null;
    }
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
            _countCastWhenPlayed();
          })
        : null;
    notifyListeners();
  }

  void _countCastWhenPlayed() {
    final id = _castTrack;
    if (id == null || _castCounted) return;
    final track = _library.resolveTracks([id]).firstOrNull;
    if (track == null || _remotePosition() < track.countsAfter) return;
    _castCounted = true;
    try {
      _library.recordPlay(track.id);
    } catch (e) {
      WiretuneLog.debug('PlayerViewModel', 'Could not count a play cast to another player: $e');
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
  /// Carries out a command from another player: this account's own, or ([from]) another account's casting here, whose
  /// music leaves out what this account hides unless this player shares any music ([RemoteClient.sharing]).
  void _execute(RemoteCommand command, {AccountInfo? from}) {
    List<Track> resolve(Iterable<String> ids) {
      final tracks = _library.resolveTracks(ids);
      if (from == null || _remote?.sharing == DeviceSharing.any) return tracks;
      return [
        for (final track in tracks)
          if (!_library.isTrackHidden(track)) track,
      ];
    }

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
        _setRepeatLocal(command.repeat);
      case RemoteAction.playTracks:
        // Music from another device: it plays here now, and this player shows it. The track it was on starts where it
        // was; one this library lacks gives way to the next one it has, from its beginning.
        final tracks = resolve(command.trackIds);
        if (tracks.isEmpty) return;
        final index = command.index;
        final wanted = index < 0 ? null : resolve([command.trackIds[index]]).firstOrNull;
        final start = wanted ?? (index < 0 ? null : resolve(command.trackIds.skip(index + 1)).firstOrNull);
        if (isRemote) _leaveRemote();
        // Set first: the first track's play counts for whoever cast it, not for this account.
        _playingFor = from;
        _playQueueInternal(tracks, start, start: wanted != null ? command.position : Duration.zero);
        if (from != null) castHere.emit(from);
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
        _queueLocal(resolve(command.trackIds), next: command.action == RemoteAction.playNext);
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
        playingFor: _playingFor?.id,
      ),
    );
  }

  @override
  void notifyListeners() {
    _publish();
    _publishGroup();
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
    _followTimer?.cancel();
    _hostBeat?.cancel();
    _sleepTimer?.cancel();
    position.dispose();
    elapsedSeconds.dispose();
    nowPlaying.dispose();
    spectrum.dispose();
    super.dispose();
  }
}

/// The spectrum's bands, which tell [onShown] when the first listener comes and when the last one goes.
class _Spectrum extends ValueNotifier<Float32List> {
  _Spectrum(this.onShown) : super(Float32List(SpectrumAnalyzer.numBands));

  final void Function(bool shown) onShown;
  int _listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_listeners++ == 0) onShown(true);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_listeners > 0 && --_listeners == 0) onShown(false);
  }
}
