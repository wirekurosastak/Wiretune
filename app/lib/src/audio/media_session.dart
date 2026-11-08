// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';
import 'package:wiretune_core/wiretune_core.dart' hide PlaybackState;
import 'package:wiretune_core/wiretune_core.dart' as core show PlaybackState;

import '../platform.dart';
import '../view_models/main_view_model.dart';
import '../widgets/cover_image.dart';

/// Connects the player to the system's media session: the playback notification and its buttons on Android, the
/// lock screen and Control Center on iOS, the Now Playing widget on macOS, media buttons on headsets, and the browse
/// tree that Android Auto shows in the car (albums, artists, playlists, favourites) and its voice search.
class WiretuneMediaSession extends BaseAudioHandler {
  /// [now] is the clock the published positions are timed by; replaceable by tests. [homeWidget]: tell Android's
  /// home-screen widget what plays too.
  WiretuneMediaSession(this._vm, {DateTime Function()? now, this.homeWidget = false}) : _now = now ?? DateTime.now {
    _vm.player.addListener(_publish);
    _vm.player.position.addListener(_followPosition);
    _vm.library.libraryChanged.listen((_) => notifyChildrenChanged());
    _vm.library.playlistsChanged.listen((_) => notifyChildrenChanged());
    // The heart in the notification follows the favourite, wherever it changes.
    _vm.library.favoriteChanged.listen((_) => _publish());
    _publish();
  }

  final MainViewModel _vm;
  final DateTime Function() _now;
  final bool homeWidget;
  String? _publishedTrackId;
  List<String> _publishedQueue = const [];
  String? _streamToken;
  bool _publishedFavorite = false;

  static Future<WiretuneMediaSession> start(MainViewModel vm) => AudioService.init(
    builder: () => WiretuneMediaSession(vm, homeWidget: AppPlatform.current.isAndroid),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.wiretune.player.playback',
      androidNotificationChannelName: 'Wiretune',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
      androidBrowsableRootExtras: {
        // Android Auto: albums and artists as grids, track lists as lists.
        'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
        'android.media.browse.SEARCH_SUPPORTED': true,
      },
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );

  // ── Publishing the player's state ──────────────────────────────────────────────────────────────
  // The system shows the position it was last given, carried on by the time since while playing: a track that plays on
  // needs no updates, only changes do (play, pause, a seek, the next track, the modes).

  void _publish() {
    final player = _vm.player;
    final track = player.currentTrack;

    final trackChanged = track?.id != _publishedTrackId;
    if (trackChanged) {
      _publishedTrackId = track?.id;
      if (track != null && !track.isLocal) unawaited(_refreshToken());
      mediaItem.add(track == null ? null : _item(track, playable: true));
    }

    final state = _playbackState();
    final last = playbackState.value;
    final favorite = track != null && _vm.library.isFavorite(track.id);
    final favoriteChanged = favorite != _publishedFavorite;
    _publishedFavorite = favorite;
    if (trackChanged ||
        favoriteChanged ||
        state.playing != last.playing ||
        state.processingState != last.processingState ||
        state.repeatMode != last.repeatMode ||
        state.shuffleMode != last.shuffleMode ||
        state.queueIndex != last.queueIndex ||
        state.errorMessage != last.errorMessage) {
      playbackState.add(state);
    }

    _showOnWidget();
    if (trackChanged && homeWidget) {
      // A server's cover is a file only once the player has shown it: told again when it may have come.
      Timer(const Duration(seconds: 3), _showOnWidget);
    }

    // Another queue of the same length (the next album) or a reordered one is a new queue too.
    final queueTracks = player.queueTracks.take(_maxQueue).toList();
    final ids = [for (final t in queueTracks) t.id];
    if (!_sameIds(ids, _publishedQueue)) {
      _publishedQueue = ids;
      queue.add([for (final t in queueTracks) _item(t, playable: true)]);
    }
  }

  static const int _maxQueue = 500;

  // ── The home-screen widget (Android) ───────────────────────────────────────────────────────────

