// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import 'buttons.dart';

/// Asks before an action that can't easily be taken back. True when the user confirmed it. Cancel has the focus, so a
/// stray press of a remote's OK button doesn't confirm a [destructive] action, which is red.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: title,
      content: Text(message),
      actions: [
        TextButton(
          autofocus: destructive,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.tr('Cancel')),
        ),
        PressShrink(
          child: FilledButton(
            autofocus: !destructive,
            style: destructive ? FilledButton.styleFrom(backgroundColor: ctx.colors.danger) : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Asks what a swipe left or right does in the full-screen player (at the first one); null when the question is
/// dismissed.
Future<PlayerSwipe?> askPlayerSwipe(BuildContext context) => showDialog<PlayerSwipe>(
  context: context,
  builder: (ctx) => AppDialog(
    title: ctx.tr('PlayerSwipeQuestion'),
    content: Text(ctx.tr('PlayerSwipeLater')),
    actions: [
      for (final (choice, key) in [(PlayerSwipe.tracks, 'PlayerSwipeTracks'), (PlayerSwipe.tabs, 'PlayerSwipeTabs')])
        OutlinedButton(onPressed: () => Navigator.of(ctx).pop(choice), child: Text(ctx.tr(key))),
    ],
  ),
);

/// Signs out of the server; first asks when that deletes the downloads on this device.
Future<void> confirmAndSignOut(BuildContext context) async {
  final vm = context.vm;
  final downloads = vm.downloads;
  if (downloads.copyCount > 0) {
    final confirmed = await confirmAction(
      context,
      title: context.tr('SignOutConfirm'),
      message: context.trf('SignOutConfirmDownloads', [downloads.copyCount, downloads.sizeLabel]),
      confirmLabel: context.tr('SignOut'),
      destructive: true,
    );
    if (!confirmed) return;
  }
  await vm.logout();
}

/// Asks for a name and makes a playlist, starting with [tracks] (called [adding] in the dialog) when there are any, and
/// opens it.
Future<void> showNewPlaylistDialog(
  BuildContext context, {
  List<Track> tracks = const [],
  String name = '',
  String adding = '',
}) => showDialog<void>(
  context: context,
  builder: (_) => _NewPlaylistDialog(tracks: tracks, name: name, adding: adding),
);

/// Puts [tracks] (called [label] in the dialog) into the playlist the user picks, or into a new one that starts as
/// [suggestedName].
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  List<Track> tracks, {
  required String label,
  required String suggestedName,
}) async {
  if (tracks.isEmpty) return;
  final playlists = context.vm.playlists;
  final createNew = await showDialog<bool>(
    context: context,
    builder: (dialog) => AppDialog(
      title: dialog.tr('TipAddToPlaylist'),
      subtitle: label,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (!playlists.hasPlaylists)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(dialog.tr('NoPlaylistsCreateOne'), style: TextStyle(color: dialog.colors.textMuted)),
              ),
            for (final playlist in playlists.playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                subtitle: Text(dialog.trf('TrackCount', [playlist.trackCount])),
                onTap: () {
                  playlists.addTracks(playlist, tracks);
                  Navigator.pop(dialog);
                },
              ),
            ListTile(
              leading: Icon(Icons.add_rounded, color: dialog.colors.accent),
              title: Text(dialog.tr('PlaylistNew'), style: TextStyle(color: dialog.colors.accent)),
              onTap: () => Navigator.pop(dialog, true),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Cancel')))],
    ),
  );
  if (createNew == true && context.mounted) {
    await showNewPlaylistDialog(context, tracks: tracks, name: suggestedName, adding: label);
  }
}

/// The "add to playlist" dialog for one track.
Future<void> showAddTrackToPlaylistDialog(BuildContext context, Track track) =>
    showAddToPlaylistDialog(context, [track], label: '${track.title} • ${track.artist}', suggestedName: track.album);

/// Asks before [playlist] is deleted.
Future<void> confirmDeletePlaylist(BuildContext context, Playlist playlist) async {
  final confirmed = await confirmAction(
    context,
    title: context.tr('PlaylistDeleteAction'),
    message: context.trf('PlaylistDeleteConfirm', [playlist.name]),
    confirmLabel: context.tr('Delete'),
    destructive: true,
  );
  if (confirmed && context.mounted) context.vm.playlists.deletePlaylist(playlist);
}

class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog({required this.tracks, required this.name, required this.adding});

  final List<Track> tracks;
  final String name;
  final String adding;

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    if (_name.text.trim().isEmpty) return;
    context.vm.playlists.createPlaylist(_name.text, widget.tracks);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: context.tr('PlaylistNew'),
    subtitle: widget.tracks.isEmpty ? null : context.trf('PlaylistAlsoAddsTrack', [widget.adding]),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: UserDataRules.maxPlaylistNameLength,
      decoration: InputDecoration(hintText: context.tr('PlaylistNamePlaceholder'), counterText: ''),
      onSubmitted: (_) => _create(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
      PressShrink(
        child: FilledButton(onPressed: _create, child: Text(context.tr('Create'))),
      ),
    ],
  );
}

/// Every dialog of the app, one look: the title (and a line about what it is for), the content, and the buttons at the
/// bottom right, Cancel first. No close button: Cancel, Back or a tap beside it closes it. A TV remote's focus starts in
/// it.
class AppDialog extends StatelessWidget {
  const AppDialog({super.key, required this.title, this.subtitle, required this.content, required this.actions});

  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: FocusScope(
            autofocus: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.textMain),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(subtitle!, style: TextStyle(fontSize: 13, color: colors.textMuted)),
                  ),
                const SizedBox(height: 14),
                DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 14, height: 1.4, color: colors.textMain),
                  child: content,
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: OverflowBar(
                    spacing: 8,
                    overflowSpacing: 8,
                    overflowAlignment: OverflowBarAlignment.end,
                    children: actions,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
