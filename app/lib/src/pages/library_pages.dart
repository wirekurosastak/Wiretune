// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/library_view_models.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cards.dart';
import '../widgets/cover_image.dart';
import '../widgets/downloads.dart';
import '../widgets/links.dart';
import '../widgets/page_parts.dart';
import '../widgets/track_list.dart';

/// What an empty library says, with the two ways to fill it: a server, or a folder of this computer.
class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return EmptyState(
      icon: Icons.library_music_outlined,
      title: context.tr('EmptyLibraryTitle'),
      hint: context.tr(vm.capabilities.supportsLocalFolder ? 'EmptyLibraryHint' : 'EmptyLibraryHintServer'),
      actions: [
        PressShrink(
          child: FilledButton.icon(
            onPressed: vm.showLoginScreen,
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: Text(context.tr('ConnectToServer')),
          ),
        ),
        if (vm.capabilities.supportsLocalFolder)
          OutlinedButton.icon(
            onPressed: () => vm.navigateTo(AppSection.settings),
            icon: Icon(Icons.folder_open_outlined, size: 18, color: colors.accent),
            label: Text(context.tr('LocalFolder')),
          ),
      ],
    );
  }
}

class TracksPage extends StatelessWidget {
  const TracksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tracks = context.vm.tracks;
    return ListenableBuilder(
      listenable: tracks,
      builder: (context, _) {
        if (!tracks.hasTracks) return const EmptyLibrary();
        return PinnedTitleBar(
          title: context.tr('NavTracks'),
          child: CustomScrollView(
            key: const PageStorageKey('tracks'),
            slivers: [
              SliverToBoxAdapter(
                child: PageHeader(
                  title: context.tr('NavTracks'),
                  subtitle: '${context.trf('TrackCount', [tracks.totalTracksCount])}  •  ${tracks.totalTracksDuration}',
                  actions: [
                    if (PhoneChrome.isPhone(context)) TrackSortButtons(tracks), // a wide table sorts by its headers
                    PlayShuffleButtons(tracks: tracks.displayedTracks, onPlay: tracks.playAll),
                  ],
                ),
              ),
              TrackSliver(tracks: tracks.displayedTracks, sorting: tracks),
              const PageEndSpace(),
            ],
          ),
        );
      },
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final favorites = context.vm.favorites;
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) {
        if (favorites.isEmpty) {
          return EmptyState(
            icon: Icons.favorite_border,
            title: context.tr('EmptyFavoritesTitle'),
            hint: context.tr('EmptyFavoritesHint'),
          );
        }
        return PinnedTitleBar(
          title: context.tr('NavFavorites'),
          child: CustomScrollView(
            key: const PageStorageKey('favorites'),
            slivers: [
              SliverToBoxAdapter(
                child: PageHeader(
                  title: context.tr('NavFavorites'),
                  subtitle:
                      '${context.trf('TrackCount', [favorites.favoriteTracks.length])}  •  ${favorites.totalFavoritesDuration}',
                  actions: [
                    if (PhoneChrome.isPhone(context)) TrackSortButtons(favorites), // a wide table sorts by its headers
                    PlayShuffleButtons(
                      tracks: favorites.favoriteTracks,
                      onPlay: favorites.playAll,
                      download: DownloadListButton.forTracks(
                        favorites.favoriteTracks,
                        isDownloaded: () => context.vm.downloads.areFavoritesDownloaded,
                        onPressed: context.vm.downloads.toggleFavorites,
                      ),
                    ),
                  ],
                ),
              ),
              TrackSliver(tracks: favorites.favoriteTracks, sorting: favorites),
              const PageEndSpace(),
            ],
          ),
        );
      },
    );
  }
}

