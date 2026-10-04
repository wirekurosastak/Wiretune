import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../localization.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import 'cover_image.dart';
import 'quality_tag.dart';

/// Whether tiles are drawn as the desktop's framed cards (fixed size, a badge and a play button) or as the phone's
/// plain cover-and-caption tiles. [TileGridSliver] decides it from the width and passes it down.
class _TileStyle extends InheritedWidget {
  const _TileStyle({required this.phone, required super.child});

  final bool phone;

  static bool phoneOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TileStyle>()?.phone ?? PhoneChrome.isPhone(context);

  @override
  bool updateShouldNotify(_TileStyle oldWidget) => phone != oldWidget.phone;
}

/// An album: cover, title, artist, track count and year, then the format and a play button.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, required this.onOpen, this.onPlay});

  final Album album;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final purple = colors.palette.purple;
    if (_TileStyle.phoneOf(context)) {
      return _PhoneTile(
        onTap: onOpen,
        cover: CoverImage(path: album.coverArtPath, radius: 8, placeholderIcon: Icons.album, placeholderColor: purple),
        title: album.title,
        subtitle: album.artist,
      );
    }
    final details = [
      context.trf('TrackCount', [album.trackCount]),
      if (album.year != null) '${album.year}',
    ].join('  •  ');
    return MetricCard(
      accent: purple,
      onTap: onOpen,
      child: _DesktopTile(
        cover: CoverImage(path: album.coverArtPath, radius: 6, placeholderIcon: Icons.album, placeholderColor: purple),
        lines: [
          _line(album.title, 14, FontWeight.w700, colors.textMain),
          _line(album.artist, 12, FontWeight.w400, colors.textMuted),
          _line(details, 11, FontWeight.w400, colors.textMuted),
        ],
        badge: QualityTag(tier: album.tier, spec: album.tagSpec, compact: true),
        play: TilePlayButton(color: purple, onPressed: onPlay, tooltip: context.tr('Play')),
      ),
    );
  }
}

/// An artist: round picture, name, track count, the "ARTIST" label and a play button.
class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist, required this.onOpen, this.onPlay});

  final Artist artist;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final coral = colors.palette.coral;
    final picture = CoverImage(
      path: artist.picturePath,
      circle: true,
      placeholderIcon: Icons.person,
      placeholderColor: coral,
    );
    if (_TileStyle.phoneOf(context)) {
      return _PhoneTile(
        onTap: onOpen,
        cover: picture,
        title: artist.name,
        subtitle: context.trf('TrackCount', [artist.trackCount]),
        centered: true,
      );
    }
    return MetricCard(
      accent: coral,
      onTap: onOpen,
      child: _DesktopTile(
        cover: Center(
          child: SizedBox.square(dimension: _DesktopTile.coverHeight, child: picture),
        ),
        lines: [
          _line(artist.name, 14, FontWeight.w700, colors.textMain),
          _line(context.trf('TrackCount', [artist.trackCount]), 12, FontWeight.w400, colors.textMuted),
        ],
        badge: TagBadge(context.tr('ColArtist'), color: coral),
        play: TilePlayButton(color: coral, onPressed: onPlay, tooltip: context.tr('Play')),
      ),
    );
  }
}

/// A playlist's cover: a 2x2 collage of its albums, one cover, or an icon.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({super.key, required this.covers, this.radius = 6});

  final List<String> covers;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final lime = context.colors.palette.lime;
    if (covers.isEmpty) {
      return CoverImage(path: null, radius: radius, placeholderIcon: Icons.queue_music, placeholderColor: lime);
    }
    if (covers.toSet().length == 1) {
      return CoverImage(path: covers.first, radius: radius, placeholderIcon: Icons.queue_music, placeholderColor: lime);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [for (final c in covers.take(4)) CoverImage(path: c, radius: 0, decodeWidth: 256)],
      ),
    );
  }
}

/// A playlist: its cover collage, name, track count, the format and a play button.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({super.key, required this.playlist, required this.covers, required this.onOpen, this.onPlay});

  final Playlist playlist;
  final List<String> covers;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final lime = colors.palette.lime;
    if (_TileStyle.phoneOf(context)) {
      return _PhoneTile(
        onTap: onOpen,
        cover: PlaylistCover(covers: covers, radius: 8),
        title: playlist.name,
        subtitle: context.trf('TrackCount', [playlist.trackCount]),
      );
    }
    return MetricCard(
      accent: lime,
      onTap: onOpen,
      child: _DesktopTile(
        cover: PlaylistCover(covers: covers),
        lines: [
          _line(playlist.name, 14, FontWeight.w700, colors.textMain),
          _line(context.trf('TrackCount', [playlist.trackCount]), 12, FontWeight.w400, colors.textMuted),
        ],
        badge: playlist.formatBadge.isEmpty
            ? const SizedBox.shrink()
            : QualityTag(tier: playlist.formatTier, spec: playlist.formatSpec, compact: true),
        play: TilePlayButton(
          color: lime,
          onPressed: playlist.trackCount > 0 ? onPlay : null,
          tooltip: context.tr('Play'),
        ),
      ),
    );
  }
}

