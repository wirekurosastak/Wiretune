// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import 'badges.dart';
import 'buttons.dart';
import 'cover_flight.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'downloads.dart';
import 'equalizer_bars.dart';
import 'links.dart';
import 'page_parts.dart';
import 'player_controls.dart';

/// Which list a track table shows; each has its own columns, as far as the width allows. Every row ends in the
/// favourite and a menu with the rest.
enum TrackTableKind {
  /// The library, and the favourites: cover, title, artist, album, length, released, added, quality, bitrate.
  tracks,

  /// An album: track number, title, length, quality, bitrate; a heading over each disc of several.
  album,

  /// An artist: cover, title, album, length, released, quality, bitrate.
  artist,

  /// A playlist: cover, title, artist, album, length, released, the place in the playlist, quality, bitrate; its menu also
  /// removes the track and, in the playlist's own order, moves it.
  playlist,

  /// Search results: cover, title, artist, album, length.
  search,
}

/// A list of tracks as slivers: on a wide screen a table (a header row with sortable columns, which stays at the list's
/// top while the rows scroll, over rounded rows that light up under the mouse), on a phone rows of cover, title, the
/// favourite and a menu. The track that is playing is washed in the accent and marked by bouncing bars; a downloaded one
/// carries a tick. Playing a track makes the list the queue, in the order it is shown.
class TrackSliver extends StatefulWidget {
  const TrackSliver({
    super.key,
    required this.tracks,
    this.sorting,
    this.kind = TrackTableKind.tracks,
    this.horizontalPadding,
    this.onReorder,
    this.columnHeaders = true,
  });

  final List<Track> tracks;

  /// The page's sort (Tracks, Favourites), which [tracks] are already in: the column headers change it, as the sort
  /// buttons do. Without one the list keeps its own order (an album's, a playlist's, the best match first) until a
  /// header sorts this table alone.
  final TrackSorting? sorting;
  final TrackTableKind kind;
  final double? horizontalPadding;

  /// Moves the track shown at `from` to `to` (counted after it has been taken out): a playlist in its own order. Its
  /// rows then move under a long press, or (in a table) by the handle at their start.
  final void Function(int from, int to)? onReorder;

  /// Whether a table has its column headers over its rows; a tab page has them of its own ([TrackColumnHeaders],
  /// [TabPageList]), which stay put above the list.
  final bool columnHeaders;

  /// The space at a table's sides.
  static const double tablePadding = 20;

  /// The heights of the wide table's header and of its rows.
  static const double tableHeaderHeight = 40;
  static const double tableRowHeight = 52;

  @override
  State<TrackSliver> createState() => _TrackSliverState();
}

/// Which of a table's columns show at its width, and how they share it.
class _Columns {
  const _Columns(this.kind, this.width);

  final TrackTableKind kind;
  final double width;

  bool get leadIsNumber => kind == TrackTableKind.album;
  bool get showArtist => kind != TrackTableKind.album && kind != TrackTableKind.artist;
  bool get showAlbum => kind != TrackTableKind.album && width >= 560;
  bool get showReleased =>
      (kind == TrackTableKind.tracks || kind == TrackTableKind.artist || kind == TrackTableKind.playlist) &&
      width >= 720;
  bool get showAdded => (kind == TrackTableKind.tracks || kind == TrackTableKind.playlist) && width >= 880;
  bool get showQuality => kind != TrackTableKind.search && width >= 1060;

  int get titleFlex {
    if (!showArtist && !showAlbum) return 8; // an album's table shows neither
    if (!showArtist || !showAlbum) return 7;
    return 6;
  }

  int get artistFlex => 4;
  int get albumFlex => 4;

  // The columns of figures are as wide as their longest header (German) and value; the text columns share the rest.
  static const double lengthWidth = 76;
  static const double releasedWidth = 112;
  static const double addedWidth = 124;
  static const double qualityWidth = 168;
  static const double bitrateWidth = 104;

  // The drag handle at the start of a row that can be moved.
  static const double handleWidth = 24;
}