  static const MethodChannel _widget = MethodChannel('wiretune/power');
  Map<String, Object?>? _shownOnWidget;

  /// Tells Android's home-screen widget what plays, when anything it shows changed.
  void _showOnWidget() {
    if (!homeWidget) return;
    final player = _vm.player;
    final track = player.currentTrack;
    final shown = {
      'title': track?.title,
      'artist': track?.artist,
      'playing': player.playbackState == core.PlaybackState.playing,
      'cover': CoverArt.fileOf(track?.coverArtPath),
      'favorite': track != null && _vm.library.isFavorite(track.id),
      'shuffle': player.isShuffle,
    };
    if (_shownOnWidget != null && mapEquals(shown, _shownOnWidget)) return;
    _shownOnWidget = shown;
    unawaited(
      _widget.invokeMethod<void>('showOnWidget', shown).catchError((Object _) {
        // Not registered (tests): no widget.
      }),
    );
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// A position that has drifted from where the system has carried it to (a seek, a stream that stalled) is published;
  /// one that keeps pace is not.
  void _followPosition() {
    final last = playbackState.value;
    final carried = last.playing ? last.updatePosition + _now().difference(last.updateTime) : last.updatePosition;
    if ((_vm.player.position.value - carried).abs() > const Duration(seconds: 1)) playbackState.add(_playbackState());
  }

  /// The player's state as the system shows it, with the position at this moment. Beside the transport, as in TIDAL's
  /// and Spotify's: the heart of the track that plays (filled when it is a favourite) and shuffle (with a dot when on),
  /// which Android 13 and later show in the media controls, and Android Auto on its screen.
  PlaybackState _playbackState() {
    final player = _vm.player;
    final playing = player.playbackState == core.PlaybackState.playing;
    final track = player.currentTrack;
    final favorite = track != null && _vm.library.isFavorite(track.id);
    return PlaybackState(
      controls: [
        if (track != null)
          MediaControl.custom(
            androidIcon: favorite ? 'drawable/ic_favorite' : 'drawable/ic_favorite_border',
            label: Localizer.get(favorite ? 'RemoveFromFavorites' : 'Favorite'),
            name: favoriteAction,
          ),
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: player.isShuffle ? 'drawable/ic_shuffle_on' : 'drawable/ic_shuffle',
          label: Localizer.get(player.isShuffle ? 'TipShuffleOff' : 'TipShuffleOn'),
          name: shuffleAction,
        ),
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      // Folded, the notification shows the transport alone.
      androidCompactActionIndices: track != null ? const [1, 2, 3] : const [0, 1, 2],
      processingState: switch (player.playbackState) {
        core.PlaybackState.error => AudioProcessingState.error,
        core.PlaybackState.stopped =>
          player.currentTrack == null ? AudioProcessingState.idle : AudioProcessingState.ready,
        _ => AudioProcessingState.ready,
      },
      playing: playing,
      updatePosition: player.position.value,
      updateTime: _now(),
      errorMessage: player.errorMessage,
      repeatMode: switch (player.repeatMode) {
        RepeatMode.off => AudioServiceRepeatMode.none,
        RepeatMode.all => AudioServiceRepeatMode.all,
        RepeatMode.one => AudioServiceRepeatMode.one,
      },
      shuffleMode: player.isShuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      queueIndex: player.currentQueueIndex >= 0 ? player.currentQueueIndex : null,
    );
  }

  Future<void> _refreshToken() async {
    final token = await _vm.session.getStreamToken();
    if (token != _streamToken) {
      _streamToken = token;
      final track = _vm.player.currentTrack;
      if (track != null) mediaItem.add(_item(track, playable: true));
    }
  }

  /// A cover the system can load by itself: a file (a downloaded one too), or a server URL carrying the media-only
  /// stream token.
  Uri? _art(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final copy = _vm.downloadService.localCover(path);
      if (copy != null) return Uri.file(copy);
      final token = _streamToken;
      final isOwnServer = path.startsWith(_vm.session.serverUrl);
      if (!isOwnServer || token == null) return isOwnServer ? null : Uri.parse(path);
      return Uri.parse('$path${path.contains('?') ? '&' : '?'}token=${Uri.encodeQueryComponent(token)}');
    }
    return Uri.file(path);
  }