/// The button that leads back from a detail page: a bordered button with the section's arrow and [text], where it leads
/// (on a phone the top bar has the arrow).
class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.text, required this.onPressed});

  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (PhoneChrome.isPhone(context)) {
      // The top bar's arrow stands here, as in TIDAL.
      if (PinnedTitleBar.hasBar(context)) return const SizedBox(height: PinnedTitleBar.height);
      // Without one, the arrow alone where the bar's would be; where it leads is its tooltip.
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: SizedBox(
          height: PinnedTitleBar.height,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                tooltip: text,
                onPressed: onPressed,
                icon: Icon(Icons.arrow_back_rounded, size: 24, color: colors.textMain),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Pressable(
          onPressed: onPressed,
          builder: (context, lit) => AnimatedScale(
            scale: lit ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_back_rounded,
                    size: 20,
                    color: colors.textMain,
                    shadows: lit ? [BoxShadow(color: colors.textMain.withValues(alpha: 0.6), blurRadius: 10)] : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.textMain,
                      letterSpacing: -0.2,
                      shadows: lit ? [BoxShadow(color: colors.textMain.withValues(alpha: 0.6), blurRadius: 10)] : null,
                    ),
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

/// The header of a detail page: the [back] button, then the large artwork (with its [artworkBadge]) beside the labels,
/// the title, a line of details and the buttons (on a phone held upright the artwork sits above, centred, and the
/// labels are left out).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.artwork,
    required this.tags,
    required this.title,
    this.artworkBadge,
    this.roundArtwork = false,
    this.back,
    this.details = const [],
    this.actions = const [],
    this.titleWidget,
  });

  final Widget artwork;

  /// Shown on the artwork's corner, as on the tiles: an album's or a playlist's quality tag.
  final Widget? artworkBadge;

  /// The artwork is round (an artist's picture): so is its shadow and glow.
  final bool roundArtwork;
  final Widget? back;

  /// The labels above the title on a wide screen ("ALBUM", "PLAYLIST").
  final List<Widget> tags;
  final String title;

  /// Replaces the title text (a playlist's name, which can be clicked to rename it).
  final Widget? titleWidget;
  final List<Widget> details;
  final List<Widget> actions;

  /// Below this width the artwork sits above the title; from it on (a phone held sideways, a narrow window) beside it,
  /// where the height it saves keeps the tracks in view.
  static const double sideBySideWidth = 600;

  /// Whether the page is narrower than [sideBySideWidth]: the header, and the page around it, are the upright phone's.
  static bool isNarrow(BuildContext context) => MediaQuery.sizeOf(context).width < sideBySideWidth;

  /// The wide header's title style; a playlist's editable title uses it too.
  static TextStyle titleStyle(BuildContext context) => TextStyle(
    fontSize: 46,
    height: 1.05,
    letterSpacing: -1.6,
    fontWeight: FontWeight.w900,
    color: context.colors.textMain,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final narrow = isNarrow(context);
    final dot = Text('•', style: TextStyle(color: colors.textMuted));
    final shadow = [
      BoxShadow(color: colors.palette.shadow, blurRadius: 40, spreadRadius: -8, offset: const Offset(0, 20)),
      BoxShadow(color: colors.accent.withValues(alpha: 0.18), blurRadius: 60, spreadRadius: -10),
    ];
    final frame = roundArtwork
        ? BoxDecoration(shape: BoxShape.circle, boxShadow: shadow)
        : BoxDecoration(borderRadius: BorderRadius.circular(Radii.card), boxShadow: shadow);
    final badge = artworkBadge;
    final framed = badge == null
        ? artwork
        : Stack(
            fit: StackFit.expand,
            children: [
              artwork,
              Positioned(left: 10, bottom: 10, child: badge),
            ],
          );
    final detailRow = details.isEmpty
        ? null
        : Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: narrow ? WrapAlignment.center : WrapAlignment.start,
            children: [
              for (var i = 0; i < details.length; i++) ...[if (i > 0) dot, details[i]],
            ],
          );
    if (narrow) {
      // The phone's top bar takes the name over once it has reached it: one of a line shrinks into the bar's title,
      // a longer one (or a playlist's, which renames it) fades over to it.
      final titleStyle = TextStyle(
        fontSize: 24,
        letterSpacing: -0.6,
        fontWeight: FontWeight.w800,
        color: colors.textMain,
      );
      final narrowTitle = titleWidget != null
          ? PinnedTitleBar.pageTitle(context, titleWidget!)
          : LayoutBuilder(
              builder: (context, constraints) {
                // Measured in the font it is drawn in (the app's, which a Text takes from around it).
                final painter = TextPainter(
                  text: TextSpan(text: title, style: DefaultTextStyle.of(context).style.merge(titleStyle)),
                  maxLines: 1,
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout(maxWidth: constraints.maxWidth);
                final oneLine = !painter.didExceedMaxLines;
                painter.dispose();
                return PinnedTitleBar.pageTitle(
                  context,
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  shrinkStyle: oneLine ? titleStyle : null,
                );
              },
            );
      // The phone's header: the 230 px artwork with a glow, the title and the details centred, and a line of buttons
      // as tall as Play (see PlayShuffleButtons), Play over the ⋮ of the rows below.
      return SafeArea(
        bottom: false,
        child: Column(
          children: [
            ?back,
            Padding(
              padding: EdgeInsets.fromLTRB(16, back == null ? 12 : 0, 16, 0),
              child: Column(
                children: [
                  Container(width: 230, height: 230, decoration: frame, child: framed),
                  const SizedBox(height: 20),
                  if (actions.isEmpty) PinnedTitleBar.anchor(context, narrowTitle) else narrowTitle,
                  if (detailRow != null) ...[const SizedBox(height: 6), detailRow],
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, PhoneChrome.playEndPadding, 0),
                child: PinnedTitleBar.anchor(
                  context,
                  SizedBox(
                    height: PhoneChrome.playSize,
                    child: Row(children: [for (final action in actions) Expanded(child: action)]),
                  ),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      );
    }
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: tags),
        const SizedBox(height: 12),
        PinnedTitleBar.pageTitle(
          context,
          titleWidget ?? Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle(context)),
        ),
        if (detailRow != null) ...[const SizedBox(height: 12), detailRow],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 22),
          PinnedTitleBar.anchor(context, Wrap(spacing: 12, runSpacing: 8, children: actions)),
        ],
      ],
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?back,
        Padding(
          padding: EdgeInsets.fromLTRB(30, back == null ? 28 : 6, 30, 28),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(width: 210, height: 210, decoration: frame, child: framed),
              const SizedBox(width: 30),
              Expanded(child: text),
            ],
          ),
        ),
      ],
    );
    // The phone's pages reach under the status bar (and, held sideways, a camera's cutout); the wide layout's page
    // never does.
    return PhoneChrome.isPhone(context) ? SafeArea(bottom: false, child: header) : header;
  }
}