class _TrackSliverState extends State<TrackSliver> {
  // This table's own sort, for a list without a page's sort; null keeps the list's order.
  SortOrder<TrackSortField>? _own;
  List<Track>? _sortedSource;
  List<Track> _sorted = const [];
  double _tableWidth = 1200;

  // As large as the music apps' rows.
  static const double _phoneRowHeight = 76;

  @override
  void didUpdateWidget(TrackSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _own = null;
      _sortedSource = null;
    }
  }

  TrackSortField? get _sortField => widget.sorting?.sortField ?? _own?.field;
  bool get _descending => widget.sorting?.isSortDescending ?? _own?.descending ?? false;

  /// When [track] was added: to the favourites on that page, otherwise to the library.
  DateTime? _addedAt(Track track) {
    final sorting = widget.sorting;
    return sorting != null ? sorting.addedAt(track) : track.addedAt;
  }

  void _play(Track track) => context.vm.player.playQueue(_tracks, track);

  TrackTableKind get kind => widget.kind;
  _Columns get _columns => _Columns(kind, _tableWidth);

  /// The tracks in the order shown: the page sorts its own, this table those of a list without a page's sort.
  List<Track> get _tracks {
    final own = _own;
    if (widget.sorting != null || own == null) return widget.tracks;
    if (identical(_sortedSource, widget.tracks)) return _sorted;
    _sortedSource = widget.tracks;
    return _sorted = sortTracks(widget.tracks, own.field, descending: own.descending);
  }

  void _sortBy(TrackSortField field) {
    final sorting = widget.sorting;
    if (sorting != null) return sorting.setSortField(field);
    setState(() {
      final own = _own;
      if (own == null) {
        _own = SortOrder(field, startsDescending: startsDescending);
      } else {
        own.select(field);
      }
      _sortedSource = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    // The rows follow what plays (the playing track's mark), the favourites (the hearts) and the downloads (their
    // states, not their every byte).
    final listenable = Listenable.merge([vm.player.nowPlaying, vm.favorites, vm.downloads.states]);
    return SliverWidthBuilder(
      builder: (context, width) {
        // The desktop layout always draws the table; the phone layout draws rows.
        final table = !PhoneChrome.isPhone(context);
        final padding = widget.horizontalPadding ?? (table ? TrackSliver.tablePadding : 8.0);
        _tableWidth = width - 2 * padding;
        return ListenableBuilder(
          listenable: listenable,
          builder: (context, _) {
            final tracks = _tracks;
            Widget row(int index) => table
                ? _TableRow(track: tracks[index], index: index, state: this)
                : _PhoneRow(track: tracks[index], state: this);
            final reorder = widget.onReorder;
            final extent = table ? TrackSliver.tableRowHeight : _phoneRowHeight;
            Widget rows(int start, int end) => SliverFixedExtentList(
              itemExtent: extent,
              delegate: SliverChildBuilderDelegate((context, index) => row(start + index), childCount: end - start),
            );
            final discs = _discStarts(tracks);
            final Widget list = discs != null
                ? SliverMainAxisGroup(
                    slivers: [
                      for (final (i, start) in discs.indexed) ...[
                        SliverToBoxAdapter(child: _DiscHeader(disc: tracks[start].discNumber ?? 1)),
                        rows(start, i + 1 < discs.length ? discs[i + 1] : tracks.length),
                      ],
                    ],
                  )
                : reorder == null
                ? rows(0, tracks.length)
                : SliverReorderableList(
                    itemExtent: extent,
                    itemCount: tracks.length,
                    onReorderItem: reorder,
                    proxyDecorator: liftedRow(context, const EdgeInsets.symmetric(vertical: 2)),
                    itemBuilder: (context, index) => ReorderableDelayedDragStartListener(
                      key: ValueKey(tracks[index].id),
                      index: index,
                      child: row(index),
                    ),
                  );
            if (!table) {
              return SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: list,
              );
            }
            return SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              sliver: widget.columnHeaders
                  ? PinnedColumnHeaders(
                      headers: _ColumnHeaders(
                        columns: _columns,
                        reorderable: widget.onReorder != null,
                        sortField: _sortField,
                        descending: _descending,
                        onSort: _sortBy,
                      ),
                      rows: list,
                    )
                  : list,
            );
          },
        );
      },
    );
  }

  /// Where each disc of an album of several starts among [tracks] while they are in the album's own order; null for
  /// any other list or order.
  List<int>? _discStarts(List<Track> tracks) {
    if (kind != TrackTableKind.album || _sortField != null || tracks.isEmpty) return null;
    final starts = <int>[0];
    for (var i = 1; i < tracks.length; i++) {
      final previous = tracks[i - 1].discNumber ?? 1;
      final disc = tracks[i].discNumber ?? 1;
      if (disc < previous) return null;
      if (disc != previous) starts.add(i);
    }
    return starts.length > 1 ? starts : null;
  }
}

