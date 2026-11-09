// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/downloads_view_model.dart';
import 'dialogs.dart';
import 'page_parts.dart';

/// Opens what is known of the playing track and the way it takes to the speakers: its file (format, bitrate, size), and
/// the signal path, as *Settings → Audio* shows it (where it comes from, what is done to it, the output and what that
/// opened). A sheet on a phone, a dialog elsewhere. A tap on the player's quality tags opens it.
Future<void> showTrackInfo(BuildContext context) async {
  if (context.vm.player.currentTrack == null) return;
  if (PhoneChrome.isPhone(context)) {
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: Text(
            sheet.tr('SignalPath'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: sheet.colors.textMain),
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(24, 0, 24, 16), child: TrackInfo()),
      ],
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: dialog.tr('SignalPath'),
      content: const DialogScroll(maxHeight: 460, child: TrackInfo()),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Close')))],
    ),
  );
}

/// The playing track's title and file, then its signal path line by line; following the track and the output as they
/// change. While another device plays, only the track's own file: the path is that device's.
class TrackInfo extends StatelessWidget {
  const TrackInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([vm.player, vm.audioSettings]),
      builder: (context, _) {
        final track = vm.player.currentTrack;
        if (track == null) return const SizedBox.shrink();
        final format = track.format;
        final file = [
          format.tagSpec,
          if (format.bitrateKbps > 0) context.trf('BitrateKbps', [format.bitrateKbps]),
          if (track.fileSizeBytes > 0) _size(track.fileSizeBytes),
        ].join('  ·  ');
        final lines = vm.player.isRemote ? const <String>[] : vm.audioSettings.signalPath.split('\n');
        TextStyle line(Color color) => TextStyle(fontSize: 13, height: 1.5, color: color);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${track.title} • ${track.artist}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: colors.textMain),
            ),
            const SizedBox(height: 4),
            Text(file, style: line(colors.textMuted)),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final text in lines)
                if (text.isNotEmpty) Text(text, style: line(colors.textMain)),
            ],
          ],
        );
      },
    );
  }

  static String _size(int bytes) {
    final (amount, unit) = DownloadsViewModel.sizeOf(bytes);
    return Localizer.formatTemplate('{0} {1}', [amount, unit], Localizer.instance.language);
  }
}