/// One of the details under a detail page's title: a count, a release year, a length.
class DetailText extends StatelessWidget {
  const DetailText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: context.colors.textMuted),
  );
}

/// The sort buttons of a list page ("Sort by: ABC ↑ | Released") as one segmented pill; the active segment is filled with
/// the accent.
class SortButtons extends StatelessWidget {
  const SortButtons({super.key, required this.buttons});

  final List<(String label, bool selected, VoidCallback onTap)> buttons;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (PhoneChrome.isPhone(context)) {
      // The active field with its direction, as on every other sort control.
      final active = buttons.firstWhere((b) => b.$2, orElse: () => buttons.first);
      return SizedBox(
        width: double.infinity,
        height: PhoneChrome.controlHeight,
        // The label is the order alone ("ABC ↑"): the tooltip, and a screen reader, say what the button is.
        child: Tooltip(
          message: context.tr('TipSortBy'),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              backgroundColor: colors.surface1,
              side: BorderSide(color: colors.glassBorder),
              shape: const StadiumBorder(),
            ),
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                backgroundColor: colors.palette.modal,
                shape: RoundedRectangleBorder(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.panel)),
                  side: BorderSide(color: colors.palette.glassBorder),
                ),
                // As tall as its choices (a sheet keeps to 9/16 of the screen otherwise, which cut the last ones off),
                // and scrolling when even the screen is too short for them.
                isScrollControlled: true,
                useSafeArea: true,
                builder: (ctx) => SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: colors.textMuted.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                          child: Text(
                            context.tr('SortBy'),
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.textMain),
                          ),
                        ),
                        for (final (label, selected, onTap) in buttons)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                            title: Text(
                              label,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected ? colors.accent : colors.textMain,
                              ),
                            ),
                            trailing: selected ? Icon(Icons.check_rounded, color: colors.accent) : null,
                            onTap: () {
                              Navigator.pop(ctx);
                              onTap();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    active.$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.accent),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          context.tr('SortBy'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textMuted),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: colors.surface1,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: colors.glassBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (label, selected, onTap) in buttons)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: selected ? colors.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.pill),
                        boxShadow: selected ? colors.accentGlow(0.5) : const [],
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: onTap,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            child: Text(
                              label,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: selected ? colors.onAccent : colors.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sort buttons of a list of tracks on a phone (a wide table sorts by its headers).
class TrackSortButtons extends StatelessWidget {
  const TrackSortButtons(this.sorting, {super.key});

  final TrackSorting sorting;

  @override
  Widget build(BuildContext context) {
    context.tr('SortBy'); // the labels follow the language
    return SortButtons(
      buttons: [
        for (final field in TrackSortField.values)
          (sorting.sortLabel(field), sorting.sortField == field, () => sorting.setSortField(field)),
      ],
    );
  }
}

/// The genre filter of a list page: a pill naming the chosen genre (or "All genres"), opening a menu of the library's
/// genres.
class _GenreFilter extends StatelessWidget {
  const _GenreFilter({required this.genres, required this.selected, required this.onSelected});

  final List<String> genres;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = selected != null;
    final color = active ? colors.accent : colors.textMuted;
    return PopupMenuButton<String>(
      tooltip: context.tr('TipGenreFilter'),
      position: PopupMenuPosition.under,
      // The menu's "all" entry has the empty string as its value: a null would read as "closed without a choice".
      onSelected: (value) => onSelected(value.isEmpty ? null : value),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(value: '', checked: !active, child: Text(context.tr('AllGenres'))),
        const PopupMenuDivider(),
        for (final genre in genres)
          CheckedPopupMenuItem(value: genre, checked: equalsIgnoreCase(genre, selected), child: Text(genre)),
      ],
      child: Container(
        height: PhoneChrome.isPhone(context) ? PhoneChrome.controlHeight : 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? colors.accent.withValues(alpha: 0.16) : colors.surface1,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: active ? colors.accent.withValues(alpha: 0.6) : colors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_rounded, size: 16, color: color),
            const SizedBox(width: 6),
            // A long genre is cut short, also where the phone's header leaves the pill less than its 180 px.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  selected ?? context.tr('AllGenres'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? colors.accent : colors.textMain,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

// ── Albums ──────────────────────────────────────────────────────────────────────────────────────────

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final albums = context.vm.albums;
    return ListenableBuilder(
      listenable: albums,
      builder: (context, _) {
        final selected = albums.selectedAlbum;
        if (albums.isAlbumDetailOpen && selected != null) return AlbumDetail(album: selected);
        if (albums.displayedAlbums.isEmpty) {
          return const EmptyLibrary(); // nothing to list means nothing in the library
        }
        return PinnedTitleBar(
          title: context.tr('NavAlbums'),
          child: CustomScrollView(
            key: const PageStorageKey('albums'),
            slivers: [
              SliverToBoxAdapter(
                child: PageHeader(
                  title: context.tr('NavAlbums'),
                  subtitle: context.trf('AlbumCount', [albums.displayedAlbums.length]),
                  actions: [
                    SortButtons(
                      buttons: [
                        for (final field in AlbumSortField.values)
                          (albums.sortLabel(field), albums.sortField == field, () => albums.setSortField(field)),
                      ],
                    ),
                    if (albums.genres.isNotEmpty)
                      _GenreFilter(genres: albums.genres, selected: albums.genre, onSelected: albums.setGenre),
                  ],
                ),
              ),
              AlbumsSliver(albums: albums.displayedAlbums, onOpen: albums.openAlbum, onPlay: albums.playAlbum),
              const PageEndSpace(),
            ],
          ),
        );
      },
    );
  }
}

