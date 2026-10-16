// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/downloads.dart';
import '../widgets/quality_tag.dart';
import '../widgets/track_list.dart';
import 'library_pages.dart';

class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final playlists = context.vm.playlists;
    return ListenableBuilder(
      listenable: playlists,
      builder: (context, _) {
        final selected = playlists.selectedPlaylist;
        if (playlists.isPlaylistDetailOpen && selected != null) return PlaylistDetail(playlist: selected);
        if (!playlists.hasPlaylists) {
          return EmptyState(
            icon: Icons.queue_music,
            title: context.tr('EmptyPlaylistsTitle'),
            hint: context.tr('EmptyPlaylistsHint'),
            actions: [FilledButton(onPressed: playlists.openCreateDialog, child: Text(context.tr('PlaylistNew')))],
          );
        }
        return CustomScrollView(
          key: const PageStorageKey('playlists'),
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: context.tr('NavPlaylists'),
                subtitle: context.trf('PlaylistCount', [playlists.playlists.length]),
                actions: [
                  SortButtons(
                    buttons: [
                      for (final field in PlaylistSortField.values)
                        (
                          playlists.listSortLabel(field),
                          playlists.listSortField == field,
                          () => playlists.setListSortField(field),
                        ),
                    ],
                  ),
                  FilledButton.icon(
                    onPressed: playlists.openCreateDialog,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(context.tr('PlaylistNew')),
                  ),
                ],
              ),
            ),
            PlaylistsSliver(
              playlists: [...playlists.automaticPlaylists, ...playlists.playlists],
              tracksOf: playlists.tracksOf,
              onOpen: playlists.openPlaylist,
              onPlay: playlists.playPlaylist,
            ),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

class PlaylistDetail extends StatefulWidget {
  const PlaylistDetail({super.key, required this.playlist});

  final Playlist playlist;

  @override
  State<PlaylistDetail> createState() => _PlaylistDetailState();
}

class _PlaylistDetailState extends State<PlaylistDetail> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = context.vm.playlists;
    final playlist = widget.playlist;
    final colors = context.colors;
    final tracks = playlists.selectedPlaylistTracks;

    final title = playlist.isAutomatic
        ? null
        : playlists.isEditingName
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 240, maxWidth: 400),
                child: TextField(
                  controller: _name..text = _name.text.isEmpty ? playlists.editingPlaylistName : _name.text,
                  autofocus: true,
                  maxLength: UserDataRules.maxPlaylistNameLength,
                  decoration: const InputDecoration(counterText: ''),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  onSubmitted: (value) => playlists.confirmRenamePlaylist(value).then((_) => _name.clear()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.tr('Save'),
                icon: Icon(Icons.check_rounded, color: colors.accent),
                onPressed: () => playlists.confirmRenamePlaylist(_name.text).then((_) => _name.clear()),
              ),
              IconButton(
                tooltip: context.tr('Cancel'),
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _name.clear();
                  playlists.cancelRename();
                },
              ),
            ],
          )
        : Tooltip(
            message: context.tr('Rename'),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: playlists.startRename,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DetailHeader.isNarrow(context)
                          ? TextStyle(
                              fontSize: 24,
                              letterSpacing: -0.6,
                              fontWeight: FontWeight.w800,
                              color: colors.textMain,
                            )
                          : DetailHeader.titleStyle(context),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.edit_rounded, size: 20, color: colors.textMuted),
                ],
              ),
            ),
          );

    return CustomScrollView(
      key: PageStorageKey('playlist-${playlist.id}'),
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            back: BackLink(text: context.tr('NavPlaylists'), onPressed: playlists.closePlaylistDetail),
            artwork: PlaylistCover(covers: playlistCovers(tracks), radius: Radii.card),
            artworkBadge: playlist.formatSpec.isEmpty
                ? null
                : QualityTag(tier: playlist.formatTier, spec: playlist.formatSpec, fontSize: 11),
            tags: [
              TagBadge(
                context.tr(playlist.isAutomatic ? 'LabelAutoPlaylist' : 'LabelPlaylist'),
                color: colors.palette.lime,
              ),
            ],
            title: playlist.name,
            titleWidget: title,
            details: [
              DetailText(context.trf('TrackCount', [playlist.trackCount])),
              if (playlists.selectedPlaylistTotalDuration.isNotEmpty)
                DetailText(playlists.selectedPlaylistTotalDuration),
            ],
            actions: [
              PlayShuffleButtons(
                onPlay: tracks.isEmpty ? null : () => playlists.playPlaylist(),
                onShuffle: tracks.isEmpty ? null : () => playlists.shufflePlaylist(),
                trailing: playlist.isAutomatic
                    ? null
                    : DownloadListButton.forTracks(
                        tracks,
                        isDownloaded: () => context.vm.downloads.isPlaylistDownloaded(playlist),
                        onPressed: () => context.vm.downloads.togglePlaylist(playlist),
                      ),
              ),
              CollectionMenu.playlist(playlist, tracks, onPlay: playlists.playPlaylist).headerButton(),
            ],
          ),
        ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.playlist_add,
              title: context.tr('PlaylistEmptyTitle'),
              hint: context.tr('PlaylistEmptyHint'),
            ),
          )
        else
          TrackSliver(
            tracks: tracks,
            sorting: playlists,
            kind: TrackTableKind.playlist,
            onReorder: playlists.canReorder ? playlists.moveTrack : null,
          ),
        const PageEndSpace(),
      ],
    );
  }
}

