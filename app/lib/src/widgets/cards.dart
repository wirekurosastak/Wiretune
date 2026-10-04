import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import 'cover_image.dart';
import 'quality_tag.dart';

/// Whether tiles are drawn as the desktop's hover tiles (a cover with a badge and a play button on it) or as the
/// phone's plain cover-and-caption tiles. [TileGridSliver] decides it from the width and passes it down.
class _TileStyle extends InheritedWidget {
  const _TileStyle({required this.phone, required super.child});

  final bool phone;

  static bool phoneOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TileStyle>()?.phone ?? PhoneChrome.isPhone(context);

  @override
  bool updateShouldNotify(_TileStyle oldWidget) => phone != oldWidget.phone;
}

/// An album: cover (with its format on it), title, artist, track count and year, and a play button.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, required this.onOpen, this.onPlay});

  final Album album;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final purple = colors.palette.purple;
    final cover = CoverImage(
      path: album.coverArtPath,
      radius: Radii.small + 2,
      placeholderIcon: Icons.album,
      placeholderColor: purple,
    );
    final badge = QualityTag(tier: album.tier, spec: album.tagSpec, compact: true);
    if (_TileStyle.phoneOf(context)) {
      return _PhoneTile(onTap: onOpen, cover: cover, badge: badge, title: album.title, subtitle: album.artist);
    }
    final details = [
      context.trf('TrackCount', [album.trackCount]),
      if (album.year != null) '${album.year}',
    ].join('  •  ');
    return _DesktopTile(
      accent: purple,
      onTap: onOpen,
      cover: cover,
      lines: [
        _line(album.title, 14, FontWeight.w700, colors.textMain),
        _line(album.artist, 12.5, FontWeight.w500, colors.textMuted),
        _line(details, 11, FontWeight.w500, colors.textMuted.withValues(alpha: 0.75)),
      ],
      badge: badge,
      play: TilePlayButton(color: purple, onPressed: onPlay, tooltip: context.tr('Play')),
    );
  }
}

/// An artist: round picture, name, track count and a play button.
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
    return _DesktopTile(
      accent: coral,
      onTap: onOpen,
      circle: true,
      cover: picture,
      lines: [
        _line(artist.name, 14, FontWeight.w700, colors.textMain, center: true),
        _line(context.trf('TrackCount', [artist.trackCount]), 12.5, FontWeight.w500, colors.textMuted, center: true),
      ],
      play: TilePlayButton(color: coral, onPressed: onPlay, tooltip: context.tr('Play')),
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

/// A playlist: its cover collage (with the format on it), name, track count and a play button.
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
    final cover = PlaylistCover(covers: covers, radius: Radii.small + 2);
    final badge = playlist.formatBadge.isEmpty
        ? null
        : QualityTag(tier: playlist.formatTier, spec: playlist.formatSpec, compact: true);
    if (_TileStyle.phoneOf(context)) {
      return _PhoneTile(
        onTap: onOpen,
        cover: cover,
        badge: badge,
        title: playlist.name,
        subtitle: context.trf('TrackCount', [playlist.trackCount]),
      );
    }
    return _DesktopTile(
      accent: lime,
      onTap: onOpen,
      cover: cover,
      lines: [
        _line(playlist.name, 14, FontWeight.w700, colors.textMain),
        _line(context.trf('TrackCount', [playlist.trackCount]), 12.5, FontWeight.w500, colors.textMuted),
      ],
      badge: badge,
      play: TilePlayButton(
        color: lime,
        onPressed: playlist.trackCount > 0 ? onPlay : null,
        tooltip: context.tr('Play'),
      ),
    );
  }
}

Widget _line(String text, double size, FontWeight weight, Color color, {bool center = false}) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  textAlign: center ? TextAlign.center : TextAlign.start,
  style: TextStyle(fontSize: size, fontWeight: weight, color: color, letterSpacing: size >= 14 ? -0.1 : 0),
);

/// A wide screen's tile: a square cover with a soft shadow and the caption lines under it. Under the mouse, or while
/// the remote's focus is on it or its play button, the tile lifts, its background lights up, the cover's shadow takes
/// the [accent] and the play button rises onto the cover. On a touch screen the play button is always there.
class _DesktopTile extends StatefulWidget {
  const _DesktopTile({
    required this.accent,
    required this.onTap,
    required this.cover,
    required this.lines,
    required this.play,
    this.badge,
    this.circle = false,
  });