/// A tab page's column headers ([TabPageList]), for a table without its own ([TrackSliver.columnHeaders] off): they stay
/// put above the list while the rows scroll, and sort the page as the table's own do.
class TrackColumnHeaders extends StatelessWidget {
  const TrackColumnHeaders({super.key, required this.sorting});

  final TrackSorting sorting;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: TrackSliver.tablePadding),
        child: _ColumnHeaders(
          columns: _Columns(TrackTableKind.tracks, constraints.maxWidth - 2 * TrackSliver.tablePadding),
          reorderable: false,
          sortField: sorting.sortField,
          descending: sorting.isSortDescending,
          onSort: sorting.setSortField,
        ),
      ),
    );
  }
}

/// A table's header row: the columns' names, those of a sortable column sorting by it (again: the other way round).
class _ColumnHeaders extends StatelessWidget {
  const _ColumnHeaders({
    required this.columns,
    required this.reorderable,
    required this.sortField,
    required this.descending,
    required this.onSort,
  });

  final _Columns columns;
  final bool reorderable;
  final TrackSortField? sortField;
  final bool descending;
  final void Function(TrackSortField field) onSort;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget cell(String label, TrackSortField? column, {int flex = 0, double? width}) {
      final active = column != null && sortField == column;
      final content = column != null
          ? _HeaderCell(label: label, active: active, descending: descending, onTap: () => onSort(column))
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.9,
                    fontWeight: FontWeight.w700,
                    color: colors.textMuted,
                  ),
                ),
              ),
            );
      final sized = SizedBox(height: TrackSliver.tableHeaderHeight - 8, child: content);
      return width != null ? SizedBox(width: width, child: sized) : Expanded(flex: flex, child: sized);
    }

    return Container(
      height: TrackSliver.tableHeaderHeight,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.glassBorder)),
      ),
      child: Row(
        children: [
          if (reorderable) const SizedBox(width: _Columns.handleWidth),
          cell(columns.leadIsNumber ? '#' : '', null, width: columns.leadIsNumber ? 48 : 56),
          cell(context.tr('ColTitle'), TrackSortField.title, flex: columns.titleFlex),
          if (columns.showArtist) cell(context.tr('ColArtist'), TrackSortField.artist, flex: columns.artistFlex),
          if (columns.showAlbum) cell(context.tr('ColAlbum'), TrackSortField.album, flex: columns.albumFlex),
          cell(context.tr('ColLength'), TrackSortField.length, width: _Columns.lengthWidth),
          if (columns.showReleased)
            cell(context.tr('ColReleased'), TrackSortField.released, width: _Columns.releasedWidth),
          if (columns.showAdded) cell(context.tr('ColAdded'), TrackSortField.added, width: _Columns.addedWidth),
          if (columns.showQuality) cell(context.tr('ColQuality'), TrackSortField.quality, width: _Columns.qualityWidth),
          if (columns.showQuality) cell(context.tr('ColBitrate'), TrackSortField.bitrate, width: _Columns.bitrateWidth),
          const SizedBox(width: 2 * 44),
        ],
      ),
    );
  }
}

