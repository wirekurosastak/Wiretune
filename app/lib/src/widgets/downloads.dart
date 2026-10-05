// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// The download button of a list (an album, a playlist, the favourites): keeps the whole list on this device, or lets
/// it go again. While the copies arrive a ring around it fills up (only as they do: nothing moves on its own). Not
/// there for a list without server tracks, which has nothing to download.
class DownloadListButton extends StatelessWidget {
  const DownloadListButton({super.key, required this.tracks, required this.isPinned, required this.onPressed});

  final List<Track> tracks;
  final bool Function() isPinned;
  final VoidCallback onPressed;

  /// The button for [tracks]; null when none of them can be downloaded (the list gets no button).
  static Widget? forTracks(List<Track> tracks, {required bool Function() isPinned, required VoidCallback onPressed}) =>
      tracks.any(DownloadService.canDownload)
      ? DownloadListButton(tracks: tracks, isPinned: isPinned, onPressed: onPressed)
      : null;

  /// The button's diameter: as tall as the play and shuffle buttons beside it.
  static double size(BuildContext context) => PhoneChrome.isPhone(context) ? 48 : 46;

  @override
  Widget build(BuildContext context) {
    final downloads = context.vm.downloads;
    final colors = context.colors;
    return ValueListenableBuilder(
      valueListenable: downloads.states,
      builder: (context, _, _) {
        final (done, total) = downloads.progressOf(tracks);
        if (total == 0) return const SizedBox.shrink();
        final pinned = isPinned();
        final complete = pinned && done == total;
        final dimension = size(context);
        return SizedBox.square(
          dimension: dimension,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (pinned && !complete)
                SizedBox.square(
                  dimension: dimension,
                  child: CircularProgressIndicator(
                    value: done / total,
                    strokeWidth: 2.5,
                    color: colors.accent,
                    backgroundColor: colors.glassBorder,
                  ),
                ),
              IconButton(
                tooltip: !pinned
                    ? context.tr('TipDownload')
                    : (complete
                          ? context.tr('TipRemoveDownload')
                          : context.trf('DownloadsListProgress', [done, total])),
                style: IconButton.styleFrom(
                  fixedSize: Size.square(dimension),
                  side: BorderSide(color: pinned ? colors.accent.withValues(alpha: 0.6) : colors.glassBorder),
                  backgroundColor: pinned ? colors.accent.withValues(alpha: 0.12) : null,
                ),
                onPressed: onPressed,
                icon: Icon(
                  complete
                      ? Icons.download_done_rounded
                      : (pinned ? Icons.downloading_rounded : Icons.download_rounded),
                  size: 22,
                  color: pinned ? colors.accent : colors.textMain,
                ),
              ),
            ],
          ),
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
  if (downloads.isPinnedByList(track)) return context.tr('TipDownloadedWithList');
  return context.tr(downloads.isTrackPinned(track) ? 'TipRemoveDownload' : 'TipDownload');
}
