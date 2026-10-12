// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import '../view_models/main_view_model.dart';
import 'common.dart';
import 'cover_image.dart';
import 'quality_tag.dart';

/// An album: cover (with its format on it), title, artist, track count and year, and a play button.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, required this.onOpen, required this.onPlay});

  final Album album;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

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
    final details = [
      context.trf('TrackCount', [album.trackCount]),
      if (album.year != null) '${album.year}',
    ].join('  •  ');
    return _DesktopTile(
      accent: purple,
      onTap: onOpen,
      onSecondaryTap: (position) => CollectionMenu.album(album, onPlay: onPlay).showAt(context, position),
      cover: cover,
      lines: [
        _line(album.title, 14, FontWeight.w700, colors.textMain),
        _line(album.artist, 12.5, FontWeight.w500, colors.textMuted),
        _line(details, 11, FontWeight.w500, colors.textMuted),
      ],
      badge: QualityTag(tier: album.tier, spec: album.tagSpec),
      play: TilePlayButton(color: purple, onPressed: onPlay),
    );
  }
}

/// An artist: round picture, name, track count and a play button.
class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist, required this.onOpen, required this.onPlay});

  final Artist artist;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

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
    return _DesktopTile(
      accent: coral,
      onTap: onOpen,
      onSecondaryTap: (position) => CollectionMenu.artist(artist, onPlay: onPlay).showAt(context, position),
      circle: true,
      cover: picture,
      lines: [
        _line(artist.name, 14, FontWeight.w700, colors.textMain, center: true),
        _line(artistCounts(context, artist), 12.5, FontWeight.w500, colors.textMuted, center: true),
      ],
      play: TilePlayButton(color: coral, onPressed: onPlay),
    );
  }
}

/// How many albums and tracks an artist has, as its tile and its row say it.
String artistCounts(BuildContext context, Artist artist) =>
    '${context.trf('AlbumCount', [artist.albumCount])}  •  ${context.trf('TrackCount', [artist.trackCount])}';

enum _CollectionAction { play, shuffle, playNext, addToQueue, download, hide }

/// The menu of an album or an artist, on its tile (a right click) and its phone row (the ⋮): what the header of its page
/// offers, in the same order (play, shuffle, download when a track of it can be, hide), and after play and shuffle the
/// queue's two.
class CollectionMenu {
  CollectionMenu._(
    this.tracks,
    this.name, {
    required this.downloadable,
    required this.onPlay,
    required this.isPinned,
    required this.onDownload,
    required this.hideKey,
    required this.onHide,
  });

  factory CollectionMenu.album(Album album, {required VoidCallback onPlay}) => CollectionMenu._(
    album.tracks,
    album.title,
    downloadable: album.tracks,
    onPlay: onPlay,
    isPinned: (vm) => vm.downloads.isAlbumPinned(album),
    onDownload: (vm) => vm.downloads.toggleAlbum(album),
    hideKey: 'HideAlbum',
    onHide: (vm) => vm.library.hideAlbum(album.id),
  );

  factory CollectionMenu.artist(Artist artist, {required VoidCallback onPlay}) => CollectionMenu._(
    artist.tracks,
    artist.name,
    // The download keeps the artist's albums, as the button on its page does.
    downloadable: [for (final album in artist.albums) ...album.tracks],
    onPlay: onPlay,
    isPinned: (vm) => vm.downloads.isArtistPinned(artist),
    onDownload: (vm) => vm.downloads.toggleArtist(artist),
    hideKey: 'HideArtist',
    onHide: (vm) => vm.library.hideArtist(artist.id),
  );

  /// What playing, shuffling and queueing start.
  final List<Track> tracks;
  final String name;
  final List<Track> downloadable;
  final VoidCallback onPlay;
  final bool Function(MainViewModel vm) isPinned;
  final void Function(MainViewModel vm) onDownload;
  final String hideKey;
  final void Function(MainViewModel vm) onHide;

  List<PopupMenuEntry<_CollectionAction>> _items(BuildContext context) {
    final vm = context.vm;
    final muted = context.colors.textMuted;
    PopupMenuItem<_CollectionAction> item(_CollectionAction action, IconData icon, String text) => PopupMenuItem(
      value: action,
      child: Row(
        children: [
          Icon(icon, size: 20, color: muted),
          const SizedBox(width: 14),
          Flexible(child: Text(text)),
        ],
      ),
    );
    final pinned = isPinned(vm);
    return [
      item(_CollectionAction.play, Icons.play_arrow_rounded, context.tr('Play')),
      item(_CollectionAction.shuffle, Icons.shuffle_rounded, context.tr('Shuffle')),
      item(_CollectionAction.playNext, Icons.queue_play_next_rounded, context.tr('PlayNext')),
      item(_CollectionAction.addToQueue, Icons.add_to_queue_rounded, context.tr('AddToQueue')),
      if (downloadable.any(vm.downloads.canDownload))
        item(
          _CollectionAction.download,
          pinned ? Icons.download_done_rounded : Icons.download_rounded,
          context.tr(pinned ? 'TipRemoveDownload' : 'TipDownload'),
        ),
      item(_CollectionAction.hide, Icons.visibility_off_outlined, context.tr(hideKey)),
    ];
  }

