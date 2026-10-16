// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';

/// The download button of a list (an album, a playlist, the favourites): keeps the whole list on this device, or lets
/// it go again. While the copies arrive a ring around it fills up (only as they do: nothing moves on its own). Not
/// there for a list without server tracks, which has nothing to download.
class DownloadListButton extends StatelessWidget {
  const DownloadListButton({super.key, required this.tracks, required this.isDownloaded, required this.onPressed});

  final List<Track> tracks;
  final bool Function() isDownloaded;
  final VoidCallback onPressed;

  /// The button for [tracks]; null when none of them can be downloaded (the list gets no button).
  static Widget? forTracks(
    List<Track> tracks, {
    required bool Function() isDownloaded,
    required VoidCallback onPressed,
  }) => tracks.any(DownloadService.canDownload)
      ? DownloadListButton(tracks: tracks, isDownloaded: isDownloaded, onPressed: onPressed)
      : null;

  @override
  Widget build(BuildContext context) {
    final downloads = context.vm.downloads;
    return ValueListenableBuilder(
      valueListenable: downloads.states,
      builder: (context, _, _) {
        final (done, total) = downloads.progressOf(tracks);
        if (total == 0) return const SizedBox.shrink();
        final downloaded = isDownloaded();
        final complete = downloaded && done == total;
        return HeaderIconButton(
          tooltip: !downloaded
              ? context.tr('TipDownload')
              : (complete ? context.tr('TipRemoveDownload') : context.trf('DownloadsListProgress', [done, total])),
          icon: complete
              ? Icons.download_done_rounded
              : (downloaded ? Icons.downloading_rounded : Icons.download_rounded),
          color: downloaded ? context.colors.accent : context.colors.textMain,
          progress: downloaded && !complete ? done / total : null,
          onPressed: onPressed,
        );
      },
    );
  }
}

/// A track's download state as an icon: the arrow (not kept), the arrow in progress (waiting or arriving) or the tick
/// (on this device). Null for a track that is not kept.
IconData? downloadIcon(DownloadState state) => switch (state) {
  DownloadState.none => null,
  DownloadState.queued || DownloadState.downloading => Icons.downloading_rounded,
  DownloadState.done => Icons.download_done_rounded,
};

/// The tooltip of a track's own download button: download, remove, or why it cannot be removed by itself.
String downloadTip(BuildContext context, Track track) {
  final downloads = context.vm.downloads;
  if (downloads.isDownloadedWithList(track)) return context.tr('TipDownloadedWithList');
  return context.tr(downloads.isTrackDownloaded(track) ? 'TipRemoveDownload' : 'TipDownload');
}