  /// The space around the cover, inside the tile.
  static const double padding = 10;

  /// The space between the cover and the caption.
  static const double captionGap = 12;

  final Color accent;
  final VoidCallback onTap;
  final Widget cover;
  final List<Widget> lines;
  final Widget play;
  final Widget? badge;
  final bool circle;

  @override
  State<_DesktopTile> createState() => _DesktopTileState();
}

class _DesktopTileState extends State<_DesktopTile> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = _hover || _focus;
    final showPlay = active || AppPlatform.current.isMobile;
    const duration = Duration(milliseconds: 240);
    final shape = widget.circle
        ? const BoxDecoration(shape: BoxShape.circle)
        : BoxDecoration(borderRadius: BorderRadius.circular(Radii.small + 2));
    final cover = AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedContainer(
            duration: duration,
            decoration: shape.copyWith(
              boxShadow: [
                BoxShadow(
                  color: active ? widget.accent.withValues(alpha: 0.38) : colors.palette.shadow,
                  blurRadius: active ? 26 : 16,
                  spreadRadius: -6,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: widget.cover,
          ),
          if (widget.badge != null) Positioned(left: 8, top: 8, child: widget.badge!),
          Positioned(
            right: widget.circle ? 4 : 8,
            bottom: widget.circle ? 4 : 8,
            child: AnimatedSlide(
              offset: showPlay ? Offset.zero : const Offset(0, 0.35),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(opacity: showPlay ? 1 : 0, duration: duration, child: widget.play),
            ),
          ),
        ],
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focus = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, active ? -4 : 0, 0),
          decoration: BoxDecoration(
            color: active ? colors.surface1 : colors.surface1.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(Radii.card + 2),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.card + 2),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(_DesktopTile.padding),
                child: Column(
                  crossAxisAlignment: widget.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                  children: [
                    cover,
                    const SizedBox(height: _DesktopTile.captionGap),
                    for (var i = 0; i < widget.lines.length; i++) ...[
                      if (i > 0) const SizedBox(height: 2),
                      SizedBox(width: double.infinity, child: widget.lines[i]),
                    ],
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

/// A phone tile: a square cover (or round picture) with a soft shadow and the [badge] on it, and two lines below it.
class _PhoneTile extends StatelessWidget {
  const _PhoneTile({
    required this.onTap,
    required this.cover,
    required this.title,
    required this.subtitle,
    this.badge,
    this.centered = false,
  });

  final VoidCallback onTap;
  final Widget cover;
  final Widget? badge;
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
        borderRadius: BorderRadius.circular(Radii.card),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: align,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: centered ? BoxShape.circle : BoxShape.rectangle,
                        borderRadius: centered ? null : BorderRadius.circular(Radii.small + 2),
                        boxShadow: [
                          BoxShadow(
                            color: colors.palette.shadow,
                            blurRadius: 14,
                            spreadRadius: -6,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: badge == null
                          ? cover
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                cover,
                                Positioned(left: 6, top: 6, child: badge!),
                              ],
                            ),
                    ),
                  ),
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
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                    color: colors.textMain,
                  ),
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

/// Tiles as a sliver. On a wide screen as many columns of at least 176 px as fit, stretched to fill the row; on a
/// phone two or three columns.
class TileGridSliver extends StatelessWidget {
  const TileGridSliver({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.kind = TileKind.album,
    this.horizontalPadding,
  });

  static const double _minTileWidth = 176;
  static const double _gap = 14;

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
    final second = _lineHeight(context, 12.5, FontWeight.w500);
    final third = _lineHeight(context, 11, FontWeight.w500);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final phone = PhoneChrome.isPhone(context);
        final padding = horizontalPadding ?? (phone ? 8.0 : 20.0);
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
          final columns = ((available + _gap) / (_minTileWidth + _gap)).floor().clamp(1, 1000);
          final tileWidth = (available - _gap * (columns - 1)) / columns;
          // The square cover, then the caption at the user's font size.
          final lines = kind == TileKind.album ? title + second + third + 4 : title + second + 2;
          const inset = 2 * _DesktopTile.padding;
          delegate = SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: inset + (tileWidth - inset) + _DesktopTile.captionGap + lines + 2,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
          );
        }
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
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