/// A table row: rounded, lit under the mouse (where the number or the cover turns into a play button) and washed in
/// the accent while its track plays.
class _TableRow extends StatefulWidget {
  const _TableRow({required this.track, required this.index, required this.state});

  final Track track;
  final int index;
  final _TrackSliverState state;

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final track = widget.track;
    final state = widget.state;
    final playing = vm.player.isCurrent(track);
    final onPlay = state._play;
    final kind = state.kind;
    final radius = BorderRadius.circular(Radii.medium);
    final Widget lead;
    if (state._columns.leadIsNumber) {
      lead = playing
          ? EqualizerBars(playing: vm.player.isPlaying)
          : _hover
          ? Icon(Icons.play_arrow_rounded, size: 22, color: colors.textMain)
          : Text(
              track.displayTrackNumber,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            );
    } else {
      lead = _Cover(track: track, playing: playing, hover: _hover, size: 38, radius: Radii.small);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            borderRadius: radius,
            // The playing track's soft wash, as on a phone's row.
            color: playing
                ? colors.accent.withValues(alpha: 0.12)
                : (_hover ? colors.surface1 : colors.surface1.withValues(alpha: 0)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: () => onPlay(track),
              onSecondaryTapUp: (details) => showTrackContextMenu(context, details.globalPosition, track, kind),
              child: Row(
                children: [
                  if (state.widget.onReorder != null)
                    ReorderableDragStartListener(
                      index: widget.index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: SizedBox(
                          width: _Columns.handleWidth,
                          height: TrackSliver.tableRowHeight,
                          child: Tooltip(
                            message: context.tr('TipDragToReorder'),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 16,
                              color: _hover ? colors.textMuted : colors.palette.textDisabled.withValues(alpha: 0),
                            ),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: state._columns.leadIsNumber ? 48 : 56,
                    child: Center(child: lead),
                  ),
                  Expanded(
                    flex: state._columns.titleFlex,
                    // The row plays the track; the title is no link of its own (one more stop for the keyboard). A kept
                    // track carries the download's mark after it, as on a phone.
                    child: Row(
                      children: [
                        Flexible(
                          child: _CellLink(track.title, color: playing ? colors.accent : colors.textMain, bold: true),
                        ),
                        if (downloadIcon(vm.downloads.stateOf(track)) case final icon?)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Icon(icon, size: 14, color: colors.accent),
                          ),
                      ],
                    ),
                  ),
                  if (state._columns.showArtist)
                    Expanded(
                      flex: state._columns.artistFlex,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ArtistLinks(
                            track.artistNames,
                            hoverColor: colors.palette.coral,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: colors.textMuted),
                            onOpen: vm.openArtistByName,
                          ),
                        ),
                      ),
                    ),
                  if (state._columns.showAlbum)
                    Expanded(
                      flex: state._columns.albumFlex,
                      child: _CellLink(
                        track.album,
                        hoverColor: colors.palette.purple,
                        color: colors.textMuted,
                        onTap: () => vm.openAlbumOfTrack(track),
                      ),
                    ),
                  _FigureCell(track.formattedDuration, width: _Columns.lengthWidth),
                  if (state._columns.showReleased)
                    _FigureCell(track.releaseYear?.toString() ?? '—', width: _Columns.releasedWidth),
                  if (state._columns.showAdded)
                    _FigureCell(
                      // A playlist knows no date of its tracks, only the order they were added in.
                      kind == TrackTableKind.playlist
                          ? '${vm.playlists.positionOf(track) ?? '—'}'
                          : switch (state._addedAt(track)) {
                              final date? => context.trf('DateShort', [date]),
                              null => '—',
                            },
                      width: _Columns.addedWidth,
                    ),
                  if (state._columns.showQuality)
                    SizedBox(
                      width: _Columns.qualityWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: QualityTag(tier: track.format.tier, spec: track.format.tagSpec),
                        ),
                      ),
                    ),
                  // The file's average bitrate, in the quality's colours.
                  if (state._columns.showQuality)
                    SizedBox(
                      width: _Columns.bitrateWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: QualityTag(
                            tier: track.format.tier,
                            spec: context.trf('BitrateKbps', [track.format.bitrateKbps]),
                          ),
                        ),
                      ),
                    ),
                  ..._trailing(context, kind, track),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The heart and the ⋮ menu at a row's end; a phone's row has the menu alone, with the favourite in it, so that the title
