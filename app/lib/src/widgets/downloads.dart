// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
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
    return ValueListenableBuilder(
      valueListenable: downloads.states,
      builder: (context, _, _) {
        final (done, total) = downloads.progressOf(tracks);
        if (total == 0) return const SizedBox.shrink();
        final pinned = isPinned();
        final complete = pinned && done == total;
        final dimension = size(context);
        return _DownloadHoverButton(
          pinned: pinned,
          complete: complete,
          done: done,
          total: total,
          dimension: dimension,
          tooltip: !pinned
              ? context.tr('TipDownload')
              : (complete
                    ? context.tr('TipRemoveDownload')
                    : context.trf('DownloadsListProgress', [done, total])),
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
  if (downloads.isPinnedByList(track)) return context.tr('TipDownloadedWithList');
  return context.tr(downloads.isTrackPinned(track) ? 'TipRemoveDownload' : 'TipDownload');
}

class _DownloadHoverButton extends StatefulWidget {
  const _DownloadHoverButton({
    required this.pinned,
    required this.complete,
    required this.done,
    required this.total,
    required this.dimension,
    required this.tooltip,
    required this.onPressed,
  });

  final bool pinned;
  final bool complete;
  final int done;
  final int total;
  final double dimension;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_DownloadHoverButton> createState() => _DownloadHoverButtonState();
}

class _DownloadHoverButtonState extends State<_DownloadHoverButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = widget.pinned ? colors.accent : colors.textMain;
    return PopEffect(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: SizedBox.square(
          dimension: widget.dimension,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.pinned && !widget.complete)
                SizedBox.square(
                  dimension: widget.dimension,
                  child: CircularProgressIndicator(
                    value: widget.total > 0 ? widget.done / widget.total : 0,
                    strokeWidth: 2.5,
                    color: colors.accent,
                    backgroundColor: colors.glassBorder,
                  ),
                ),
              IconButton(
                tooltip: widget.tooltip,
                hoverColor: Colors.transparent,
                highlightColor: Colors.transparent,
                splashColor: Colors.transparent,
                focusColor: Colors.transparent,
                style: IconButton.styleFrom(
                  side: BorderSide.none,
                  backgroundColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  overlayColor: Colors.transparent,
                  splashFactory: NoSplash.splashFactory,
                ),
                onPressed: widget.onPressed,
                icon: Icon(
                  widget.complete
                      ? Icons.download_done_rounded
                      : (widget.pinned ? Icons.downloading_rounded : Icons.download_rounded),
                  size: 22,
                  color: iconColor,
                  shadows: _hover
                      ? [
                          BoxShadow(
                            color: iconColor.withValues(alpha: 0.7),
                            blurRadius: 14,
                          ),
                        ]
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