class AlbumDetail extends StatelessWidget {
  const AlbumDetail({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final albums = vm.albums;
    final colors = context.colors;
    final menu = ListMenu.album(album, onPlay: albums.playAlbum);
    return PinnedTitleBar(
      title: album.title,
      onBack: albums.closeAlbumDetail,
      menu: menu.topBarButton(),
      child: CustomScrollView(
        key: PageStorageKey('album-${album.id}'),
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              back: BackLink(text: albums.backText, onPressed: albums.closeAlbumDetail),
              artwork: CoverImage(
                path: album.coverArtPath,
                radius: Radii.card,
                decodeWidth: 640,
                placeholderIcon: Icons.album,
                placeholderColor: colors.palette.purple,
              ),
              artworkBadge: QualityTag(tier: album.quality.tier, spec: album.quality.spec, fontSize: 11),
              tags: [TagBadge(context.tr('ColAlbum'), color: colors.palette.purple)],
              title: album.title,
              details: [
                ArtistLinks(
                  album.artistNames,
                  onOpen: vm.openArtistByName,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: colors.palette.coral),
                ),
                if (album.releaseYear != null) DetailText('${album.releaseYear}'),
                DetailText(context.trf('TrackCount', [album.trackCount])),
                DetailText(album.formattedTotalDuration),
              ],
              actions: [
                PlayShuffleButtons(
                  tracks: album.tracks,
                  onPlay: () => albums.playAlbum(),
                  download: DownloadListButton.forTracks(
                    album.tracks,
                    isDownloaded: () => vm.downloads.isAlbumDownloaded(album),
                    onPressed: () => vm.downloads.toggleAlbum(album),
                  ),
                  addToPlaylist: menu.addToPlaylistButton(),
                  menu: menu.headerButton(),
                ),
              ],
            ),
          ),
          TrackSliver(tracks: album.tracks, kind: TrackTableKind.album),
          const PageEndSpace(),
        ],
      ),
    );
  }
}