  void _run(BuildContext context, _CollectionAction? action) {
    if (action == null || !context.mounted) return;
    final vm = context.vm;
    switch (action) {
      case _CollectionAction.play:
        onPlay();
      case _CollectionAction.shuffle:
        vm.player.shuffleQueue(tracks);
      case _CollectionAction.playNext:
        vm.queue(tracks, next: true, name: name);
      case _CollectionAction.addToQueue:
        vm.queue(tracks, next: false, name: name);
      case _CollectionAction.download:
        onDownload(vm);
      case _CollectionAction.hide:
        onHide(vm);
    }
  }

  /// Opens the menu at [position] (a right click on a tile).
  Future<void> showAt(BuildContext context, Offset position) async {
    final action = await showMenu<_CollectionAction>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: _items(context),
    );
    if (context.mounted) _run(context, action);
  }

  /// The ⋮ button of a phone row.
  Widget button(BuildContext context) => PopupMenuButton<_CollectionAction>(
    icon: Icon(Icons.more_vert_rounded, size: 20, color: context.colors.textMuted),
    tooltip: context.tr('TipMore'),
    onSelected: (action) => _run(context, action),
    itemBuilder: _items,
  );
}

/// Albums as a sliver: on a phone a list of rows (the cover, the title, the artist and the year), on a wide screen a grid
/// of tiles.
class AlbumsSliver extends StatelessWidget {
  const AlbumsSliver({super.key, required this.albums, required this.onOpen, required this.onPlay});

  final List<Album> albums;
  final void Function(Album album) onOpen;
  final void Function(Album album) onPlay;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        itemCount: albums.length,
        itemBuilder: (context, index) =>
            AlbumCard(album: albums[index], onOpen: () => onOpen(albums[index]), onPlay: () => onPlay(albums[index])),
      );
    }
    final purple = context.colors.palette.purple;
    return _rows(albums.length, (index) {
      final album = albums[index];
      return _ListRow(
        onTap: () => onOpen(album),
        picture: CoverImage(
          path: album.coverArtPath,
          size: _ListRow.pictureSize,
          radius: Radii.small + 2,
          placeholderIcon: Icons.album,
          placeholderColor: purple,
        ),
        title: album.title,
        subtitle: [album.artist, if (album.year != null) '${album.year}'].join('  •  '),
        badge: QualityTag(
          tier: album.tier,
          spec: album.compactTagSpec,
          fontSize: 9.5,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        ),
        trailing: CollectionMenu.album(album, onPlay: () => onPlay(album)).button(context),
      );
    });
  }
}

/// Artists as a sliver: on a phone a list of rows (the round picture, the name, the albums and tracks), on a wide
/// screen a grid of tiles.
class ArtistsSliver extends StatelessWidget {
  const ArtistsSliver({super.key, required this.artists, required this.onOpen, required this.onPlay});

  final List<Artist> artists;
  final void Function(Artist artist) onOpen;
  final void Function(Artist artist) onPlay;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        kind: TileKind.twoLines,
        itemCount: artists.length,
        itemBuilder: (context, index) => ArtistCard(
          artist: artists[index],
          onOpen: () => onOpen(artists[index]),
          onPlay: () => onPlay(artists[index]),
        ),
      );
    }
    final coral = context.colors.palette.coral;
    return _rows(artists.length, (index) {
      final artist = artists[index];
      return _ListRow(
        onTap: () => onOpen(artist),
        picture: CoverImage(
          path: artist.picturePath,
          size: _ListRow.pictureSize,
          circle: true,
          placeholderIcon: Icons.person,
          placeholderColor: coral,
        ),
        title: artist.name,
        subtitle: artistCounts(context, artist),
        trailing: CollectionMenu.artist(artist, onPlay: () => onPlay(artist)).button(context),
      );
    });
  }
}

/// Playlists as a sliver: on a phone a list of rows (matching album cover size), on a wide screen a grid of tiles.
class PlaylistsSliver extends StatelessWidget {
  const PlaylistsSliver({
    super.key,
    required this.playlists,
    required this.tracksOf,
    required this.onOpen,
    required this.onPlay,
  });

