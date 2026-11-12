// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/search_view_model.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cards.dart';
import '../widgets/cover_flight.dart';
import '../widgets/cover_image.dart';
import '../widgets/page_parts.dart';
import '../widgets/track_list.dart';

/// The results of the search: the best match beside the matching tracks, then the artists, the albums and the playlists.
class SearchResults extends StatelessWidget {
  const SearchResults({super.key});

  /// The content width from which the best match and the tracks sit side by side.
  static const double _sideBySideWidth = 900;

  /// The tracks' height beside the best match: they scroll inside past it, unless what is under the card leaves them
  /// more.
  static const double _tracksHeight = 380;

  /// Between the best match's column and the tracks, as between tiles.
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    final search = context.vm.search;
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        if (!search.hasQuery) {
          final recent = search.recent;
          if (recent.isEmpty) return EmptyState(icon: Icons.search, title: context.tr('Search'));
          return _RecentSearches(recent: recent);
        }
        if (!search.hasResults && search.filter == null) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: context.tr('NoResultsTitle'),
            hint: context.tr('NoResultsHint'),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) => ValueListenableBuilder(
            // The tiles that go under the best match are as large as the grids'.
            valueListenable: context.vm.tileSize,
            builder: (context, _, _) => _results(context, search, constraints.maxWidth),
          ),
        );
      },
    );
  }

  Widget _results(BuildContext context, SearchViewModel search, double width) {
    final narrow = width < 600;
    final sideBySide = width >= _sideBySideWidth;
    final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 30);
    final best = search.bestMatch;
    const inset = TileGridSliver.tileInset;
    const column = _BestMatchCard.width + 2 * inset;
    final tracksHeight =
        TrackSliver.tableHeaderHeight + 6 + TrackSliver.tableRowHeight * search.matchingTracks.length + 2;
    // Under the best match, beside tracks too many for their usual height: the artists, and then the albums, while a row
    // of their tiles fits under the card. The tracks then go on down beside them.
    var artistsUnder = false;
    var albumsUnder = false;
    if (best != null && sideBySide && tracksHeight > _tracksHeight) {
      final tileWidth = TileGridSliver.layoutIn(context, width, TileKind.album).tileWidth;
      final fitting = TileRow.fitting(column, tileWidth);
      artistsUnder = search.hasArtists && search.matchingArtists.length <= fitting;
      albumsUnder = (artistsUnder || !search.hasArtists) && search.hasAlbums && search.matchingAlbums.length <= fitting;
    }
    TileRow tiles(TileKind kind, List<Widget> children) {
      final layout = TileGridSliver.layoutIn(context, width, kind);
      return TileRow(tileWidth: layout.tileWidth, extent: layout.extent, children: children);
    }

    // No title: the search field above shows what was searched for. The results start where a page's title would,
    // under the kinds they can be narrowed to.
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: narrow ? 8 : 24)),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: narrow ? 12 : 20),
            child: _Filters(search: search, padding: pad),
          ),
        ),
        if (!search.hasResults)
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: Text(context.tr('NoResultsTitle'), style: TextStyle(color: context.colors.textMuted)),
            ),
          ),
        if (best != null && sideBySide)
          SliverToBoxAdapter(
            child: Padding(
              // From the tiles' edge, so that those under the card line up as in the grids (their covers with the card).
              padding: EdgeInsets.fromLTRB(TileGridSliver.padding, 0, pad.right, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: column,
                        child: SectionLabel(
                          context.tr('BestMatch'),
                          padding: const EdgeInsets.fromLTRB(inset, 0, 0, 14),
                        ),
                      ),
                      const SizedBox(width: _gap),
                      if (search.hasTracks)
                        SectionLabel(context.tr('LabelTracks'), padding: const EdgeInsets.only(bottom: 14)),
                    ],
                  ),
                  _Beside(
                    leftWidth: column,
                    gap: _gap,
                    rightHeights: (math.min(tracksHeight, _tracksHeight), tracksHeight),
                    left: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: inset),
                          child: _BestMatchCard(match: best),
                        ),
                        if (artistsUnder) ...[
                          _label(context, 'LabelArtists', inset),
                          tiles(TileKind.twoLines, [
                            for (final artist in search.matchingArtists)
                              ArtistCard(
                                artist: artist,
                                onOpen: () => context.vm.openArtist(artist),
                                onPlay: () => context.vm.artists.playArtist(artist),
                              ),
                          ]),
                        ],
                        if (albumsUnder) ...[
                          _label(context, 'LabelAlbums', inset),
                          tiles(TileKind.album, [
                            for (final album in search.matchingAlbums)
                              AlbumCard(
                                album: album,
                                onOpen: () => context.vm.openAlbum(album),
                                onPlay: () => context.vm.albums.playAlbum(album),
                              ),
                          ]),
                        ],
                      ],
                    ),
                    // It scrolls inside, and fades where more of it goes on.
                    right: search.hasTracks
                        ? EdgeFade(
                            child: CustomScrollView(
                              slivers: [
                                TrackSliver(
                                  tracks: search.matchingTracks,
                                  kind: TrackTableKind.search,
                                  horizontalPadding: 0,
                                  playingFrom: () => '"${search.query}"',
                                ),
                              ],
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        if (best != null && !sideBySide)
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionLabel(context.tr('BestMatch'), padding: const EdgeInsets.only(bottom: 14)),
                  // A phone's is as wide as the rows under it.
                  _BestMatchCard(match: best, fill: narrow),
                ],
              ),
            ),
          ),
        if (search.hasTracks && (best == null || !sideBySide)) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: SectionLabel(context.tr('LabelTracks'), padding: const EdgeInsets.fromLTRB(0, 24, 0, 14)),
            ),
          ),
          TrackSliver(
            tracks: search.matchingTracks,
            kind: TrackTableKind.search,
            playingFrom: () => '"${search.query}"',
          ),
        ],
        if (search.hasArtists && !artistsUnder) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: SectionLabel(context.tr('LabelArtists'), padding: const EdgeInsets.fromLTRB(4, 28, 4, 12)),
            ),
          ),
          ArtistsSliver(
            artists: search.matchingArtists,
            onOpen: context.vm.openArtist,
            onPlay: context.vm.artists.playArtist,
          ),
        ],
        if (search.hasAlbums && !albumsUnder) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: SectionLabel(context.tr('LabelAlbums'), padding: const EdgeInsets.fromLTRB(4, 28, 4, 12)),
            ),
          ),
          AlbumsSliver(
            albums: search.matchingAlbums,
            onOpen: context.vm.openAlbum,
            onPlay: context.vm.albums.playAlbum,
          ),
        ],
        if (search.hasPlaylists) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: pad,
              child: SectionLabel(context.tr('LabelPlaylists'), padding: const EdgeInsets.fromLTRB(4, 28, 4, 12)),
            ),
          ),
          PlaylistsSliver(
            playlists: search.matchingPlaylists,
            tracksOf: context.vm.playlists.tracksOf,
            onOpen: context.vm.openPlaylist,
            onPlay: context.vm.playlists.playPlaylist,
          ),
        ],
        const PageEndSpace(),
      ],
    );
  }

  static Widget _label(BuildContext context, String key, double inset) =>
      SectionLabel(context.tr(key), padding: EdgeInsets.fromLTRB(inset + 4, 28, 4, 12));
}