Widget _line(String text, double size, FontWeight weight, Color color) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: TextStyle(fontSize: size, fontWeight: weight, color: color),
);

/// The inside of a desktop tile: a 150 px cover, the caption lines, and a row with a badge and the play button.
class _DesktopTile extends StatelessWidget {
  const _DesktopTile({required this.cover, required this.lines, required this.badge, required this.play});

  static const double coverHeight = 150;

  final Widget cover;
  final List<Widget> lines;
  final Widget badge;
  final Widget play;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(height: coverHeight, child: cover),
      const SizedBox(height: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[if (i > 0) const SizedBox(height: 2), lines[i]],
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Flexible(
            child: Align(alignment: Alignment.centerLeft, child: badge),
          ),
          const SizedBox(width: 8),
          play,
        ],
      ),
    ],
  );
}

/// A phone tile: a square cover (or round picture) and two lines below it.
class _PhoneTile extends StatelessWidget {
  const _PhoneTile({
    required this.onTap,
    required this.cover,
    required this.title,
    required this.subtitle,
    this.centered = false,
  });

  final VoidCallback onTap;
  final Widget cover;
  final String title;
  final String subtitle;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final align = centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: align,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(aspectRatio: 1, child: cover),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: colors.textMain),
                ),
              ),
              const SizedBox(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which kind of tile a [TileGridSliver] holds; it decides the desktop tile's height.
enum TileKind {
  /// Albums: three lines of caption.
  album,

  /// Artists and playlists: two lines.
  twoLines,
}

/// Tiles as a sliver. On a wide screen they are fixed-size cards (210 px wide, 18 px apart, as many per row as fit,
/// left-aligned); on a phone they fill the width in two or three columns.
class TileGridSliver extends StatelessWidget {
  const TileGridSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.kind = TileKind.album,
    this.horizontalPadding,
  });

  static const double _tileWidth = 210;
  static const double _gap = 18;

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final TileKind kind;
  final double? horizontalPadding;

  /// The height of one line of text at [size] in the font the app uses, at the user's font size.
  static double _lineHeight(BuildContext context, double size, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Ág',
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: size, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final title = _lineHeight(context, 14, FontWeight.w700);
    final second = _lineHeight(context, 12, FontWeight.w400);
    final third = _lineHeight(context, 11, FontWeight.w400);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final phone = PhoneChrome.isPhone(context);
        final padding = horizontalPadding ?? (phone ? 8.0 : 28.0);
        final available = constraints.crossAxisExtent - 2 * padding;
        final SliverGridDelegate delegate;
        if (phone) {
          final columns = available >= 420 ? 3 : 2;
          final tileWidth = (available - 4 * (columns - 1)) / columns;
          // Square cover plus two caption lines and the tile's padding.
          final caption = title + second + 8 + 1 + 8 + 1;
          delegate = SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: tileWidth + caption,
            crossAxisSpacing: 4,
            mainAxisSpacing: 12,
          );
        } else {
          // The caption at the user's font size; at the default size the tiles come out 290 and 270 px tall.
          final lines = kind == TileKind.album ? title + second + third + 4 : title + second + 2;
          final height = 16 + _DesktopTile.coverHeight + 10 + lines + 8 + 32 + 16 + 2 + 1;
          delegate = _FixedTileDelegate(width: _tileWidth, height: height, gap: _gap);
        }
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(padding, phone ? 4 : 6, padding, 4),
          sliver: SliverGrid(
            gridDelegate: delegate,
            delegate: SliverChildBuilderDelegate(
              (context, index) => _TileStyle(phone: phone, child: itemBuilder(context, index)),
              childCount: itemCount,
            ),
          ),
        );
      },
    );
  }
}

/// Fixed-size tiles in rows, left-aligned, like a wrap panel.
class _FixedTileDelegate extends SliverGridDelegate {
  const _FixedTileDelegate({required this.width, required this.height, required this.gap});

  final double width;
  final double height;
  final double gap;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final columns = ((constraints.crossAxisExtent + gap) / (width + gap)).floor().clamp(1, 1000);
    return SliverGridRegularTileLayout(
      crossAxisCount: columns,
      mainAxisStride: height + gap,
      crossAxisStride: width + gap,
      childMainAxisExtent: height,
      childCrossAxisExtent: width,
      reverseCrossAxis: false,
    );
  }

  @override
  bool shouldRelayout(_FixedTileDelegate oldDelegate) =>
      width != oldDelegate.width || height != oldDelegate.height || gap != oldDelegate.gap;
}