  final List<Playlist> playlists;
  final List<Track> Function(Playlist playlist) tracksOf;
  final void Function(Playlist playlist) onOpen;
  final void Function(Playlist playlist) onPlay;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        kind: TileKind.twoLines,
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          return PlaylistCard(
            playlist: playlist,
            covers: playlistCovers(tracksOf(playlist)),
            onOpen: () => onOpen(playlist),
            onPlay: () => onPlay(playlist),
          );
        },
      );
    }
    return _rows(playlists.length, (index) {
      final playlist = playlists[index];
      final covers = playlistCovers(tracksOf(playlist));
      final badge = playlist.formatSpec.isEmpty
          ? null
          : QualityTag(
              tier: playlist.formatTier,
              spec: playlist.compactFormatSpec,
              fontSize: 9.5,
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            );
      return _ListRow(
        onTap: () => onOpen(playlist),
        picture: PlaylistCover(covers: covers, radius: Radii.small + 2),
        title: playlist.name,
        subtitle: context.trf('TrackCount', [playlist.trackCount]),
        badge: badge,
      );
    });
  }
}

/// A phone's list of [count] rows, all as tall as the first: that follows the user's font size, and the list still
/// knows where every row is without building it.
Widget _rows(int count, Widget Function(int index) row) => count == 0
    ? const SliverToBoxAdapter()
    : SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverPrototypeExtentList.builder(
          prototypeItem: row(0),
          itemCount: count,
          itemBuilder: (context, index) => row(index),
        ),
      );

/// A phone's list row, as large as the music apps' lists: the picture, the title and below it the [subtitle]; a tap
/// opens what it shows.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.onTap,
    required this.picture,
    required this.title,
    required this.subtitle,
    this.badge,
    this.trailing,
  });

  static const double pictureSize = 68;

  final VoidCallback onTap;
  final Widget picture;
  final String title;
  final String subtitle;
  final Widget? badge;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              SizedBox.square(
                dimension: pictureSize,
                child: badge == null
                    ? picture
                    : Stack(
                        children: [
                          Positioned.fill(child: picture),
                          Positioned(
                            left: 4,
                            right: 4,
                            bottom: 4,
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              heightFactor: 1,
                              child: FittedBox(fit: BoxFit.scaleDown, child: badge!),
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: colors.textMain,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
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

/// A playlist: its cover collage (with the format on it), name, track count and a play button.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    required this.covers,
    required this.onOpen,
    required this.onPlay,
  });

  final Playlist playlist;
  final List<String> covers;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final lime = colors.palette.lime;
    return _DesktopTile(
      accent: lime,
      onTap: onOpen,
      cover: PlaylistCover(covers: covers, radius: Radii.small + 2),
      lines: [
        _line(playlist.name, 14, FontWeight.w700, colors.textMain),
        _line(context.trf('TrackCount', [playlist.trackCount]), 12.5, FontWeight.w500, colors.textMuted),
      ],
      badge: playlist.formatSpec.isEmpty ? null : QualityTag(tier: playlist.formatTier, spec: playlist.formatSpec),
      play: TilePlayButton(color: lime, onPressed: playlist.trackCount > 0 ? onPlay : null),
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
    this.onSecondaryTap,
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
  final void Function(Offset position)? onSecondaryTap;
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
        clipBehavior: Clip.none,
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
          if (widget.badge != null)
            // Beside the play button, while it is there, the tag shrinks rather than slide under it.
            Positioned(
              left: 8,
              right: showPlay ? 8 + 44 + 8 : 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomLeft,
                heightFactor: 1,
                child: FittedBox(fit: BoxFit.scaleDown, child: widget.badge!),
              ),
            ),
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
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.card + 2),
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              onTap: widget.onTap,
              onSecondaryTapUp: widget.onSecondaryTap != null ? (d) => widget.onSecondaryTap!(d.globalPosition) : null,
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

/// Which kind of tile a [TileGridSliver] holds; it decides the tile's height.
enum TileKind {
  /// Albums: three lines of caption.
  album,

  /// Artists and playlists: two lines.
  twoLines,
}

/// Tiles as a sliver, for a wide screen (a phone lists rows): as many columns of at least 176 px as fit, stretched to
/// fill the row.
class TileGridSliver extends StatelessWidget {
  const TileGridSliver({super.key, required this.itemCount, required this.itemBuilder, this.kind = TileKind.album});

  static const double _minTileWidth = 176;
  static const double _gap = 14;

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final TileKind kind;

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
        const padding = 20.0;
        final available = constraints.crossAxisExtent - 2 * padding;
        final columns = ((available + _gap) / (_minTileWidth + _gap)).floor().clamp(1, 1000);
        final tileWidth = (available - _gap * (columns - 1)) / columns;
        // The square cover, then the caption at the user's font size.
        final lines = kind == TileKind.album ? title + second + third + 4 : title + second + 2;
        const inset = 2 * _DesktopTile.padding;
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(padding, 4, padding, 4),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: inset + (tileWidth - inset) + _DesktopTile.captionGap + lines + 2,
              crossAxisSpacing: _gap,
              mainAxisSpacing: _gap,
            ),
            delegate: SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
          ),
        );
      },
    );
  }
}
