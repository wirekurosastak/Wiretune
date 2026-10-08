// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The download buttons (a track, an album, an artist, a playlist, the favourites) and the Downloads card in the
/// settings.
class DownloadsViewModel extends ChangeNotifier {
  DownloadsViewModel(this._downloads) {
    _unsubscribe = _downloads.changed.listen((_) => _onChanged());
  }

  final DownloadService _downloads;
  late final void Function() _unsubscribe;
  final ValueNotifier<Object?> _states = ValueNotifier(null);
  int _pinChanges = 0;

  /// Notifies when a track's or a list's download state changes, but not at every byte of progress: what the rows and
  /// the buttons follow. The view model itself notifies at every change, progress included (the settings card).
  ValueListenable<Object?> get states => _states;

  void _onChanged() {
    final signature = (_downloads.doneCount, _downloads.wantedCount, _downloads.currentTrack?.id, _pinChanges);
    if (signature != _states.value) _states.value = signature;
    notifyListeners();
  }

  // ── A track ────────────────────────────────────────────────────────────────────────────────────

  /// Only a server track can be downloaded; a local file is on the device already.
  bool canDownload(Track track) => DownloadService.canDownload(track);

  DownloadState stateOf(Track track) => _downloads.stateOf(track);

  /// The track itself was marked (not only the album, playlist or favourites it belongs to).
  bool isTrackPinned(Track track) => _downloads.isTrackPinned(track.id);

  /// Wanted because of a list it is on, not by itself: its own button cannot remove it.
  bool isPinnedByList(Track track) => _downloads.isWanted(track) && !isTrackPinned(track);

  void toggleTrack(Track track) => _pin(_downloads.pinTrack(track.id, !isTrackPinned(track)));

  // ── A list ─────────────────────────────────────────────────────────────────────────────────────

  bool isAlbumPinned(Album album) => _downloads.isAlbumPinned(album.id);

  void toggleAlbum(Album album) => _pin(_downloads.pinAlbum(album.id, !isAlbumPinned(album)));

  /// All the artist's albums, also the ones that arrive later.
  bool isArtistPinned(Artist artist) => _downloads.isArtistPinned(artist.id);

  void toggleArtist(Artist artist) => _pin(_downloads.pinArtist(artist.id, !isArtistPinned(artist)));

  bool isPlaylistPinned(Playlist playlist) => _downloads.isPlaylistPinned(playlist.id);

  void togglePlaylist(Playlist playlist) => _pin(_downloads.pinPlaylist(playlist.id, !isPlaylistPinned(playlist)));

  bool get areFavoritesPinned => _downloads.areFavoritesPinned;

  void toggleFavorites() => _pin(_downloads.pinFavorites(!areFavoritesPinned));

  /// How many of [tracks] are downloaded, of how many that can be.
  (int done, int total) progressOf(Iterable<Track> tracks) => _downloads.progressOf(tracks);

  void _pin(Future<void> change) {
    _pinChanges++;
    unawaited(
      change.catchError((Object e) {
        WiretuneLog.warn('Downloads', 'Could not save the downloads: $e');
      }),
    );
  }

  // ── The settings card ──────────────────────────────────────────────────────────────────────────

  int get downloadedCount => _downloads.doneCount;
  int get wantedCount => _downloads.wantedCount;
  bool get hasAnything => _downloads.wantedCount > 0 || _downloads.bytesOnDisk > 0;

  /// "1.4 GB on this device" (with the language's decimal separator).
  String get sizeText {
    final (amount, unit) = sizeOf(_downloads.bytesOnDisk);
    return Localizer.format('DownloadsSize', [amount, unit]);
  }

  /// What the downloads are doing, in a sentence.
  String get statusText {
    final error = _downloads.errorMessage;
    if (error != null) return error;
    final current = _downloads.currentTrack;
    if (current != null) {
      final percent = (_downloads.currentProgress * 100).round();
      return Localizer.format('DownloadsProgress', [current.title, percent, downloadedCount + 1, wantedCount]);
    }
    if (_downloads.isWaitingForServer) return Localizer.format('DownloadsWaiting', [wantedCount - downloadedCount]);
    if (wantedCount == 0) return Localizer.get('DownloadsNone');
    return Localizer.format('DownloadsUpToDate', [downloadedCount]);
  }

  bool get hasError => _downloads.errorMessage != null;

  /// Forgets every mark and deletes every copy.
  Future<void> removeAll() async {
    _pinChanges++;
    await _downloads.removeAll();
  }

  /// [bytes] in the unit that reads best: 820 KB, 34 MB, 1.4 GB.
  static (double amount, String unit) sizeOf(int bytes) {
    const mb = 1024 * 1024, gb = 1024 * mb;
    if (bytes < mb) return ((bytes / 1024).ceilToDouble(), 'KB');
    if (bytes < gb) return ((bytes / mb).roundToDouble(), 'MB');
    return ((bytes / gb * 10).round() / 10, 'GB');
  }

  @override
  void dispose() {
    _unsubscribe();
    _states.dispose();
    super.dispose();
  }
}