/// The playlist dialogs (new playlist, add to playlist, delete), shown over the page while the view model says so.
class PlaylistDialogsLayer extends StatefulWidget {
  const PlaylistDialogsLayer({super.key});

  @override
  State<PlaylistDialogsLayer> createState() => _PlaylistDialogsLayerState();
}

class _PlaylistDialogsLayerState extends State<PlaylistDialogsLayer> {
  final TextEditingController _name = TextEditingController();
  bool _wasCreateOpen = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = context.vm.playlists;
    return ListenableBuilder(
      listenable: playlists,
      builder: (context, _) {
        if (playlists.isCreateDialogOpen && !_wasCreateOpen) _name.text = playlists.newPlaylistName;
        _wasCreateOpen = playlists.isCreateDialogOpen;
        if (!playlists.isAnyDialogOpen) return const SizedBox.shrink();

        final Widget dialog;
        if (playlists.isCreateDialogOpen) {
          dialog = _DialogCard(
            title: context.tr('PlaylistNew'),
            onClose: playlists.closeCreateDialog,
            subtitle: playlists.tracksToAdd.isEmpty
                ? null
                : context.trf('PlaylistAlsoAddsTrack', [playlists.addingName]),
            content: TextField(
              controller: _name,
              autofocus: true,
              maxLength: UserDataRules.maxPlaylistNameLength,
              decoration: InputDecoration(hintText: context.tr('PlaylistNamePlaceholder'), counterText: ''),
              onSubmitted: (value) => playlists.createPlaylist(value),
            ),
            actions: [
              TextButton(onPressed: playlists.closeCreateDialog, child: Text(context.tr('Cancel'))),
              FilledButton(onPressed: () => playlists.createPlaylist(_name.text), child: Text(context.tr('Create'))),
            ],
          );
        } else if (playlists.isAddToPlaylistDialogOpen) {
          dialog = _DialogCard(
            title: context.tr('TipAddToPlaylist'),
            subtitle: playlists.addingName,
            onClose: playlists.cancelAddTrack,
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (!playlists.hasPlaylists)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        context.tr('NoPlaylistsCreateOne'),
                        style: TextStyle(color: context.colors.textMuted),
                      ),
                    ),
                  for (final playlist in playlists.playlists)
                    ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(playlist.name),
                      subtitle: Text(context.trf('TrackCount', [playlist.trackCount])),
                      onTap: () => playlists.addPendingTrackTo(playlist),
                    ),
                  ListTile(
                    leading: Icon(Icons.add_rounded, color: context.colors.accent),
                    title: Text(context.tr('PlaylistNew'), style: TextStyle(color: context.colors.accent)),
                    onTap: playlists.createPlaylistForPendingTrack,
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: playlists.cancelAddTrack, child: Text(context.tr('Cancel')))],
          );
        } else {
          final playlist = playlists.playlistPendingDelete;
          dialog = _DialogCard(
            title: context.tr('PlaylistDeleteAction'),
            onClose: playlists.cancelDeletePlaylist,
            content: Text(context.trf('PlaylistDeleteConfirm', [playlist?.name ?? ''])),
            actions: [
              TextButton(onPressed: playlists.cancelDeletePlaylist, child: Text(context.tr('Cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: context.colors.danger, foregroundColor: Colors.white),
                onPressed: playlists.confirmDeletePlaylist,
                child: Text(context.tr('Delete')),
              ),
            ],
          );
        }

        return Stack(
          children: [
            ModalBarrier(color: Colors.black54, dismissible: true, onDismiss: () => context.vm.tryNavigateBack()),
            Center(child: dialog),
          ],
        );
      },
    );
  }
}

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
    return Padding(
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
    );
  }
}
