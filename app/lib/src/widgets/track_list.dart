import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'cover_image.dart';
import 'common.dart';
import 'equalizer_bars.dart';
import 'quality_tag.dart';

/// Which list a track table shows; each has the columns and buttons the C# player gave it.
enum TrackTableKind {
  /// The library: cover, title, artist, album, quality, length, favourite, add to playlist.
  tracks,

  /// Favourites: the same, ending in a filled heart that removes the track from the favourites.
  favorites,

  /// An album: track number, title, quality, length, favourite, add to playlist.
  album,

  /// An artist: cover, title, album, quality, length, favourite, add to playlist.
  artist,

  /// A playlist: cover, title, artist, album, quality, length, favourite, remove from the playlist.
  playlist,

  /// Search results: cover, title, artist, album, length, favourite, add to playlist.
  search,
}

enum _Column { title, artist, album, quality, length }

/// A list of tracks as slivers: on a wide screen a table in a glass frame (header row, a line between rows, sortable
/// columns), on a phone rows of cover, title and two buttons. The track that is playing is marked by bouncing bars.
class TrackSliver extends StatefulWidget {
  const TrackSliver({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.kind = TrackTableKind.tracks,
    this.sortable = true,
    this.horizontalPadding,
  });

  final List<Track> tracks;
  final void Function(Track track) onPlay;
  final TrackTableKind kind;
  final bool sortable;
  final double? horizontalPadding;

  @override
  State<TrackSliver> createState() => _TrackSliverState();
}

class _TrackSliverState extends State<TrackSliver> {
  _Column? _sortColumn;
  bool _descending = false;
  List<Track>? _sortedSource;
  List<Track> _sorted = const [];

  static const double _tableRowHeight = 46;
  static const double _phoneRowHeight = 68;

  TrackTableKind get kind => widget.kind;
  bool get _leadIsNumber => kind == TrackTableKind.album;
  bool get _showArtist => kind != TrackTableKind.album && kind != TrackTableKind.artist;
  bool get _showAlbum => kind != TrackTableKind.album;
  bool get _showQuality => kind != TrackTableKind.search;

  (int title, int artist, int album) get _flex => switch (kind) {
    TrackTableKind.album => (1, 0, 0),
    TrackTableKind.artist => (5, 0, 3),
    TrackTableKind.search => (5, 4, 4),
    _ => (4, 3, 3),
  };

  List<Track> get _tracks {
    final column = _sortColumn;
    if (column == null) return widget.tracks;
    if (identical(_sortedSource, widget.tracks)) return _sorted;
    final list = List.of(widget.tracks);
    int compare(Track a, Track b) => switch (column) {
      _Column.title => compareText(a.title, b.title),
      _Column.artist => compareText(a.artist, b.artist),
      _Column.album => compareText(a.album, b.album),
      _Column.quality => a.format.tier.index.compareTo(b.format.tier.index),
      _Column.length => a.duration.compareTo(b.duration),
    };
    sortStable(list, _descending ? (Track a, Track b) => compare(b, a) : compare);
    _sortedSource = widget.tracks;
    return _sorted = list;
  }