/// has the room.
List<Widget> _trailing(BuildContext context, TrackTableKind kind, Track track, {bool phone = false}) {
  if (phone) return [TrackMenu(track: track, kind: kind, width: 48, withFavorite: true)];
  final colors = context.colors;
  final favorite = context.vm.library.isFavorite(track.id);
  return [
    _IconCell(
      width: 44,
      tooltip: context.tr(favorite ? 'RemoveFromFavorites' : 'Favorite'),
      icon: HeartIcon(filled: favorite, color: favorite ? colors.palette.coral : colors.textMuted, size: 18),
      onPressed: () => context.vm.library.toggleFavorite(track.id),
    ),
    TrackMenu(track: track, kind: kind, width: 44),
  ];
}

/// In the order they show in a track's menu: a list's ([ListMenu]) with the track's own among them.
enum TrackAction {
  favorite,
  playNext,
  addToQueue,
  addToPlaylist,
  removeFromPlaylist,
  moveUp,
  moveDown,
  download,
  openAlbum,
  openArtist,
  hideTrack,
}

/// How a row being moved looks (a playlist's, the queue's): lifted off the list as a rounded card, a little larger, on a
/// soft shadow, easing into it as it is picked up and back as it is let go. [margin]: the room between the list's item
/// and the row's own rounded shape (its gap to the next). The row is drawn in the screen's overlay, above the phone's
/// layout: [list] (the list's context) says whether it is a phone's row, as large as the ones it is moved among.
ReorderItemProxyDecorator liftedRow(BuildContext list, EdgeInsets margin) {
  final phone = PhoneChrome.isPhone(list);
  return (child, index, animation) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final colors = context.colors;
      final lift = Curves.easeOutCubic.transform(animation.value);
      final shadow = colors.palette.shadow;
      return Transform.scale(
        scale: 1 + 0.02 * lift,
        child: Stack(
          children: [
            Positioned.fill(
              left: margin.left,
              top: margin.top,
              right: margin.right,
              bottom: margin.bottom,
              child: Opacity(
                opacity: lift,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // As the menus and sheets: black, or white in the light theme.
                    color: colors.palette.modal,
                    borderRadius: BorderRadius.circular(Radii.medium),
                    border: Border.all(color: colors.glassBorder),
                    boxShadow: [
                      BoxShadow(color: shadow, blurRadius: 24, spreadRadius: -6, offset: const Offset(0, 10)),
                    ],
                  ),
                ),
              ),
            ),
            child!,
          ],
        ),
      );
    },
    child: Material(
      type: MaterialType.transparency,
      child: phone ? PhoneChrome(child: child) : child,
    ),
  );
}

/// A right click on a track's row (a table's, the queue's): the track's menu, with the favourite first; on a phone, as
/// a sheet ([TrackMenu.showSheet]).
Future<void> showTrackContextMenu(BuildContext context, Offset position, Track track, TrackTableKind kind) async {
  if (PhoneChrome.isPhone(context)) return TrackMenu.showSheet(context, track, kind, withFavorite: true);
  final action = await showMenu<TrackAction>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
    items: TrackMenu.buildMenuItems(context, track, kind, withFavorite: true),
  );
  if (action != null && context.mounted) {
    TrackMenu.handleAction(context, action, track);
  }
}

/// The "⋮" menu of a track, on its row (a table's and a phone's), in the player bar and the phone's full-screen player:
/// play next and add to the queue, a playlist (and, in one, moving and removing the track), the download, the way to
/// the album and the artist, and hiding it. On a phone it is a sheet, with the track's cover and names on top
/// ([showSheet]).
class TrackMenu extends StatelessWidget {
  const TrackMenu({
    super.key,
    required this.track,
    required this.kind,
    required this.width,
    this.color,
    this.iconSize = 22,
    this.withFavorite = false,
  });