/// The kinds the results narrow to, as pills like Settings' choices (the chosen one filled), sliding sideways where
/// they don't fit: all of them, or the artists, the albums, the tracks or the playlists alone.
class _Filters extends StatelessWidget {
  const _Filters({required this.search, required this.padding});

  final SearchViewModel search;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    const style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, 34)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    );
    Widget pill(SearchFilter? filter, String key) {
      final label = Text(context.tr(key));
      return search.filter == filter
          ? PressShrink(
              child: FilledButton(style: style, onPressed: () => search.setFilter(filter), child: label),
            )
          : OutlinedButton(style: style, onPressed: () => search.setFilter(filter), child: label);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        spacing: 8,
        children: [
          pill(null, 'SearchAll'),
          pill(SearchFilter.artists, 'NavArtists'),
          pill(SearchFilter.albums, 'NavAlbums'),
          pill(SearchFilter.tracks, 'NavTracks'),
          pill(SearchFilter.playlists, 'NavPlaylists'),
        ],
      ),
    );
  }
}

/// What was searched for lately on this device, in place of the results while nothing is typed: a tap searches it
/// again, × forgets it.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.recent});

  final List<String> recent;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return ListView(
      padding: EdgeInsets.fromLTRB(narrow ? 8 : 22, narrow ? 8 : 28, narrow ? 8 : 22, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SectionLabel(context.tr('RecentSearches'), padding: const EdgeInsets.fromLTRB(0, 4, 0, 6)),
        ),
        for (final query in recent)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 8),
            leading: Icon(Icons.history_rounded, color: colors.textMuted),
            title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              vm.openSearch();
              vm.searchQuery = query;
            },
            trailing: IconButton(
              tooltip: context.tr('Remove'),
              icon: Icon(Icons.close_rounded, size: 20, color: colors.textMuted),
              onPressed: () => vm.search.forget(query),
            ),
          ),
      ],
    );
  }
}

/// The best match: a 116 px cover, its type, title and details, a play button and its ⋮, on a card 320 px wide; the
/// card opens it.
class _BestMatchCard extends StatelessWidget {
  const _BestMatchCard({required this.match, this.fill = false});

  static const double width = 320;

  final BestMatch match;

