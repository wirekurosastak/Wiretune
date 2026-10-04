import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/library_view_models.dart';
import '../widgets/ambient.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/cover_image.dart';
import '../widgets/quality_tag.dart';
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
      hint: context.tr('EmptyLibraryHint'),
      actions: [
        FilledButton.icon(
          onPressed: vm.showLoginScreen,
          icon: const Icon(Icons.dns_outlined, size: 18),
          label: Text(context.tr('ConnectToServer')),
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
        return CustomScrollView(
          key: const PageStorageKey('tracks'),
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: context.tr('NavTracks'),
                subtitle: '${context.trf('TrackCount', [tracks.totalTracksCount])}  •  ${tracks.totalTracksDuration}',
                actions: [
                  PlayShuffleButtons(
                    playLabel: context.tr('Play'),
                    shuffleLabel: context.tr('Shuffle'),
                    onPlay: tracks.playAll,
                    onShuffle: tracks.shuffleAll,
                  ),
                ],
              ),
            ),
            TrackSliver(tracks: tracks.displayedTracks, onPlay: tracks.playTrack),
            const PageEndSpace(),
          ],
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
        return CustomScrollView(
          key: const PageStorageKey('favorites'),
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: context.tr('NavFavorites'),
                subtitle:
                    '${context.trf('TrackCount', [favorites.favoriteTracks.length])}  •  ${favorites.totalFavoritesDuration}',
                actions: [
                  PlayShuffleButtons(
                    playLabel: context.tr('Play'),
                    shuffleLabel: context.tr('Shuffle'),
                    onPlay: favorites.playAll,
                    onShuffle: favorites.shuffleAll,
                  ),
                ],
              ),
            ),
            TrackSliver(tracks: favorites.favoriteTracks, onPlay: favorites.playTrack, kind: TrackTableKind.favorites),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

/// The button that leads back from a detail page (a bordered button with the section's arrow).
class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.text, required this.onPressed});

  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (PhoneChrome.isPhone(context)) {
      // The phone's back button: a plain arrow and the text, 56 px high.
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_back_rounded, size: 24, color: colors.textMain),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.textMain),
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
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 26, narrow ? 12 : 22, narrow ? 16 : 26, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
            backgroundColor: colors.palette.panel,
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          onPressed: onPressed,
          icon: Icon(Icons.arrow_back_rounded, size: 18, color: context.colors.accent),
          label: Text(text, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

/// The header of a detail page, over a wash of its own artwork's colours that fades into the page: the [back] button,
/// then the large artwork beside the labels, the title, a line of details and the buttons (on a phone the artwork sits
/// above, centred).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.artwork,
    required this.tags,
    required this.title,
    this.artworkPath,
    this.back,
    this.details = const [],
    this.actions = const [],
    this.titleWidget,
  });

  final Widget artwork;

  /// The picture whose colours wash the header; none leaves a glow of the accent.
  final String? artworkPath;
  final Widget? back;
  final List<Widget> tags;
  final String title;

  /// Replaces the title text (a playlist's name, which can be clicked to rename it).
  final Widget? titleWidget;
  final List<Widget> details;
  final List<Widget> actions;

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
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final dot = Text('•', style: TextStyle(color: colors.textMuted));
    final shadow = [
      BoxShadow(color: colors.palette.shadow, blurRadius: 40, spreadRadius: -8, offset: const Offset(0, 20)),
      BoxShadow(color: colors.accent.withValues(alpha: 0.18), blurRadius: 60, spreadRadius: -10),
    ];
    // The wash: the artwork's colours (or a glow of the accent), fading out towards the bottom.
    final wash = Positioned.fill(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black, Colors.black54, Colors.transparent],
          stops: [0, 0.55, 1],
        ).createShader(rect),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.7, -0.8),
                  radius: 1.2,
                  colors: [colors.accent.withValues(alpha: 0.3), colors.accent.withValues(alpha: 0)],
                ),
              ),
            ),
            AmbientArtwork(path: artworkPath, opacity: colors.palette.isDark ? 0.6 : 0.45),
          ],
        ),
      ),
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
      // The phone's header: the 230 px artwork with a glow, the title, the details and the quality, all centred.
      return Stack(
        children: [
          wash,
          Column(
            children: [
              ?back,
              Padding(
                padding: EdgeInsets.fromLTRB(16, back == null ? 12 : 0, 16, 10),
                child: Column(
                  children: [
                    Container(
                      width: 230,
                      height: 230,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.card), boxShadow: shadow),
                      child: artwork,
                    ),
                    const SizedBox(height: 20),
                    titleWidget ??
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 24,
                            letterSpacing: -0.6,
                            fontWeight: FontWeight.w800,
                            color: colors.textMain,
                          ),
                        ),
                    if (detailRow != null) ...[const SizedBox(height: 6), detailRow],
                    if (tags.any((t) => t is! TagBadge)) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.center,
                        children: [...tags.where((t) => t is! TagBadge)],
                      ),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      for (final action in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: action),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: tags),
        const SizedBox(height: 12),
        titleWidget ?? Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle(context)),
        if (detailRow != null) ...[const SizedBox(height: 12), detailRow],
        if (actions.isNotEmpty) ...[const SizedBox(height: 22), Wrap(spacing: 12, runSpacing: 8, children: actions)],
      ],
    );
    return Stack(
      children: [
        wash,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?back,
            Padding(
              padding: EdgeInsets.fromLTRB(30, back == null ? 28 : 6, 30, 28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    width: 210,
                    height: 210,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.card), boxShadow: shadow),
                    child: artwork,
                  ),
                  const SizedBox(width: 30),
                  Expanded(child: text),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: context.colors.textMuted),
  );
}

