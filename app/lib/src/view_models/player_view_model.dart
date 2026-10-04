import 'dart:async';
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

typedef LyricsProvider = Future<String?> Function(Track track, CancellationToken ct);

/// The player: the queue, shuffle and repeat, the transport, volume and modes, and the lyrics of the current track.
class PlayerViewModel extends ChangeNotifier {
  PlayerViewModel(this._engine, this._library) {
    isExclusiveMode = _engine.isExclusiveMode;
    isBitperfect = _engine.isBitperfect;
    isVolumeLocked = _engine.isBitperfect;

    _subscriptions.addAll([
      _engine.stateChanged.listen((state) {
        playbackState = state;
        if (state == PlaybackState.playing) errorMessage = null;
        if (state != PlaybackState.playing) spectrum.value = Float32List(32);
        notifyListeners();
      }),
      // The player keeps the Track instance it started with; a favourite toggled elsewhere changes the library's one.
      _library.favoriteChanged.listen((changed) {
        final current = currentTrack;
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
        if (!_isUserSeeking) _setPositionFromEngine(position);
      }),
      _engine.trackChanged.listen(_onEngineTrackChanged),
      _engine.bitperfectChanged.listen((value) {
        isBitperfect = value;
        isVolumeLocked = value;
        volume = value ? 100 : (_engine.volume * 100).roundToDouble();
        signalPath = _engine.signalPathDescription;
        notifyListeners();
      }),
      _engine.exclusiveModeChanged.listen((value) {
        isExclusiveMode = value;
        signalPath = _engine.signalPathDescription;
        notifyListeners();
      }),
      _engine.spectrumDataAvailable.listen((bands) {
        if (playbackState == PlaybackState.playing) spectrum.value = bands;
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

  WiretuneAudioEngine get engine => _engine;

  // ── State ──────────────────────────────────────────────────────────────────────────────────────

  Track? _currentTrack;
  Track? get currentTrack => _currentTrack;

  PlaybackState playbackState = PlaybackState.stopped;

  /// The playback position; updated several times a second, so it has its own notifier.
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// The 32 spectrum bands (0..1), about 30 times a second while playing.
  final ValueNotifier<Float32List> spectrum = ValueNotifier(Float32List(32));

  double get positionSeconds => position.value.inMicroseconds / 1e6;
  Duration get duration => _currentTrack?.duration ?? Duration.zero;
  double get durationSeconds => duration.inMicroseconds / 1e6;

  double volume = 100;
  bool isMuted = false;
  bool isExclusiveMode = false;
  bool isBitperfect = false;
  bool isVolumeLocked = false;
  bool isShuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  String signalPath = '';
  QualityTier currentTier = QualityTier.silver;
  String currentTagSpec = '';
  String? errorMessage;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
  bool get isPlaying => playbackState == PlaybackState.playing;
  bool get isVolumeDisabledOrMuted => isMuted || isVolumeLocked;
  bool get isVolumeActive => !isMuted && !isVolumeLocked;
  bool get isVolumeLockedAndNotMuted => !isMuted && isVolumeLocked;
  String get volumeToolTip =>
      Localizer.get(isMuted ? 'VolumeUnmute' : (isVolumeLocked ? 'VolumeLocked' : 'VolumeMute'));

  /// Title of the current track, or a hint when nothing is loaded.
  String get nowPlayingTitle => _currentTrack?.title ?? Localizer.get('NothingPlaying');

  /// Artist of the current track, or a hint when nothing is loaded.
  String get nowPlayingArtist => _currentTrack?.artist ?? Localizer.get('ChooseMusic');

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

  List<Track> queueTracks = const [];
  List<QueueItem> queueItems = const [];
  int currentQueueIndex = -1;

  void toggleQueue() => isQueueOpen = !isQueueOpen;

  void closeQueue() => isQueueOpen = false;

  /// Plays an entry of the queue (a [Track] or a [QueueItem]); a track that is not queued yet starts the library.
  void playQueueTrack(Object? parameter) {
    final track = switch (parameter) {
      Track t => t,
      QueueItem entry => entry.track,
      _ => null,
    };
    if (track == null) return;

    final index = _playbackQueue.indexOf(track);
    if (index >= 0) {
      _playAt(index);
    } else {
      _playQueueInternal(_library.tracks.isNotEmpty ? _library.tracks : [track], track);
    }
  }

  void moveQueueTrack(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _playbackQueue.length) return;
    if (newIndex < 0 || newIndex >= _playbackQueue.length) return;
    if (oldIndex == newIndex) return;

    final track = _playbackQueue.removeAt(oldIndex);
    _playbackQueue.insert(newIndex, track);
    if (!isShuffle) {
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
    if (item == null || item.index >= _playbackQueue.length - 1) return;
    moveQueueTrack(item.index, item.index + 1);
  }

  void removeQueueTrack(Track? track) {
    if (track == null) return;
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
        nextTrack();
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
    queueTracks = List.unmodifiable(_playbackQueue);
    currentQueueIndex = _queueIndex;
    queueItems = [for (var i = 0; i < _playbackQueue.length; i++) QueueItem(_playbackQueue[i], i, i == _queueIndex)];
  }

  /// Replaces the queue with [tracks] and starts [startTrack] (the first track, or a random one when shuffling).
  void playQueue(Iterable<Track> tracks, [Track? startTrack]) {
    _playQueueInternal(tracks, startTrack);
    notifyListeners();
  }

  void _playQueueInternal(Iterable<Track> tracks, Track? startTrack) {
    _originalQueue
      ..clear()
      ..addAll(tracks);
    if (_originalQueue.isEmpty) return;

    final start = startTrack != null && _originalQueue.contains(startTrack) ? startTrack : null;
    _playbackQueue.clear();
    if (isShuffle) {
      final first = start ?? _originalQueue[_random.nextInt(_originalQueue.length)];
      _playbackQueue
        ..add(first)
        ..addAll(_shuffled(_originalQueue.where((t) => !identical(t, first))));
      _playAt(0);
    } else {
      _playbackQueue.addAll(_originalQueue);
      _playAt(start != null ? _playbackQueue.indexOf(start) : 0);
    }
    _updateQueueState();
  }

  void _playAt(int index) {
    if (index < 0 || index >= _playbackQueue.length) return;
    _queueIndex = index;
    _updateQueueState();
    errorMessage = null;
    final track = _playbackQueue[index];
    _runSafe(() => _engine.playTrack(track));
    notifyListeners();
  }

  // ── Transport ──────────────────────────────────────────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    switch (playbackState) {
      case PlaybackState.playing:
        await _engine.pause();
      case PlaybackState.paused:
        await _engine.resume();
      default:
        if (_queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
          _playAt(_queueIndex);
        } else if (_currentTrack != null) {
          playQueue([_currentTrack!], _currentTrack);
        } else if (_library.tracks.isNotEmpty) {
          playQueue(_library.tracks);
        }
    }
  }

  Future<void> play() async {
    if (playbackState != PlaybackState.playing) await togglePlayPause();
  }

  Future<void> pause() async {
    if (playbackState == PlaybackState.playing) await _engine.pause();
  }

  Future<void> stop() => _runSafe(_engine.stop);

  void nextTrack() {
    if (_playbackQueue.isEmpty) return;
    if (_queueIndex + 1 < _playbackQueue.length) {
      _playAt(_queueIndex + 1);
    } else if (repeatMode == RepeatMode.all) {
      _playAt(0);
    } else {
      _queueIndex = _playbackQueue.length; // past the end: nothing is current any more
      _updateQueueState();
      _runSafe(_engine.stop);
      notifyListeners();
    }
  }

  /// Restarts the current track when more than three seconds have played, otherwise goes to the previous one.
  void previousTrack() {
    if (_playbackQueue.isEmpty) return;
    if (positionSeconds > 3.0) {
      _runSafe(() => _engine.seek(Duration.zero));
      return;
    }
    var previous = _queueIndex - 1;
    if (previous < 0) previous = repeatMode == RepeatMode.all ? _playbackQueue.length - 1 : 0;
    _playAt(math.min(previous, _playbackQueue.length - 1));
  }

  void toggleShuffle() => setShuffle(!isShuffle);

  /// Reorders the rest of the running queue without interrupting the current track.
  void setShuffle(bool value) {
    if (isShuffle == value) return;
    isShuffle = value;
    if (_playbackQueue.length >= 2 && _queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
      final current = _playbackQueue[_queueIndex];
      final rest = value
          ? _shuffled(_originalQueue.where((t) => !identical(t, current)))
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

  void toggleRepeat() {
    repeatMode = switch (repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    notifyListeners();
  }

  Future<void> toggleFavoriteCurrent() async {
    final current = _currentTrack;
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
    if (_currentTrack == null) return;
    if (target < Duration.zero) target = Duration.zero;
    position.value = target;
    _updateLyricPosition(target);
    _isUserSeeking = true;

    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 200), () async {
      try {
        await _engine.seek(target);
      } catch (e) {
        WiretuneLog.warn('PlayerViewModel', 'Seek failed: $e');
      } finally {
        _isUserSeeking = false;
      }
    });
  }

  set positionSeconds(double seconds) => seekTo(Duration(microseconds: (seconds * 1e6).round()));

  void setVolume(double value) {
    volume = value.clamp(0, 100);
    if (!isBitperfect) _engine.setVolume(volume / 100.0);
    notifyListeners();
  }

  void toggleMute() {
    if (isBitperfect) return;
    isMuted = !isMuted;
    _engine.setMuted(isMuted);
    notifyListeners();
  }

  // ── Engine callbacks ───────────────────────────────────────────────────────────────────────────

  void _onEngineTrackChanged(Track? track) {
    _seekDebounce?.cancel();
    _seekDebounce = null;
    _isUserSeeking = false;

    currentTrack = track;
    _setPositionFromEngine(Duration.zero);
    if (track != null) {
      currentTier = track.format.tier;
      currentTagSpec = track.format.tagSpec;
      signalPath = _engine.signalPathDescription;
      // Bookkeeping only: no error banner when it fails.
      unawaited(
        _library.recordPlay(track.id).catchError((Object e) {
          WiretuneLog.debug('PlayerViewModel', 'Recording a play failed: $e');
        }),
      );
    }
    notifyListeners();
  }

  set currentTrack(Track? value) {
    final old = _currentTrack;
    if (identical(old, value)) return;
    _currentTrack = value;
    if (old != null) {
      old.isPlaying = false;
      final inLibrary = _library.getTrack(old.id);
      if (inLibrary != null && !identical(inLibrary, old)) inLibrary.isPlaying = false;
    }
    if (value != null) {
      value.isPlaying = true;
      final inLibrary = _library.getTrack(value.id);
      if (inLibrary != null && !identical(inLibrary, value)) inLibrary.isPlaying = true;
    }
    _lyricsTrackId = null;
    _refreshLyrics();
    notifyListeners();
  }

  void _onTrackEnded() {
    if (repeatMode == RepeatMode.one && _queueIndex >= 0 && _queueIndex < _playbackQueue.length) {
      _playAt(_queueIndex);
    } else if (_queueIndex < _playbackQueue.length - 1 || repeatMode == RepeatMode.all) {
      nextTrack();
    }
  }

  void _setPositionFromEngine(Duration value) {
    position.value = value;
    _updateLyricPosition(value);
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
  String? get currentLyrics => _currentLyrics;
  bool get hasLyrics => _currentLyrics != null && _currentLyrics!.trim().isNotEmpty;

  /// The lines of time-synced lyrics; empty for plain lyrics or none.
  List<LyricLine> lyricLines = const [];

  /// Index into [lyricLines] of the line being sung; -1 before the first line.
  final ValueNotifier<int> currentLyricIndex = ValueNotifier(-1);

  bool get hasSyncedLyrics => lyricLines.isNotEmpty;
  bool get hasPlainLyrics => hasLyrics && !hasSyncedLyrics;
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
    if (line == null || _currentTrack == null) return;
    seekTo(line.time);
  }

  /// Loads the lyrics of the current track, but only while the panel that shows them is open.
  void _refreshLyrics() {
    final track = _currentTrack;
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
        text = await own(track, ct);
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
          text = await online(track, ct);
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

    if (ct.isCancelled || !identical(_currentTrack, track)) return;
    _setLyrics(text);
    lyricsOrigin = origin;
    lyricsLookupFailed = failed;
    isLoadingLyrics = false;
    if (failed) _lyricsTrackId = null; // opening the panel again tries once more
    notifyListeners();
  }

  /// Re-renders the texts that were computed in the previous language.
  void refreshLocalizedTexts() {
    if (_currentTrack != null) signalPath = _engine.signalPathDescription;
    notifyListeners();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────────────────────────

  List<Track> _shuffled(Iterable<Track> source) {
    final list = source.toList();
    for (var n = list.length - 1; n > 0; n--) {
      final k = _random.nextInt(n + 1);
      final t = list[k];
      list[k] = list[n];
      list[n] = t;
    }
    return list;
  }

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
    position.dispose();
    spectrum.dispose();
    currentLyricIndex.dispose();
    super.dispose();
  }
}
