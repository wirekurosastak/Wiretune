// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cards.dart';
import '../widgets/dialogs.dart';
import '../widgets/downloads.dart';
import '../widgets/page_parts.dart';
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
        if (selected != null) return PlaylistDetail(playlist: selected);
        if (!playlists.hasPlaylists) {
          return EmptyState(
            icon: Icons.queue_music,
            title: context.tr('EmptyPlaylistsTitle'),
            hint: context.tr('EmptyPlaylistsHint'),
            actions: [
              PressShrink(
                child: FilledButton(
                  onPressed: () => showNewPlaylistDialog(context),
                  child: Text(context.tr('PlaylistNew')),
                ),
              ),
            ],
          );
        }
        return TabPageList(
          title: context.tr('NavPlaylists'),
          storageKey: 'playlists',
          header: PageHeader(
            title: context.tr('NavPlaylists'),
            subtitle: context.trf('PlaylistCount', [playlists.allPlaylists.length]),
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
              PressShrink(
                child: FilledButton.icon(
                  onPressed: () => showNewPlaylistDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(context.tr('PlaylistNew')),
                ),
              ),
            ],
          ),
          slivers: [
            PlaylistsSliver(
              playlists: playlists.allPlaylists,
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
              // As wide as the header leaves beside its two buttons, up to 400; one line of the title's size.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: TextField(
                    controller: _name,
                    autofocus: true,
                    maxLength: UserDataRules.maxPlaylistNameLength,
                    decoration: const InputDecoration(
                      counterText: '',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    onSubmitted: playlists.confirmRenamePlaylist,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.tr('Save'),
                icon: Icon(Icons.check_rounded, color: colors.accent),
                onPressed: () => playlists.confirmRenamePlaylist(_name.text),
              ),
              IconButton(
                tooltip: context.tr('Cancel'),
                icon: const Icon(Icons.close_rounded),
                onPressed: playlists.cancelRename,
              ),
            ],
          )
        : Tooltip(
            message: context.tr('Rename'),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.tag),
              onTap: () {
                _name.text = playlist.name;
                playlists.startRename();
              },
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

    final menu = ListMenu.playlist(playlist, tracks, onPlay: playlists.playPlaylist);
    return PinnedTitleBar(
      title: playlist.name,
      onBack: playlists.closePlaylistDetail,
      backText: playlists.backText,
      menu: menu.topBarButton(),
      child: CustomScrollView(
        key: PageStorageKey('playlist-${playlist.id}-${playlists.pageVisit}'),
        slivers: [
          PinnedTitleBar.room,
          SliverToBoxAdapter(
            child: DetailHeader(
              back: BackLink(text: playlists.backText, onPressed: playlists.closePlaylistDetail),
              artwork: PlaylistCover(covers: playlistCovers(tracks), radius: Radii.card),
              artworkFlight: 'playlist:${playlist.id}',
              artworkBadge: switch (qualityOf(tracks)) {
                final quality? => QualityTag(tier: quality.tier, spec: quality.spec, fontSize: 11),
                null => null,
              },
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
                  tracks: tracks,
                  onPlay: tracks.isEmpty ? null : () => playlists.playPlaylist(),
                  playNext: menu.playNextButton(),
                  addToQueue: menu.addToQueueButton(),
                  addToPlaylist: menu.addToPlaylistButton(),
                  download: playlist.isAutomatic
                      ? null
                      : DownloadListButton.forTracks(
                          tracks,
                          name: playlist.name,
                          isDownloaded: () => context.vm.downloads.isPlaylistDownloaded(playlist),
                          onPressed: () => context.vm.downloads.togglePlaylist(playlist),
                        ),
                  remove: menu.removeButton(),
                ),
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
      ),
    );
  }
}
