// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import 'cover_image.dart';
import 'common.dart';
import 'downloads.dart';
import 'equalizer_bars.dart';
import 'player_controls.dart';
import 'quality_tag.dart';

/// Which list a track table shows; each has its own columns and buttons. Every table ends in the download button of a
/// server track; a phone row has the favourite and a menu with the rest.
enum TrackTableKind {
  /// The library, and the favourites: cover, title, artist, album, quality, length, favourite, add to playlist.
  tracks,

  /// An album: track number, title, quality, length, favourite, add to playlist.
  album,

  /// An artist: cover, title, album, quality, length, favourite, add to playlist.
  artist,

  /// A playlist: cover, title, artist, album, length, year, the place in the playlist, quality, favourite, remove from
  /// the playlist.
  playlist,

  /// Search results: cover, title, artist, album, length, favourite, add to playlist.
  search,
}

/// A list of tracks as slivers: on a wide screen a table (a header row with sortable columns over rounded rows that
/// light up under the mouse), on a phone rows of cover, title, the favourite and a menu. The track that is playing is
/// washed in the accent and marked by bouncing bars; a downloaded one carries a tick. Playing a track makes the list
/// the queue, in the order it is shown.
class TrackSliver extends StatefulWidget {
  const TrackSliver({
    super.key,
    required this.tracks,
    this.sorting,
    this.kind = TrackTableKind.tracks,
    this.horizontalPadding,
  });

  final List<Track> tracks;

  /// The page's sort (Tracks, Favourites), which [tracks] are already in: the column headers change it, as the sort
  /// buttons do. Without one the list keeps its own order (an album's, a playlist's, the best match first) until a
  /// header sorts this table alone.
  final TrackSorting? sorting;
  final TrackTableKind kind;
  final double? horizontalPadding;

  /// The heights of the wide table's header and of its rows.
  static const double tableHeaderHeight = 40;
  static const double tableRowHeight = 52;

  @override
  State<TrackSliver> createState() => _TrackSliverState();
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
    return sorting != null ? sorting.addedAt(track) : track.dateAdded;
  }

  void _play(Track track) => context.vm.player.playQueue(_tracks, track);

  TrackTableKind get kind => widget.kind;
  bool get _leadIsNumber => kind == TrackTableKind.album;
  bool get _showArtist => kind != TrackTableKind.album && kind != TrackTableKind.artist;
  bool get _showAlbum => kind != TrackTableKind.album && _tableWidth >= 560;
  bool get _showYear =>
      (kind == TrackTableKind.tracks || kind == TrackTableKind.artist || kind == TrackTableKind.playlist) &&
      _tableWidth >= 720;
  bool get _showAdded => (kind == TrackTableKind.tracks || kind == TrackTableKind.playlist) && _tableWidth >= 880;
  bool get _showQuality => kind != TrackTableKind.search && _tableWidth >= 1060;

  int get _titleFlex {
    if (!_showArtist && !_showAlbum) return 8; // an album's table shows neither
    if (!_showArtist || !_showAlbum) return 7;
    return 6;
  }

  int get _artistFlex => 4;
  int get _albumFlex => 4;

  // The columns of figures are as wide as their longest header (German) and value; the text columns share the rest.
  static const double _lengthWidth = 76;
  static const double _yearWidth = 112;
  static const double _addedWidth = 124;
  static const double _qualityWidth = 168;

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
    // The rows follow the player (the playing track) and the downloads (their states, not their every byte).
    final listenable = Listenable.merge([vm.player, vm.downloads.states]);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // The desktop layout always draws the table; the phone layout draws rows.
        final table = !PhoneChrome.isPhone(context);
        final padding = widget.horizontalPadding ?? (table ? 20.0 : 8.0);
        _tableWidth = constraints.crossAxisExtent - 2 * padding;
        return ListenableBuilder(
          listenable: listenable,
          builder: (context, _) {
            final tracks = _tracks;
            final list = SliverFixedExtentList(
              itemExtent: table ? TrackSliver.tableRowHeight : _phoneRowHeight,
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    table ? _TableRow(track: tracks[index], state: this) : _PhoneRow(track: tracks[index], state: this),
                childCount: tracks.length,
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
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(child: _header(context)),
                  list,
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.colors;
    Widget cell(String label, TrackSortField? column, {int flex = 0, double? width}) {
      final active = column != null && _sortField == column;
      final content = column != null
          ? _HeaderCell(label: label, active: active, descending: _descending, onTap: () => _sortBy(column))
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
          cell(_leadIsNumber ? '#' : '', null, width: _leadIsNumber ? 48 : 56),
          cell(context.tr('ColTitle'), TrackSortField.title, flex: _titleFlex),
          if (_showArtist) cell(context.tr('ColArtist'), TrackSortField.artist, flex: _artistFlex),
          if (_showAlbum) cell(context.tr('ColAlbum'), TrackSortField.album, flex: _albumFlex),
          cell(context.tr('ColLength'), TrackSortField.length, width: _lengthWidth),
          if (_showYear) cell(context.tr('ColYear'), TrackSortField.year, width: _yearWidth),
          if (_showAdded) cell(context.tr('ColAdded'), TrackSortField.added, width: _addedWidth),
          if (_showQuality) cell(context.tr('ColQuality'), TrackSortField.quality, width: _qualityWidth),
          const SizedBox(width: 4 * 44),
        ],
      ),
    );
  }
}