  MediaItem _item(Track track, {required bool playable, String? context}) => MediaItem(
    id: context == null ? 'track:${track.id}' : '$context|${track.id}',
    title: track.title,
    artist: track.artist,
    album: track.album,
    genre: track.genre,
    duration: track.duration,
    artUri: _art(track.coverArtPath),
    playable: playable,
    displaySubtitle: track.artist,
    displayDescription: track.album,
  );

  // ── Commands from the system ───────────────────────────────────────────────────────────────────

  /// The notification's own buttons ([MediaControl.custom]): the heart and shuffle.
  static const String favoriteAction = 'favorite';
  static const String shuffleAction = 'shuffle';

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case favoriteAction:
        final track = _vm.player.currentTrack;
        if (track != null) _vm.library.toggleFavorite(track.id);
      case shuffleAction:
        _vm.player.toggleShuffle();
    }
  }

  @override
  Future<void> play() => _vm.player.play();

  @override
  Future<void> pause() => _vm.player.pause();

  @override
  Future<void> stop() => _vm.player.stop();

  @override
  Future<void> seek(Duration position) async => _vm.player.seekTo(position);

  @override
  Future<void> skipToNext() async => _vm.player.nextTrack();

  @override
  Future<void> skipToPrevious() async => _vm.player.previousTrack();

  @override
  Future<void> skipToQueueItem(int index) async {
    final queue = _vm.player.queueItems;
    if (index >= 0 && index < queue.length) _vm.player.playQueueItem(queue[index]);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _vm.player.setRepeatMode(switch (repeatMode) {
      AudioServiceRepeatMode.none => RepeatMode.off,
      AudioServiceRepeatMode.one => RepeatMode.one,
      _ => RepeatMode.all,
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async =>
      _vm.player.setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await _vm.player.togglePlayPause();
      case MediaButton.next:
        _vm.player.nextTrack();
      case MediaButton.previous:
        _vm.player.previousTrack();
    }
  }

  // ── Browsing (Android Auto) ────────────────────────────────────────────────────────────────────
  // Media IDs: "albums", "artists", "playlists", "favorites", "tracks"; "album:ID", "artist:ID", "playlist:ID" for the
  // lists, and "search:QUERY" for what a search found; "LIST|TRACKID" for a track in a list, which plays the list from
  // that track.

  static const int _maxItems = 400;

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    await _refreshTokenIfNeeded();
    final library = _vm.library;
    MediaItem folder(String id, String titleKey, {String? subtitle}) =>
        MediaItem(id: id, title: Localizer.get(titleKey), playable: false, displaySubtitle: subtitle);

    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return [
          folder('albums', 'NavAlbums'),
          folder('artists', 'NavArtists'),
          folder('playlists', 'NavPlaylists'),
          folder('favorites', 'NavFavorites'),
          folder('tracks', 'NavTracks'),
        ];
      case AudioService.recentRootId:
        final current = _vm.player.currentTrack;
        return current == null ? const [] : [_item(current, playable: true)];
      case 'albums':
        return [
          for (final album in _vm.albums.inSortOrder(library.albums).take(_maxItems))
            MediaItem(
              id: 'album:${album.id}',
              title: album.title,
              artist: album.artist,
              displaySubtitle: album.artist,
              artUri: _art(album.coverArtPath),
              playable: false,
            ),
        ];
      case 'artists':
        return [
          for (final artist in _vm.artists.inSortOrder(library.artists).take(_maxItems))
            MediaItem(
              id: 'artist:${artist.id}',
              title: artist.name,
              displaySubtitle: Localizer.format('AlbumCount', [artist.albumCount]),
              artUri: _art(artist.picturePath),
              playable: false,
            ),
        ];
      case 'playlists':
        // As the Playlists page lists them: the most and the recently played first.
        return [
          for (final playlist in _vm.playlists.allPlaylists)
            MediaItem(
              id: 'playlist:${playlist.id}',
              title: playlist.name,
              displaySubtitle: Localizer.format('TrackCount', [playlist.trackCount]),
              playable: false,
            ),
        ];
    }

    final tracks = _tracksOf(parentMediaId);
    return [for (final t in tracks.take(_maxItems)) _item(t, playable: true, context: parentMediaId)];
  }

  Future<void> _refreshTokenIfNeeded() async {
    if (_vm.session.isLoggedIn) _streamToken = await _vm.session.getStreamToken();
  }

  /// The tracks of a list's media ID.
  List<Track> _tracksOf(String listId) {
    final library = _vm.library;
    final colon = listId.indexOf(':');
    final kind = colon < 0 ? listId : listId.substring(0, colon);
    final id = colon < 0 ? '' : listId.substring(colon + 1);
    return switch (kind) {
      'album' => library.getAlbum(id)?.tracks ?? const [],
      'artist' => library.getArtist(id)?.tracks ?? const [],
      'playlist' => switch (_vm.playlists.allPlaylists.where((p) => p.id == id).firstOrNull) {
        final p? => _vm.playlists.tracksOf(p),
        null => const [],
      },
      // In the order chosen in the app (without its genre filter).
      'favorites' => _vm.favorites.tracks,
      'tracks' => _vm.tracks.tracks,
      'search' => _found(id),
      _ => const [],
    };
  }

  /// What a search for [query] shows in the car, and plays from the result picked.
  List<Track> _found(String query) => _vm.library.search(query).take(_maxSearchResults).toList();

  static const int _maxSearchResults = 50;

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final bar = mediaId.lastIndexOf('|');
    final trackId = bar >= 0 ? mediaId.substring(bar + 1) : mediaId.replaceFirst('track:', '');
    final track = _vm.library.getTrack(trackId);
    return track == null ? null : _item(track, playable: true);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final bar = mediaId.lastIndexOf('|');
    if (bar >= 0) {
      final tracks = _tracksOf(mediaId.substring(0, bar));
      final start = tracks.where((t) => t.id == mediaId.substring(bar + 1)).firstOrNull;
      if (tracks.isNotEmpty) _vm.player.playQueue(tracks, start);
      return;
    }
    if (mediaId.startsWith('track:')) {
      final track = _vm.library.getTrack(mediaId.substring(6));
      if (track != null) _vm.player.playQueueTrack(track);
      return;
    }
    final tracks = _tracksOf(mediaId);
    if (tracks.isNotEmpty) _vm.player.playQueue(tracks);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    await _refreshTokenIfNeeded();
    return [for (final t in _found(query)) _item(t, playable: true, context: 'search:$query')];
  }

  /// "Play … on Wiretune": an artist, an album, or the tracks that match; nothing named plays everything.
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final library = _vm.library;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _vm.player.shuffleQueue(library.tracks);
    final artist = library.artists.where((a) => a.name.toLowerCase() == q).firstOrNull;
    if (artist != null) return _vm.player.playQueue(artist.tracks, null, () => artist.name);
    final album = library.albums.where((a) => a.title.toLowerCase() == q).firstOrNull;
    if (album != null) return _vm.player.playQueue(album.tracks, null, () => album.title);
    final tracks = library.search(query).toList();
    if (tracks.isNotEmpty) _vm.player.playQueue(tracks);
  }

  final Map<String, BehaviorSubject<Map<String, dynamic>>> _children = {};

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
      _children.putIfAbsent(parentMediaId, () => BehaviorSubject.seeded(<String, dynamic>{}));

  /// Tells a browsing client (Android Auto) that the lists changed, so it asks for them again.
  void notifyChildrenChanged() {
    for (final subject in _children.values) {
      subject.add(<String, dynamic>{});
    }
  }
}