/// The sort buttons of a list page ("Sort by: ABC ↑ | Year") as one segmented pill; the active segment is filled with
/// the accent.
class _SortButtons extends StatelessWidget {
  const _SortButtons({required this.buttons});

  final List<(String label, bool selected, VoidCallback onTap)> buttons;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        Text(
          context.tr('SortBy'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textMuted),
        ),
        const SizedBox(width: 10),
        // On a line too short for every segment (a phone with a large font) the pill shrinks rather than overflow.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: colors.surface1,
              borderRadius: BorderRadius.circular(999),
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
                      color: selected ? colors.accent : colors.accent.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: selected ? colors.accentGlow(0.5) : const [],
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: onTap,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 64, minHeight: 30),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                label,
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
                    ),
                  ),
              ],
            ),
          ),
        ),
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
      tooltip: context.tr('Genre'),
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
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? colors.accent.withValues(alpha: 0.16) : colors.surface1,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? colors.accent.withValues(alpha: 0.6) : colors.glassBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_rounded, size: 16, color: color),
            const SizedBox(width: 6),
            ConstrainedBox(
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
          return EmptyState(
            icon: Icons.album_outlined,
            title: context.tr('EmptyAlbumsTitle'),
            hint: context.tr('EmptyConnectHint'),
          );
        }
        return CustomScrollView(
          key: const PageStorageKey('albums'),
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: context.tr('NavAlbums'),
                actions: [
                  if (albums.genres.isNotEmpty)
                    _GenreFilter(genres: albums.genres, selected: albums.genre, onSelected: albums.setGenre),
                  _SortButtons(
                    buttons: [
                      (albums.sortTitleLabel, albums.isSortByTitle, () => albums.setSortField(AlbumSortField.title)),
                      (albums.sortYearLabel, albums.isSortByYear, () => albums.setSortField(AlbumSortField.year)),
                      (
                        albums.sortQualityLabel,
                        albums.isSortByQuality,
                        () => albums.setSortField(AlbumSortField.quality),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            TileGridSliver(
              itemCount: albums.displayedAlbums.length,
              itemBuilder: (context, index) {
                final album = albums.displayedAlbums[index];
                return AlbumCard(
                  album: album,
                  onOpen: () => albums.openAlbum(album),
                  onPlay: () => albums.playAlbum(album),
                );
              },
            ),
            const PageEndSpace(),
          ],
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
    return CustomScrollView(
      key: PageStorageKey('album-${album.id}'),
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            back: BackLink(text: albums.backText, onPressed: albums.closeAlbumDetail),
            artworkPath: album.coverArtPath,
            artwork: CoverImage(
              path: album.coverArtPath,
              radius: Radii.card,
              decodeWidth: 640,
              placeholderIcon: Icons.album,
              placeholderColor: colors.palette.purple,
            ),
            tags: [
              TagBadge(context.tr('ColAlbum'), color: colors.palette.purple),
              QualityTag(tier: album.tier, spec: album.tagSpec),
            ],
            title: album.title,
            details: [
              LinkText(
                album.artist,
                onTap: () => vm.openArtistByName(album.artist),
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: colors.palette.purple),
              ),
              if (album.year != null) _Detail('${album.year}'),
              _Detail(context.trf('TrackCount', [album.trackCount])),
              _Detail(album.formattedTotalDuration),
            ],
            actions: [
              PlayShuffleButtons(
                playLabel: context.tr('Play'),
                shuffleLabel: context.tr('Shuffle'),
                onPlay: () => albums.playAlbum(),
                onShuffle: () => albums.shuffleAlbum(),
              ),
            ],
          ),
        ),
        TrackSliver(tracks: album.tracks, onPlay: albums.playAlbumTrack, kind: TrackTableKind.album),
        const PageEndSpace(),
      ],
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
          return EmptyState(
            icon: Icons.person_outline,
            title: context.tr('EmptyArtistsTitle'),
            hint: context.tr('EmptyConnectHint'),
          );
        }
        return CustomScrollView(
          key: const PageStorageKey('artists'),
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                title: context.tr('NavArtists'),
                actions: [
                  if (artists.genres.isNotEmpty)
                    _GenreFilter(genres: artists.genres, selected: artists.genre, onSelected: artists.setGenre),
                  _SortButtons(buttons: [(artists.sortNameLabel, true, artists.toggleSort)]),
                ],
              ),
            ),
            TileGridSliver(
              kind: TileKind.twoLines,
              itemCount: artists.displayedArtists.length,
              itemBuilder: (context, index) {
                final artist = artists.displayedArtists[index];
                return ArtistCard(
                  artist: artist,
                  onOpen: () => artists.openArtist(artist),
                  onPlay: () => artists.playArtist(artist),
                );
              },
            ),
            const PageEndSpace(),
          ],
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
    final albums = artists.selectedArtistAlbums;
    final colors = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return CustomScrollView(
      key: PageStorageKey('artist-${artist.id}'),
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            back: BackLink(text: artists.backText, onPressed: artists.closeArtistDetail),
            artworkPath: artist.picturePath ?? albums.firstOrNull?.coverArtPath,
            artwork: CoverImage(
              path: artist.picturePath,
              circle: true,
              placeholderIcon: Icons.person,
              placeholderColor: colors.palette.coral,
            ),
            tags: [TagBadge(context.tr('ColArtist'), color: colors.palette.coral)],
            title: artist.name,
            details: [
              _Detail(context.trf('TrackCountInDatabase', [artist.trackCount])),
            ],
            actions: [
              PlayShuffleButtons(
                playLabel: context.tr('Play'),
                shuffleLabel: context.tr('Shuffle'),
                onPlay: () => artists.playArtist(),
                onShuffle: () => artists.shuffleArtist(),
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
          TileGridSliver(
            itemCount: albums.length,
            itemBuilder: (context, index) => AlbumCard(
              album: albums[index],
              onOpen: () => vm.openAlbum(albums[index]),
              onPlay: () => vm.albums.playAlbum(albums[index]),
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 26),
            child: SectionLabel(context.tr('LabelAllTracks'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 8)),
          ),
        ),
        TrackSliver(tracks: artists.selectedArtistTracks, onPlay: artists.playArtistTrack, kind: TrackTableKind.artist),
        const PageEndSpace(),
      ],
    );
  }
}