/// A table row: rounded, lit under the mouse (where the number or the cover turns into a play button) and washed in
/// the accent while its track plays.
class _TableRow extends StatefulWidget {
  const _TableRow({required this.track, required this.state});

  final Track track;
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
    final playing = track.isPlaying;
    final onPlay = state._play;
    final kind = state.kind;
    final radius = BorderRadius.circular(Radii.small + 2);
    final Widget lead;
    if (state._leadIsNumber) {
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
      lead = _Cover(track: track, playing: playing, hover: _hover, size: 38, radius: 7);
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
            color: _hover ? colors.surface1 : colors.surface1.withValues(alpha: 0),
            gradient: playing
                ? LinearGradient(colors: [colors.accent.withValues(alpha: 0.2), colors.accent.withValues(alpha: 0.03)])
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: () => onPlay(track),
              onSecondaryTapUp: (details) => _showTrackContextMenu(context, details.globalPosition, track, kind),
              child: Row(
                children: [
                  SizedBox(
                    width: state._leadIsNumber ? 48 : 56,
                    child: Center(child: lead),
                  ),
                  Expanded(
                    flex: state._titleFlex,
                    // The row plays the track; the title is no link of its own (one more stop for the keyboard).
                    child: _CellLink(track.title, color: playing ? colors.accent : colors.textMain, bold: true),
                  ),
                  if (state._showArtist)
                    Expanded(
                      flex: state._artistFlex,
                      child: _CellLink(
                        track.artist,
                        hoverColor: colors.palette.coral,
                        color: colors.textMuted,
                        onTap: () => vm.openArtistByName(track.artist),
                      ),
                    ),
                  if (state._showAlbum)
                    Expanded(
                      flex: state._albumFlex,
                      child: _CellLink(
                        track.album,
                        hoverColor: colors.palette.purple,
                        color: colors.textMuted,
                        onTap: () => vm.openAlbumOfTrack(track),
                      ),
                    ),
                  _FigureCell(track.formattedDuration, width: _TrackSliverState._lengthWidth),
                  if (state._showYear) _FigureCell(track.year?.toString() ?? '—', width: _TrackSliverState._yearWidth),
                  if (state._showAdded)
                    _FigureCell(
                      // A playlist knows no date of its tracks, only the order they were added in.
                      kind == TrackTableKind.playlist
                          ? '${vm.playlists.positionOf(track) ?? '—'}'
                          : switch (state._addedAt(track)) {
                              final date? => context.trf('DateShort', [date]),
                              null => '—',
                            },
                      width: _TrackSliverState._addedWidth,
                    ),
                  if (state._showQuality)
                    SizedBox(
                      width: _TrackSliverState._qualityWidth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: QualityTag(tier: track.format.tier, spec: track.format.tagSpec),
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

/// The buttons at the end of a row, per kind of list: on a phone the favourite and the menu, in the table the
/// favourite, the list's own button and the download.
List<Widget> _trailing(BuildContext context, TrackTableKind kind, Track track, {bool phone = false}) {
  final vm = context.vm;
  final colors = context.colors;
  final size = phone ? 48.0 : 44.0;
  final favorite = _IconCell(
    width: size,
    tooltip: context.tr(track.isFavorite ? 'TipRemoveFromFavorites' : 'TipFavorite'),
    icon: HeartIcon(
      filled: track.isFavorite,
      color: track.isFavorite ? colors.palette.coral : colors.textMuted,
      size: phone ? 22 : 18,
    ),
    onPressed: () => vm.library.toggleFavorite(track.id),
  );
  if (phone) return [favorite, TrackMenu(track: track, kind: kind, width: size)];

  final add = _IconCell(
    width: size,
    tooltip: context.tr('TipAddToPlaylist'),
    icon: Icon(Icons.playlist_add_rounded, color: colors.textMuted, size: 18),
    onPressed: () => vm.addToPlaylist(track),
  );
  final downloads = vm.downloads;
  final state = downloads.stateOf(track);
  final download = !downloads.canDownload(track)
      ? SizedBox(width: size)
      : _IconCell(
          width: size,
          tooltip: downloadTip(context, track),
          icon: Icon(
            downloadIcon(state) ?? Icons.download_rounded,
            color: state == DownloadState.none ? colors.textMuted : colors.accent,
            size: 18,
          ),
          // Kept because its album, playlist or the favourites are: those buttons let it go.
          onPressed: downloads.isPinnedByList(track) ? null : () => downloads.toggleTrack(track),
        );
  final isHidden = vm.library.isTrackExplicitlyHidden(track.id);
  final hide = _IconCell(
    width: size,
    tooltip: context.tr(isHidden ? 'Unhide' : 'HideTrack'),
    icon: Icon(isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: colors.textMuted, size: 18),
    onPressed: () {
      if (isHidden) {
        vm.library.unhideTrack(track.id);
      } else {
        vm.library.hideTrack(track.id);
      }
    },
  );
  return switch (kind) {
    TrackTableKind.playlist => [
      favorite,
      _IconCell(
        width: size,
        tooltip: context.tr('TipRemoveFromPlaylist'),
        icon: Icon(Icons.playlist_remove_rounded, color: colors.danger, size: 18),
        onPressed: () => vm.playlists.removeTrackFromSelected(track),
      ),
      download,
      hide,
    ],
    _ => [favorite, add, download, hide],
  };
}

enum TrackAction { addToPlaylist, removeFromPlaylist, download, openAlbum, openArtist, hideTrack }

Future<void> _showTrackContextMenu(BuildContext context, Offset position, Track track, TrackTableKind kind) async {
  final action = await showMenu<TrackAction>(
    context: context,
    position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
    items: TrackMenu.buildMenuItems(context, track, kind),
  );
  if (action != null && context.mounted) {
    TrackMenu.handleAction(context, action, track);
  }
}

/// The "⋮" menu of a track, on a phone's rows and its full-screen player: what the table has as buttons (a playlist,
/// the download), and the way to the album and the artist.
class TrackMenu extends StatelessWidget {
  const TrackMenu({super.key, required this.track, required this.kind, required this.width, this.color});

  final Track track;

  /// The list it is shown in, which decides the entries (a playlist's can remove the track; an album's has no way to
  /// the album).
  final TrackTableKind kind;
  final double width;

  /// The dots' colour; muted when not given.
  final Color? color;

  static List<PopupMenuEntry<TrackAction>> buildMenuItems(BuildContext context, Track track, TrackTableKind kind) {
    final vm = context.vm;
    final colors = context.colors;
    final downloads = vm.downloads;
    final isHidden = vm.library.isTrackExplicitlyHidden(track.id);
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
    return [
      item(TrackAction.addToPlaylist, Icons.playlist_add_rounded, context.tr('TipAddToPlaylist')),
      if (kind == TrackTableKind.playlist)
        item(
          TrackAction.removeFromPlaylist,
          Icons.playlist_remove_rounded,
          context.tr('TipRemoveFromPlaylist'),
          color: colors.danger,
        ),
      if (downloads.canDownload(track))
        item(
          TrackAction.download,
          downloadIcon(downloads.stateOf(track)) ?? Icons.download_rounded,
          downloadTip(context, track),
          enabled: !downloads.isPinnedByList(track),
        ),
      if (kind != TrackTableKind.album) item(TrackAction.openAlbum, Icons.album_rounded, context.tr('GoToAlbum')),
      if (kind != TrackTableKind.artist) item(TrackAction.openArtist, Icons.person_rounded, context.tr('GoToArtist')),
      item(
        TrackAction.hideTrack,
        isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        context.tr(isHidden ? 'Unhide' : 'HideTrack'),
        color: colors.textMuted,
      ),
    ];
  }

  static void handleAction(BuildContext context, TrackAction action, Track track) {
    final vm = context.vm;
    switch (action) {
      case TrackAction.addToPlaylist:
        vm.addToPlaylist(track);
      case TrackAction.removeFromPlaylist:
        vm.playlists.removeTrackFromSelected(track);
      case TrackAction.download:
        vm.downloads.toggleTrack(track);
      case TrackAction.openAlbum:
        vm.openAlbumOfTrack(track);
      case TrackAction.openArtist:
        vm.openArtistByName(track.artist);
      case TrackAction.hideTrack:
        if (vm.library.isTrackExplicitlyHidden(track.id)) {
          vm.library.unhideTrack(track.id);
        } else {
          vm.library.hideTrack(track.id);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: width,
      child: Center(
        child: PopupMenuButton<TrackAction>(
          tooltip: context.tr('TipMore'),
          icon: Icon(Icons.more_vert_rounded, color: color ?? colors.textMuted, size: 22),
          onSelected: (action) => handleAction(context, action, track),
          itemBuilder: (context) => buildMenuItems(context, track, kind),
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
  const _Cover({required this.track, required this.playing, this.hover = false, this.size = 32, this.radius = 4});

  final Track track;
  final bool playing;
  final bool hover;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(path: track.coverArtPath, size: size, radius: radius, placeholderIcon: Icons.music_note),
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
    final playing = track.isPlaying;
    final subtitle = [
      track.artist,
      if (state._showAlbum && state.kind != TrackTableKind.artist) track.album,
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: playing ? colors.accent.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.card),
          onTap: () => state._play(track),
          child: Row(
            children: [
              const SizedBox(width: 8),
              if (state._leadIsNumber)
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
            ],
          ),
        ),
      ),
    );
  }
}

/// A table cell of figures (a length, a year, a date): muted, one line, the digits lined up.
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
                Icon(
                  descending ? Icons.south_rounded : Icons.north_rounded,
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