  void _sortBy(_Column column) {
    setState(() {
      if (_sortColumn == column) {
        if (_descending) {
          _sortColumn = null; // third click: back to the list's own order
          _descending = false;
        } else {
          _descending = true;
        }
      } else {
        _sortColumn = column;
        _descending = false;
      }
      _sortedSource = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // The desktop layout always draws the table (as the C# player did); the phone layout draws rows.
        final table = !PhoneChrome.isPhone(context);
        final padding = widget.horizontalPadding ?? (table ? 28.0 : 8.0);
        return ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final tracks = _tracks;
            final list = SliverFixedExtentList(
              itemExtent: table ? _tableRowHeight : _phoneRowHeight,
              delegate: SliverChildBuilderDelegate(
                (context, index) => table
                    ? _TableRow(track: tracks[index], last: index == tracks.length - 1, state: this)
                    : _PhoneRow(track: tracks[index], state: this),
                childCount: tracks.length,
              ),
            );
            if (!table) {
              return SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: list,
              );
            }
            // The glass frame is drawn by its parts (the header its rounded top, every row its sides and the line
            // under it, the last row the rounded bottom), so it scrolls with the rows it belongs to.
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
    final (titleFlex, artistFlex, albumFlex) = _flex;
    Widget separator() => Container(width: 1, height: 16, color: colors.glassBorder);
    Widget cell(String label, _Column? column, {int flex = 0, double? width}) {
      final active = column != null && _sortColumn == column;
      final text = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: active ? colors.accent : colors.textMuted,
                ),
              ),
            ),
            if (active) Icon(_descending ? Icons.arrow_downward : Icons.arrow_upward, size: 12, color: colors.accent),
          ],
        ),
      );
      final content = Row(
        children: [
          Expanded(
            child: widget.sortable && column != null ? InkWell(onTap: () => _sortBy(column), child: text) : text,
          ),
          separator(),
        ],
      );
      return width != null ? SizedBox(width: width, height: 36, child: content) : Expanded(flex: flex, child: content);
    }

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: colors.surface1,
        border: Border.all(color: colors.glassBorder),
        borderRadius: BorderRadius.vertical(
          top: const Radius.circular(8),
          bottom: Radius.circular(widget.tracks.isEmpty ? 8 : 0),
        ),
      ),
      child: Row(
        children: [
          cell(_leadIsNumber ? '#' : '', null, width: _leadIsNumber ? 52 : 50),
          cell(context.tr('ColTitle'), _Column.title, flex: titleFlex),
          if (_showArtist) cell(context.tr('ColArtist'), _Column.artist, flex: artistFlex),
          if (_showAlbum) cell(context.tr('ColAlbum'), _Column.album, flex: albumFlex),
          if (_showQuality) cell(context.tr('ColQuality'), _Column.quality, width: 215),
          cell(context.tr('ColLength'), _Column.length, width: 105),
          cell(
            '',
            null,
            width: kind == TrackTableKind.tracks || kind == TrackTableKind.album || kind == TrackTableKind.artist
                ? 50
                : 44,
          ),
          const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({required this.track, required this.last, required this.state});

  final Track track;
  final bool last;
  final _TrackSliverState state;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final playing = track.isPlaying;
    final (titleFlex, artistFlex, albumFlex) = state._flex;
    final onPlay = state.widget.onPlay;
    final kind = state.kind;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onPlay(track),
        hoverColor: colors.palette.glassHighlight.withValues(alpha: 0.6 * colors.palette.glassHighlight.a),
        child: CustomPaint(
          painter: _RowFramePainter(fill: colors.surface1, line: colors.glassBorder, last: last),
          child: Row(
            children: [
              SizedBox(
                width: state._leadIsNumber ? 52 : 50,
                child: Center(
                  child: state._leadIsNumber
                      ? (playing
                            ? const EqualizerBars()
                            : Text(
                                track.displayTrackNumber,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.textMain,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ))
                      : _Cover(track: track, playing: playing),
                ),
              ),
              Expanded(
                flex: titleFlex,
                child: _CellLink(
                  track.title,
                  hoverColor: colors.accent,
                  color: playing ? colors.accent : colors.textMain,
                  bold: playing,
                  onTap: () => onPlay(track),
                ),
              ),
              if (state._showArtist)
                Expanded(
                  flex: artistFlex,
                  child: _CellLink(
                    track.artist,
                    hoverColor: colors.palette.coral,
                    onTap: () => vm.openArtistByName(track.artist),
                  ),
                ),
              if (state._showAlbum)
                Expanded(
                  flex: albumFlex,
                  child: _CellLink(
                    track.album,
                    hoverColor: colors.palette.purple,
                    onTap: () => vm.openAlbumOfTrack(track),
                  ),
                ),
              if (state._showQuality)
                SizedBox(
                  width: 215,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: QualityTag(tier: track.format.tier, spec: track.format.tagSpec),
                    ),
                  ),
                ),
              SizedBox(
                width: 105,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    track.formattedDuration,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.textMain,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              ..._trailing(context, kind, track),
            ],
          ),
        ),
      ),
    );
  }
}

/// A table row's part of the glass frame: the fill, the side lines and the line under it; the last row closes the
/// frame with rounded corners.
class _RowFramePainter extends CustomPainter {
  const _RowFramePainter({required this.fill, required this.line, required this.last});

