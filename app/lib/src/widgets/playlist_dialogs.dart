// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';

/// Asks for a name and makes a playlist, starting with [tracks] (called [adding] in the dialog) when there are any, and
/// opens it.
Future<void> showNewPlaylistDialog(
  BuildContext context, {
  List<Track> tracks = const [],
  String name = '',
  String adding = '',
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
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
    useSafeArea: false,
    builder: (dialog) => _DialogCard(
      title: dialog.tr('TipAddToPlaylist'),
      subtitle: label,
      onClose: () => Navigator.pop(dialog),
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
  final confirmed = await showDialog<bool>(
    context: context,
    useSafeArea: false,
    builder: (dialog) => _DialogCard(
      title: dialog.tr('PlaylistDeleteAction'),
      onClose: () => Navigator.pop(dialog),
      content: Text(dialog.trf('PlaylistDeleteConfirm', [playlist.name])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: dialog.colors.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(dialog.tr('Delete')),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) context.vm.playlists.deletePlaylist(playlist);
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
  Widget build(BuildContext context) => _DialogCard(
    title: context.tr('PlaylistNew'),
    onClose: () => Navigator.pop(context),
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
      FilledButton(onPressed: _create, child: Text(context.tr('Create'))),
    ],
  );
}

/// The card of the playlist dialogs: a title with a close button, a line about what it is for, the content and the
/// buttons, in the middle of the screen.
class _DialogCard extends StatelessWidget {
  const _DialogCard({
    required this.title,
    this.subtitle,
    required this.content,
    required this.actions,
    required this.onClose,
  });

  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: colors.palette.modal,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: colors.palette.glassBorder),
            ),
            elevation: 12,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: FocusScope(
                autofocus: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.textMain),
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr('Close'),
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(subtitle!, style: TextStyle(fontSize: 13, color: colors.textMuted)),
                      ),
                    const SizedBox(height: 8),
                    content,
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (final action in actions) Padding(padding: const EdgeInsets.only(left: 8), child: action),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