  final Track track;

  /// The list it is shown in, which decides the entries (a playlist's can remove the track; an album's has no way to
  /// the album).
  final TrackTableKind kind;
  final double width;

  /// The dots' colour; muted when not given.
  final Color? color;
  final double iconSize;

  /// Whether the menu has the favourite too: where no heart is beside it (a phone's row).
  final bool withFavorite;

  /// [withFavorite]: a menu without a heart beside it (the right click's, a phone row's) has the favourite too. What
  /// removes something is red, as in every menu; hiding isn't, a tap on its Undo away.
  static List<PopupMenuEntry<TrackAction>> buildMenuItems(
    BuildContext context,
    Track track,
    TrackTableKind kind, {
    bool withFavorite = false,
  }) {
    final vm = context.vm;
    final colors = context.colors;
    final downloads = vm.downloads;
    final isHidden = vm.library.isTrackExplicitlyHidden(track.id);
    final favorite = vm.library.isFavorite(track.id);
    PopupMenuItem<TrackAction> item(TrackAction action, IconData icon, String text, {Color? color, bool? enabled}) =>
        PopupMenuItem(
          value: action,
          enabled: enabled ?? true,
          child: Row(
            children: [
              Icon(icon, size: 20, color: color ?? colors.textMuted),
              const SizedBox(width: 14),
              Flexible(
                child: Text(text, style: TextStyle(color: color)),
              ),
            ],
          ),
        );
    // Moving needs the playlist in its own order; the arrows are the way to move it without dragging.
    final playlists = vm.playlists;
    final place = kind == TrackTableKind.playlist && playlists.canReorder ? playlists.positionOf(track) : null;
    return [
      if (withFavorite)
        item(
          TrackAction.favorite,
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          context.tr(favorite ? 'RemoveFromFavorites' : 'Favorite'),
          color: favorite ? colors.danger : null,
        ),
      item(TrackAction.playNext, Icons.queue_play_next_rounded, context.tr('PlayNext')),
      item(TrackAction.addToQueue, Icons.add_to_queue_rounded, context.tr('AddToQueue')),
      item(TrackAction.addToPlaylist, Icons.playlist_add_rounded, context.tr('AddToPlaylist')),
      if (place != null) ...[
        item(TrackAction.moveUp, Icons.arrow_upward_rounded, context.tr('MoveUp'), enabled: place > 1),
        item(
          TrackAction.moveDown,
          Icons.arrow_downward_rounded,
          context.tr('MoveDown'),
          enabled: place < playlists.selectedPlaylistTracks.length,
        ),
      ],
      if (downloads.canDownload(track))
        // Removing its own download is a bin, as in Settings; downloaded with a list, it shows how it stands.
        if (downloads.isTrackDownloaded(track) && !downloads.isDownloadedWithList(track))
          item(TrackAction.download, Icons.delete_outline_rounded, downloadTip(context, track), color: colors.danger)
        else
          item(
            TrackAction.download,
            downloadIcon(downloads.stateOf(track)) ?? Icons.download_rounded,
            downloadTip(context, track),
            enabled: !downloads.isDownloadedWithList(track),
          ),
      if (kind != TrackTableKind.album) item(TrackAction.openAlbum, Icons.album_rounded, context.tr('GoToAlbum')),
      if (kind != TrackTableKind.artist) item(TrackAction.openArtist, Icons.person_rounded, context.tr('GoToArtist')),
      // What takes the track away comes last, away from Add to playlist: a slip of one row can't remove instead of add.
      if (kind == TrackTableKind.playlist && playlists.selectedPlaylist?.isAutomatic == false)
        item(
          TrackAction.removeFromPlaylist,
          Icons.playlist_remove_rounded,
          context.tr('RemoveFromPlaylist'),
          color: colors.danger,
        ),
      item(
        TrackAction.hideTrack,
        isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        context.tr(isHidden ? 'Unhide' : 'HideTrack'),
      ),
    ];
  }