  final Color fill;
  final Color line;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 8.0;
    final rect = Offset.zero & size;
    final shape = last
        ? RRect.fromRectAndCorners(
            rect,
            bottomLeft: const Radius.circular(radius),
            bottomRight: const Radius.circular(radius),
          )
        : RRect.fromRectAndRadius(rect, Radius.zero);
    canvas.drawRRect(shape, Paint()..color = fill);
    final stroke = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final w = size.width - 0.5;
    final h = size.height - 0.5;
    final path = Path()..moveTo(0.5, 0);
    if (last) {
      path
        ..lineTo(0.5, h - radius)
        ..arcToPoint(Offset(radius + 0.5, h), radius: const Radius.circular(radius), clockwise: false)
        ..lineTo(w - radius, h)
        ..arcToPoint(Offset(w, h - radius), radius: const Radius.circular(radius), clockwise: false)
        ..lineTo(w, 0);
    } else {
      path
        ..lineTo(0.5, size.height)
        ..moveTo(w, 0)
        ..lineTo(w, size.height)
        ..moveTo(0, h)
        ..lineTo(size.width, h);
    }
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_RowFramePainter old) => old.fill != fill || old.line != line || old.last != last;
}

/// The buttons at the end of a row, per kind of list.
List<Widget> _trailing(BuildContext context, TrackTableKind kind, Track track, {bool phone = false}) {
  final vm = context.vm;
  final colors = context.colors;
  final size = phone ? 48.0 : 44.0;
  final favorite = _IconCell(
    width: !phone && (kind == TrackTableKind.tracks || kind == TrackTableKind.album || kind == TrackTableKind.artist)
        ? 50
        : size,
    tooltip: context.tr(track.isFavorite ? 'TipRemoveFromFavorites' : 'TipFavorite'),
    icon: track.isFavorite ? Icons.favorite : Icons.favorite_border,
    color: track.isFavorite ? colors.palette.coral : colors.textMuted,
    iconSize: phone ? 22 : 18,
    onPressed: () => vm.library.toggleFavorite(track.id),
  );
  final add = _IconCell(
    width: size,
    tooltip: context.tr('TipAddToPlaylist'),
    icon: Icons.playlist_add_rounded,
    color: colors.textMuted,
    iconSize: phone ? 22 : 18,
    onPressed: () => vm.addToPlaylist(track),
  );
  return switch (kind) {
    TrackTableKind.favorites when !phone => [
      add,
      _IconCell(
        width: size,
        tooltip: context.tr('TipRemoveFromFavorites'),
        icon: Icons.favorite,
        color: colors.palette.coral,
        iconSize: 18,
        onPressed: () => vm.favorites.removeFavorite(track),
      ),
    ],
    TrackTableKind.playlist => [
      favorite,
      _IconCell(
        width: size,
        tooltip: context.tr('TipRemoveFromPlaylist'),
        icon: Icons.playlist_remove_rounded,
        color: colors.danger,
        iconSize: phone ? 22 : 18,
        onPressed: () => vm.playlists.removeTrackFromSelected(track),
      ),
    ],
    _ => [favorite, add],
  };
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.width,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.iconSize,
    required this.onPressed,
  });

  final double width;
  final String tooltip;
  final IconData icon;
  final Color color;
  final double iconSize;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Center(
      child: IconButton(
        tooltip: tooltip,
        iconSize: iconSize,
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          fixedSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, color: color),
      ),
    ),
  );
}

/// A 32 px cover, with the bouncing bars over it while the track plays.
class _Cover extends StatelessWidget {
  const _Cover({required this.track, required this.playing, this.size = 32, this.radius = 4});

  final Track track;
  final bool playing;
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
        if (playing)
          DecoratedBox(
            decoration: BoxDecoration(color: const Color(0xA0000000), borderRadius: BorderRadius.circular(radius)),
            child: const Center(child: EqualizerBars()),
          ),
      ],
    ),
  );
}

/// A cell's text that is also a link: it takes [hoverColor] under the mouse.
class _CellLink extends StatefulWidget {
  const _CellLink(this.text, {required this.hoverColor, required this.onTap, this.color, this.bold = false});

  final String text;
  final Color hoverColor;
  final Color? color;
  final bool bold;
  final VoidCallback onTap;

  @override
  State<_CellLink> createState() => _CellLinkState();
}

class _CellLinkState extends State<_CellLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: widget.bold ? FontWeight.w600 : FontWeight.w400,
              color: _hover ? widget.hoverColor : (widget.color ?? context.colors.textMain),
            ),
          ),
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
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => state.widget.onPlay(track),
          child: Row(
            children: [
              const SizedBox(width: 8),
              if (state._leadIsNumber)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: playing
                        ? const EqualizerBars()
                        : Text(
                            track.displayTrackNumber,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.textMuted),
                          ),
                  ),
                )
              else
                _Cover(track: track, playing: playing, size: 48, radius: 8),
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
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: playing ? colors.accent : colors.textMain,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
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
