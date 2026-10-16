// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'player_view_model.dart';

/// Where the lyrics shown for the current track come from.
enum LyricsOrigin {
  /// There are no lyrics.
  none,

  /// The track's own tags (the file, or the server's copy of the file's tags).
  tags,

  /// The internet lookup (LRCLIB).
  online,
}

typedef LyricsProvider = Future<String?> Function(Track track);

/// The lyrics of the track that plays (also on a device this one controls): the ones it carries itself first, else the
/// internet's when the user allows it. They are looked for only while they are shown (the queue panel, the full-screen
/// player's queue and lyrics), and lyrics in LRC form ("[01:23.45] text") follow the song line by line.
class LyricsViewModel extends ChangeNotifier {
  LyricsViewModel(this._player, {this.own, this.online})
    : _shownTrackId = _player.currentTrack?.id,
      _panelOpen = _player.isQueueOpen {
    _player.addListener(_onPlayerChanged);
    _player.position.addListener(_follow);
  }

  final PlayerViewModel _player;

  /// The position arrives a few times a second, so the line being sung is looked up slightly ahead.
  static const Duration _lead = Duration(milliseconds: 200);

  /// Finds the lyrics a track carries itself (tag of a local file, server request for a server track).
  LyricsProvider? own;

  /// Looks lyrics up on the internet; asked only for a track without lyrics of its own, and only while
  /// [isOnlineEnabled]. Throws when the lookup could not be made.
  LyricsProvider? online;

  String? _text;

  /// The time-synced lines; empty for plain lyrics or none.
  List<LrcLine> lines = const [];

  /// Index into [lines] of the line being sung; -1 before the first line.
  final ValueNotifier<int> currentLine = ValueNotifier(-1);

  bool isLoading = false;
  LyricsOrigin origin = LyricsOrigin.none;

  /// True when the internet lookup could not be made (no connection, service down), as opposed to "nothing found".
  bool lookupFailed = false;

  bool _isOnlineEnabled = true;
  String? _shownTrackId;
  bool _panelOpen;

  // The track the lyrics are loaded (or loading) for; null when the next showing has to look again.
  String? _loadedFor;
  CancellationToken? _token;

  bool get hasLyrics => _text != null && _text!.trim().isNotEmpty;
  bool get isSynced => lines.isNotEmpty;
  String? get plainText => isSynced ? null : _text;

  /// True when there are neither lyrics nor a search in progress.
  bool get showEmptyState => !hasLyrics && !isLoading;

  /// Why there are no lyrics, in the active language.
  String get emptyText => lookupFailed
      ? Localizer.get('LyricsLookupFailed')
      : Localizer.get(isOnlineEnabled && online != null ? 'NoLyrics' : 'NoLyricsInTags');

  /// "Source: LRCLIB" or "Source: the track's own tags"; empty while there are no lyrics.
  String get sourceText => switch (origin) {
    LyricsOrigin.online => Localizer.format('LyricsSource', [OnlineLyrics.sourceName]),
    LyricsOrigin.tags => Localizer.get('LyricsSourceTags'),
    LyricsOrigin.none => '',
  };

  /// Whether tracks without lyrics of their own are looked up online (the Settings switch).
  bool get isOnlineEnabled => _isOnlineEnabled;
  set isOnlineEnabled(bool value) {
    if (_isOnlineEnabled == value) return;
    _isOnlineEnabled = value;
    // Switched on while a track without lyrics is shown: look now. Switched off while internet lyrics are shown: remove.
    if ((value && !hasLyrics) || (!value && origin == LyricsOrigin.online)) {
      _loadedFor = null;
      _refresh();
    }
    notifyListeners(); // the empty text names the switch
  }

  /// Jumps the song to the start of a line (the user tapped it).
  void seekTo(LrcLine line) {
    if (_player.currentTrack != null) _player.seekTo(line.time);
  }

  /// The texts are read in the active language; the view only has to draw again.
  void refreshLocalizedTexts() => notifyListeners();

  void _onPlayerChanged() {
    final trackId = _player.currentTrack?.id;
    final open = _player.isQueueOpen;
    final changed = trackId != _shownTrackId;
    final opened = open && !_panelOpen;
    _shownTrackId = trackId;
    _panelOpen = open;
    if (changed) _loadedFor = null;
    if (changed || opened) {
      _refresh();
      notifyListeners();
    }
  }

  /// Loads the lyrics of the current track, but only while they are shown.
  void _refresh() {
    final track = _player.currentTrack;
    if (track != null && _loadedFor == track.id) return; // loaded, or loading, for this track already

    _token?.cancel();
    _loadedFor = null;
    _show(null, LyricsOrigin.none);
    lookupFailed = false;
    isLoading = false;
    if (track != null && _panelOpen && (own != null || online != null)) {
      _loadedFor = track.id;
      isLoading = true;
      final token = _token = CancellationToken();
      unawaited(_load(track, token));
    }
  }

  /// The lyrics the track carries itself come first (they are instant and belong to this very file); only when it has
  /// none, and the user allows it, the internet is asked.
  Future<void> _load(Track track, CancellationToken token) async {
    String? text;
    var origin = LyricsOrigin.none;
    var failed = false;

    final own = this.own;
    if (own != null) {
      try {
        text = await own(track);
      } catch (e) {
        if (!token.isCancelled) WiretuneLog.debug('Lyrics', "Lyrics unavailable for '${track.title}': $e");
      }
    }
    if (token.isCancelled) return;

    if (text != null && text.trim().isNotEmpty) {
      origin = LyricsOrigin.tags;
    } else {
      text = null;
      final online = this.online;
      if (_isOnlineEnabled && online != null) {
        try {
          text = await online(track);
          if (text != null && text.trim().isNotEmpty) {
            origin = LyricsOrigin.online;
          } else {
            text = null;
          }
        } catch (e) {
          // Not reaching the service is not the same as "no lyrics exist": say so, and ask again next time.
          if (!token.isCancelled) {
            failed = true;
            WiretuneLog.debug('Lyrics', "Online lyrics unavailable for '${track.title}': $e");
          }
        }
      }
    }

    if (token.isCancelled || _player.currentTrack?.id != track.id) return;
    _show(text, origin);
    lookupFailed = failed;
    isLoading = false;
    if (failed) _loadedFor = null; // showing them again tries once more
    notifyListeners();
  }

  void _show(String? text, LyricsOrigin from) {
    _text = text;
    origin = from;
    lines = LrcParser.parse(text);
    // The lyrics may arrive (or be shown) in the middle of the song: start at the right line.
    _follow();
  }

  /// Moves to the line being sung.
  void _follow() {
    currentLine.value = lines.isEmpty ? -1 : LrcParser.indexAt(lines, _player.position.value + _lead);
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayerChanged);
    _player.position.removeListener(_follow);
    _token?.cancel();
    currentLine.dispose();
    super.dispose();
  }
}