  static void handleAction(BuildContext context, TrackAction action, Track track) {
    final vm = context.vm;
    switch (action) {
      case TrackAction.favorite:
        vm.library.toggleFavorite(track.id);
      case TrackAction.playNext:
        vm.queue([track], next: true, name: track.title);
        CoverFlight.toPlayer(_Cover.flightTag(track));
      case TrackAction.addToQueue:
        vm.queue([track], next: false, name: track.title);
        CoverFlight.toPlayer(_Cover.flightTag(track));
      case TrackAction.addToPlaylist:
        showAddTrackToPlaylistDialog(context, track);
      case TrackAction.removeFromPlaylist:
        final playlist = vm.playlists.selectedPlaylist;
        final undo = vm.playlists.removeTrackFromSelected(track);
        if (undo != null) vm.showNotice(context.trf('RemovedFromPlaylist', [playlist!.name]), undo: undo);
      case TrackAction.moveUp || TrackAction.moveDown:
        final place = vm.playlists.positionOf(track);
        if (place != null) vm.playlists.moveTrack(place - 1, place - 1 + (action == TrackAction.moveUp ? -1 : 1));
      case TrackAction.download:
        vm.downloads.toggleTrack(track);
      case TrackAction.openAlbum:
        vm.openAlbumOfTrack(track);
      case TrackAction.openArtist:
        vm.openArtistByName(track.primaryArtist);
      case TrackAction.hideTrack:
        if (vm.library.isTrackExplicitlyHidden(track.id)) {
          vm.library.setHidden(HiddenKind.track, track.id, false);
        } else {
          vm.hide(HiddenKind.track, track.id, track.title);
        }
    }
  }

  /// The menu as a phone's sheet: the track's cover, title and artist on top.
  static Future<void> showSheet(
    BuildContext context,
    Track track,
    TrackTableKind kind, {
    bool withFavorite = false,
  }) async {
    final action = await showMenuSheet(
      context,
      cover: CoverImage(path: track.coverArtPath, size: menuSheetCoverSize, placeholderIcon: Icons.music_note),
      title: track.title,
      subtitle: track.artist,
      items: buildMenuItems(context, track, kind, withFavorite: withFavorite),
    );
    if (action != null && context.mounted) handleAction(context, action, track);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final icon = Icon(Icons.more_vert_rounded, color: color ?? colors.textMuted, size: iconSize);
    return SizedBox(
      width: width,
      child: Center(
        child: PhoneChrome.isPhone(context)
            ? IconButton(
                tooltip: context.tr('TipMore'),
                icon: icon,
                onPressed: () => showSheet(context, track, kind, withFavorite: withFavorite),
              )
            : PopupMenuButton<TrackAction>(
                tooltip: context.tr('TipMore'),
                icon: icon,
                onSelected: (action) => handleAction(context, action, track),
                itemBuilder: (context) => buildMenuItems(context, track, kind, withFavorite: withFavorite),
              ),
      ),
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({required this.width, required this.tooltip, required this.icon, required this.onPressed});

  final double width;
  final String tooltip;
  final Widget icon;

  /// Null shows the button disabled (its tooltip says why).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Center(
      child: IconButton(
        tooltip: tooltip,
        style: IconButton.styleFrom(
          minimumSize: const Size(34, 34),
          fixedSize: const Size(34, 34),
          padding: EdgeInsets.zero,
        ),
        onPressed: onPressed,
        icon: icon,
      ),
    ),
  );
}

/// A small cover, with the bouncing bars over it while the track plays, or a play button under the mouse.
class _Cover extends StatelessWidget {
  const _Cover({
    required this.track,
    required this.playing,
    this.hover = false,
    this.size = 32,
    this.radius = Radii.tag,
  });

  final Track track;
  final bool playing;
  final bool hover;
  final double size;
  final double radius;

  /// What the cover shows, for it to fly into the player's when the track is queued ([CoverFlight.toPlayer]).
  static String flightTag(Track track) => 'track:${track.id}';

