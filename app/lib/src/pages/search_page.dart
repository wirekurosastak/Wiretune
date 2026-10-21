// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/search_view_model.dart';
import '../widgets/badges.dart';
import '../widgets/cards.dart';
import '../widgets/cover_image.dart';
import '../widgets/page_parts.dart';
import '../widgets/track_list.dart';

/// The results of the search: the best match beside the matching tracks, then the artists and the albums.
class SearchResults extends StatelessWidget {
  const SearchResults({super.key});

  /// The content width from which the best match and the tracks sit side by side.
  static const double _sideBySideWidth = 900;

  @override
  Widget build(BuildContext context) {
    final search = context.vm.search;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        if (!search.isSearchActive) {
          return EmptyState(icon: Icons.search, title: context.tr('Search'), hint: context.tr('SearchSubtitle'));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            final sideBySide = constraints.maxWidth >= _sideBySideWidth;
            final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 30);
            final best = search.bestMatch;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(pad.left, narrow ? 12 : 24, pad.right, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${context.tr('SearchResultsFor')} '),
                              TextSpan(
                                text: context.trf('QuotedText', [search.query]),
                                style: TextStyle(color: colors.accent),
                              ),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 30,
                            letterSpacing: -0.8,
                            fontWeight: FontWeight.w800,
                            color: colors.textMain,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(context.tr('SearchSubtitle'), style: TextStyle(fontSize: 13, color: colors.textMuted)),
                      ],
                    ),
                  ),
                ),
                if (!search.hasResults)
                  SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: GlassCard(
                          padding: const EdgeInsets.all(40),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.search_off_rounded, size: 56, color: colors.textMuted),
                              const SizedBox(height: 14),
                              Text(
                                context.tr('NoResultsTitle'),
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: colors.textMain),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                context.tr('NoResultsHint'),
                                style: TextStyle(fontSize: 13, color: colors.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (best != null && sideBySide)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(pad.left, 0, pad.right, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 320,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SectionLabel(context.tr('BestMatch'), padding: const EdgeInsets.only(bottom: 14)),
                                _BestMatchCard(match: best),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          if (search.hasTracks)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SectionLabel(context.tr('LabelTracks'), padding: const EdgeInsets.only(bottom: 14)),
                                  // The table is capped at 380 px; it scrolls inside.
                                  SizedBox(
                                    height:
                                        (TrackSliver.tableHeaderHeight +
                                                6 +
                                                TrackSliver.tableRowHeight * search.matchingTracks.length +
                                                2)
                                            .clamp(0, 380),
                                    child: CustomScrollView(
                                      slivers: [
                                        TrackSliver(
                                          tracks: search.matchingTracks,
                                          kind: TrackTableKind.search,
                                          horizontalPadding: 0,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
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
                          _BestMatchCard(match: best),
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
                  TrackSliver(tracks: search.matchingTracks, kind: TrackTableKind.search),
                ],
                if (search.hasArtists) ...[
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
                if (search.hasAlbums) ...[
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
                const PageEndSpace(),
              ],
            );
          },
        );
      },
    );
  }
}

/// The best match: a 110 px cover, its type, title and details, and a play button; the card opens it.
class _BestMatchCard extends StatelessWidget {
  const _BestMatchCard({required this.match});

  final BestMatch match;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final palette = colors.palette;
    final typeColor = switch (match.kind) {
      BestMatchKind.artist => palette.coral,
      BestMatchKind.album => palette.purple,
      BestMatchKind.track => palette.cyan,
    };
    return SizedBox(
      width: 320,
      child: _MetricCard(
        accent: typeColor,
        padding: 20,
        onTap: match.open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              path: match.coverPath,
              size: 116,
              radius: Radii.card,
              circle: match.kind == BestMatchKind.artist,
              placeholderColor: typeColor,
              placeholderIcon: switch (match.kind) {
                BestMatchKind.artist => Icons.person,
                BestMatchKind.album => Icons.album,
                BestMatchKind.track => Icons.music_note,
              },
            ),
            const SizedBox(height: 14),
            TagBadge(match.typeLabel, color: typeColor),
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
            TilePlayButton(color: typeColor, onPressed: match.play, tracks: match.tracks, size: 48),
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
          borderRadius: BorderRadius.circular(Radii.card + 2),
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
            borderRadius: BorderRadius.circular(Radii.card + 2),
            onTap: widget.onTap,
            child: Padding(padding: EdgeInsets.all(widget.padding), child: widget.child),
          ),
        ),
      ),
    );
  }
}