  /// As wide as there is room for (a phone's), rather than [width].
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final picture = CoverImage(
      path: match.coverPath,
      size: 116,
      radius: Radii.card,
      circle: match.kind == BestMatchKind.artist,
      placeholderIcon: switch (match.kind) {
        BestMatchKind.artist => Icons.person,
        BestMatchKind.album => Icons.album,
        BestMatchKind.track => Icons.music_note,
      },
    );
    // An artist's or an album's picture flies into its page, as from the cards under it.
    final tag = switch (match.item) {
      final Artist artist => 'artist:${artist.id}',
      final Album album => 'album:${album.id}',
      _ => null,
    };
    if (tag == null) return _card(context, colors, picture);
    return CoverFlightSource(
      tag: tag,
      radius: match.kind == BestMatchKind.artist ? null : Radii.card,
      cover: picture,
      builder: (context, cover) => _card(context, colors, cover),
    );
  }

  Widget _card(BuildContext context, WiretuneColors colors, Widget picture) {
    return SizedBox(
      width: fill ? double.infinity : width,
      child: _MetricCard(
        accent: colors.accent,
        padding: 20,
        // An artist or an album opens, like the cards under it; a track plays.
        onTap: switch (match.item) {
          final Artist artist => () => context.vm.openArtist(artist),
          final Album album => () => context.vm.openAlbum(album),
          _ => match.play,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            picture,
            const SizedBox(height: 14),
            TagBadge(match.typeLabel, color: colors.accent),
            const SizedBox(height: 4),
            Text(
              match.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 24, letterSpacing: -0.6, fontWeight: FontWeight.w800, color: colors.textMain),
            ),
            const SizedBox(height: 4),
            Text(
              match.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              match.meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                TilePlayButton(color: colors.accent, onPressed: match.play, tracks: match.tracks, size: 48),
                const Spacer(),
                // The same menu as its row's or tile's.
                switch (match.item) {
                  final Artist artist => ListMenu.artist(artist, onPlay: match.play).button(context),
                  final Album album => ListMenu.album(album, onPlay: match.play).button(context),
                  final Track track => TrackMenu(
                    track: track,
                    kind: TrackTableKind.search,
                    width: 48,
                    iconSize: 20,
                    withFavorite: true,
                  ),
                  _ => const SizedBox.shrink(),
                },
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A framed glass card that rises a little, takes the [accent] edge and glows in it under the mouse.
class _MetricCard extends StatefulWidget {
  const _MetricCard({required this.child, required this.accent, required this.onTap, this.padding = 16});

  final Widget child;
  final Color accent;
  final VoidCallback onTap;
  final double padding;

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: _hover ? colors.surface2 : colors.surface1,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: _hover ? widget.accent.withValues(alpha: 0.7) : colors.glassBorder),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: widget.accent.withValues(alpha: 0.28),
                    blurRadius: 36,
                    spreadRadius: -10,
                    offset: const Offset(0, 16),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.card),
            onTap: widget.onTap,
            child: Padding(padding: EdgeInsets.all(widget.padding), child: widget.child),
          ),
        ),
      ),
    );
  }
}

enum _Side { left, right }

/// The best match's column and, beside it, the tracks: as tall as the column, so that they go on beside what it holds
/// under the card, between [rightHeights] (at least the lower one: their usual height, while there are that many).
class _Beside extends SlottedMultiChildRenderObjectWidget<_Side, RenderBox> {
  const _Beside({
    required this.left,
    this.right,
    required this.leftWidth,
    required this.gap,
    required this.rightHeights,
  });

  final Widget left;
  final Widget? right;
  final double leftWidth;
  final double gap;
  final (double, double) rightHeights;

  @override
  Iterable<_Side> get slots => _Side.values;

  @override
  Widget? childForSlot(_Side slot) => switch (slot) {
    _Side.left => left,
    _Side.right => right,
  };

  @override
  _RenderBeside createRenderObject(BuildContext context) => _RenderBeside(leftWidth, gap, rightHeights);

  @override
  void updateRenderObject(BuildContext context, _RenderBeside renderObject) => renderObject
    ..leftWidth = leftWidth
    ..gap = gap
    ..rightHeights = rightHeights;
}

class _RenderBeside extends RenderBox with SlottedContainerRenderObjectMixin<_Side, RenderBox> {
  _RenderBeside(this._leftWidth, this._gap, this._rightHeights);

  double _leftWidth;
  set leftWidth(double value) {
    if (value == _leftWidth) return;
    _leftWidth = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  (double, double) _rightHeights;
  set rightHeights((double, double) value) {
    if (value == _rightHeights) return;
    _rightHeights = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final left = childForSlot(_Side.left)!;
    left.layout(BoxConstraints.tightFor(width: _leftWidth), parentUsesSize: true);
    var height = left.size.height;
    final right = childForSlot(_Side.right);
    if (right != null) {
      final (low, high) = _rightHeights;
      final rightHeight = height.clamp(low, high);
      right.layout(
        BoxConstraints.tightFor(width: math.max(0, constraints.maxWidth - _leftWidth - _gap), height: rightHeight),
      );
      (right.parentData! as BoxParentData).offset = Offset(_leftWidth + _gap, 0);
      height = math.max(height, rightHeight);
    }
    size = constraints.constrain(Size(constraints.maxWidth, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in children) {
      context.paintChild(child, offset + (child.parentData! as BoxParentData).offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in children) {
      final hit = result.addWithPaintOffset(
        offset: (child.parentData! as BoxParentData).offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}