  @override
  Widget build(BuildContext context) => CoverFlightSource(
    tag: flightTag(track),
    radius: radius,
    cover: CoverImage(path: track.coverArtPath, size: size, radius: radius, placeholderIcon: Icons.music_note),
    builder: _build,
  );

  Widget _build(BuildContext context, Widget cover) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      fit: StackFit.expand,
      children: [
        cover,
        if (playing || hover)
          DecoratedBox(
            decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(radius)),
            child: Center(
              child: playing
                  ? EqualizerBars(playing: context.vm.player.isPlaying, color: Colors.white)
                  : const Icon(Icons.play_arrow_rounded, size: 22, color: Colors.white),
            ),
          ),
      ],
    ),
  );
}

/// A cell's text that is also a link: it takes [hoverColor] under the mouse or the keyboard's focus.
class _CellLink extends StatelessWidget {
  const _CellLink(this.text, {this.hoverColor, this.onTap, this.color, this.bold = false});

  final String text;
  final Color? hoverColor;
  final Color? color;
  final bool bold;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Align(
      alignment: Alignment.centerLeft,
      child: LinkText(
        text,
        onTap: onTap,
        hoverColor: hoverColor,
        style: TextStyle(
          fontSize: bold ? 14 : 13.5,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
          color: color ?? context.colors.textMain,
        ),
      ),
    ),
  );
}

/// A phone row: cover (or the track number on an album), title, artist (and album), the favourite button and the
/// list's own button.
class _PhoneRow extends StatelessWidget {
  const _PhoneRow({required this.track, required this.state});

  final Track track;
  final _TrackSliverState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playing = context.vm.player.isCurrent(track);
    final subtitle = [
      track.artist,
      if (state._columns.showAlbum && state.kind != TrackTableKind.artist) track.album,
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: playing ? colors.accent.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          onTap: () => state._play(track),
          // A long press opens its menu, as on every other row; in a playlist that can be reordered it is the drag.
          onLongPress: state.widget.onReorder != null
              ? null
              : () => TrackMenu.showSheet(context, track, state.kind, withFavorite: true),
          child: Row(
            children: [
              const SizedBox(width: 8),
              if (state._columns.leadIsNumber)
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Center(
                    child: playing
                        ? EqualizerBars(playing: context.vm.player.isPlaying)
                        : Text(
                            track.displayTrackNumber,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.textMuted),
                          ),
                  ),
                )
              else
                _Cover(track: track, playing: playing, size: 56, radius: Radii.small),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: playing ? colors.accent : colors.textMain,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (downloadIcon(context.vm.downloads.stateOf(track)) case final icon?) ...[
                          Icon(icon, size: 14, color: colors.accent),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: colors.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ..._trailing(context, state.kind, track, phone: true),
              const SizedBox(width: 8), // as much room as before the cover
            ],
          ),
        ),
      ),
    );
  }
}

/// A table cell of figures (a length, a release year, a date): muted, one line, the digits lined up.
class _FigureCell extends StatelessWidget {
  const _FigureCell(this.text, {required this.width});

  final String text;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: context.colors.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ),
  );
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.active, required this.descending, required this.onTap});

  final String label;
  final bool active;
  final bool descending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = active ? colors.accent : colors.textMain;
    return Pressable(
      onPressed: onTap,
      builder: (context, lit) => AnimatedScale(
        scale: lit ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.9,
                    fontWeight: FontWeight.w700,
                    color: color,
                    shadows: lit ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 10)] : null,
                  ),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                SortArrow(
                  descending: descending,
                  size: 12,
                  color: colors.accent,
                  shadows: lit ? [BoxShadow(color: colors.accent.withValues(alpha: 0.7), blurRadius: 10)] : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The heading over one disc's tracks on the page of an album of several discs.
class _DiscHeader extends StatelessWidget {
  const _DiscHeader({required this.disc});

  final int disc;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
      child: Row(
        children: [
          Icon(Icons.album_rounded, size: 16, color: colors.textMuted),
          const SizedBox(width: 8),
          Text(
            context.trf('DiscNumber', [disc]),
            style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
