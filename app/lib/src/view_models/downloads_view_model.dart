// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

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
  int _changes = 0;

  /// Notifies when a track's or a list's download state changes, but not at every byte of progress: what the rows and
  /// the buttons follow. The view model itself notifies at every change, progress included (the settings card).
  ValueListenable<Object?> get states => _states;

  void _onChanged() {
    final signature = (_downloads.doneCount, _downloads.wantedCount, _downloads.currentTrack?.id, _changes);
    if (signature != _states.value) _states.value = signature;
    notifyListeners();
  }

  // ── A track ────────────────────────────────────────────────────────────────────────────────────

  /// Only a server track can be downloaded; a local file is on the device already.
  bool canDownload(Track track) => DownloadService.canDownload(track);

  DownloadState stateOf(Track track) => _downloads.stateOf(track);

  /// The track itself was chosen for download (not only the album, playlist or favourites it belongs to).
  bool isTrackDownloaded(Track track) => _downloads.isTrackDownloaded(track.id);

  /// Wanted because of a list it is on, not by itself: its own button cannot remove it.
  bool isDownloadedWithList(Track track) => _downloads.isWanted(track) && !isTrackDownloaded(track);

  void toggleTrack(Track track) => _change(() => _downloads.setTrackDownloaded(track.id, !isTrackDownloaded(track)));

  // ── A list ─────────────────────────────────────────────────────────────────────────────────────

  bool isAlbumDownloaded(Album album) => _downloads.isAlbumDownloaded(album.id);

  void toggleAlbum(Album album) => _change(() => _downloads.setAlbumDownloaded(album.id, !isAlbumDownloaded(album)));

  /// All the artist's albums, also the ones that arrive later.
  bool isArtistDownloaded(Artist artist) => _downloads.isArtistDownloaded(artist.id);

  void toggleArtist(Artist artist) =>
      _change(() => _downloads.setArtistDownloaded(artist.id, !isArtistDownloaded(artist)));

  bool isPlaylistDownloaded(Playlist playlist) => _downloads.isPlaylistDownloaded(playlist.id);

  void togglePlaylist(Playlist playlist) =>
      _change(() => _downloads.setPlaylistDownloaded(playlist.id, !isPlaylistDownloaded(playlist)));

  bool get areFavoritesDownloaded => _downloads.areFavoritesDownloaded;

  void toggleFavorites() => _change(() => _downloads.setFavoritesDownloaded(!areFavoritesDownloaded));

  /// How many of [tracks] are downloaded, of how many that can be.
  (int done, int total) progressOf(Iterable<Track> tracks) => _downloads.progressOf(tracks);

  void _change(void Function() change) {
    _changes++;
    try {
      change();
    } catch (e) {
      WiretuneLog.warn('Downloads', 'Could not save the downloads: $e');
    }
  }

  // ── The settings card ──────────────────────────────────────────────────────────────────────────

  int get downloadedCount => _downloads.doneCount;
  int get wantedCount => _downloads.wantedCount;
  bool get hasAnything => _downloads.wantedCount > 0 || _downloads.bytesOnDisk > 0;
  String get destinationDirectory => _downloads.directory;
  bool get isSyncModeEnabled => _downloads.isSyncModeEnabled;

  void setSyncModeEnabled(bool enabled) => _downloads.setSyncModeEnabled(enabled);

  /// "1.4 GB on this device" (with the language's decimal separator).
  String get sizeText {
    final (amount, unit) = sizeOf(_downloads.bytesOnDisk);
    return Localizer.format('DownloadsSize', [amount, unit]);
  }

  /// "1.4 GB" (with the language's decimal separator).
  String get sizeLabel {
    final (amount, unit) = sizeOf(_downloads.bytesOnDisk);
    return Localizer.formatTemplate('{0} {1}', [amount, unit], Localizer.instance.language);
  }

  /// How many tracks are downloaded on this device (signing out deletes them).
  int get copyCount => _downloads.copyCount;

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

  /// Forgets every choice and deletes every copy.
  void removeAll() => _change(_downloads.removeAll);

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