// ── Artists ─────────────────────────────────────────────────────────────────────────────────────────

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final artists = context.vm.artists;
    return ListenableBuilder(
      listenable: artists,
      builder: (context, _) {
        final selected = artists.selectedArtist;
        if (artists.isArtistDetailOpen && selected != null) return ArtistDetail(artist: selected);
        if (artists.displayedArtists.isEmpty) {
          return const EmptyLibrary(); // nothing to list means nothing in the library
        }
        return PinnedTitleBar(
          title: context.tr('NavArtists'),
          child: CustomScrollView(
            key: const PageStorageKey('artists'),
            slivers: [
              SliverToBoxAdapter(
                child: PageHeader(
                  title: context.tr('NavArtists'),
                  subtitle: context.trf('ArtistCount', [artists.displayedArtists.length]),
                  actions: [
                    SortButtons(
                      buttons: [
                        for (final field in ArtistSortField.values)
                          (artists.sortLabel(field), artists.sortField == field, () => artists.setSortField(field)),
                      ],
                    ),
                    if (artists.genres.isNotEmpty)
                      _GenreFilter(genres: artists.genres, selected: artists.genre, onSelected: artists.setGenre),
                  ],
                ),
              ),
              ArtistsSliver(artists: artists.displayedArtists, onOpen: artists.openArtist, onPlay: artists.playArtist),
              const PageEndSpace(),
            ],
          ),
        );
      },
    );
  }
}

class ArtistDetail extends StatelessWidget {
  const ArtistDetail({super.key, required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final artists = vm.artists;
    final albums = artist.albums; // the newest first, as the library orders them
    final colors = context.colors;
    final narrow = DetailHeader.isNarrow(context);
    final albumTracks = [for (final album in albums) ...album.tracks];
    final menu = ListMenu.artist(artist, onPlay: artists.playArtist);
    return PinnedTitleBar(
      title: artist.name,
      onBack: artists.closeArtistDetail,
      menu: menu.topBarButton(),
      child: CustomScrollView(
        key: PageStorageKey('artist-${artist.id}'),
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              back: BackLink(text: artists.backText, onPressed: artists.closeArtistDetail),
              artwork: CoverImage(
                path: artist.picturePath,
                circle: true,
                placeholderIcon: Icons.person,
                placeholderColor: colors.palette.coral,
              ),
              roundArtwork: true,
              tags: [TagBadge(context.tr('ColArtist'), color: colors.palette.coral)],
              title: artist.name,
              details: [
                DetailText(context.trf('AlbumCount', [artist.albumCount])),
                DetailText(context.trf('TrackCount', [artist.trackCount])),
              ],
              actions: [
                PlayShuffleButtons(
                  tracks: artist.tracks,
                  onPlay: () => artists.playArtist(),
                  // The artist's albums, also the ones that arrive later.
                  download: DownloadListButton.forTracks(
                    albumTracks,
                    isDownloaded: () => vm.downloads.isArtistDownloaded(artist),
                    onPressed: () => vm.downloads.toggleArtist(artist),
                  ),
                  addToPlaylist: menu.addToPlaylistButton(),
                  menu: menu.headerButton(),
                ),
              ],
            ),
          ),
          if (albums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 26),
                child: SectionLabel(context.tr('LabelAlbums'), padding: const EdgeInsets.fromLTRB(4, 4, 4, 10)),
              ),
            ),
            AlbumsSliver(albums: albums, onOpen: vm.openAlbum, onPlay: vm.albums.playAlbum, withArtist: false),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 26),
              child: SectionLabel(context.tr('LabelAllTracks'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 8)),
            ),
          ),
          TrackSliver(tracks: artist.tracks, kind: TrackTableKind.artist),
          const PageEndSpace(),
        ],
      ),
    );
  }
}
