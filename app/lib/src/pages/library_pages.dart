import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/library_view_models.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/cover_image.dart';
import '../widgets/quality_tag.dart';
import '../widgets/track_list.dart';

const _bottomSpace = SliverToBoxAdapter(child: SizedBox(height: 24));

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
            _bottomSpace,
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
            _bottomSpace,
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
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, narrow ? 12 : 24, narrow ? 16 : 28, 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14),
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

/// The header of a detail page: a glass card with the 120 px artwork beside the labels, the title, a line of details
/// and the buttons (on a phone the artwork sits above, centred).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.artwork,
    required this.tags,
    required this.title,
    this.details = const [],
    this.actions = const [],
    this.titleSize = 26,
    this.titleWidget,
  });

  final Widget artwork;
  final List<Widget> tags;
  final String title;

  /// Replaces the title text (a playlist's name, which can be clicked to rename it).
  final Widget? titleWidget;
  final List<Widget> details;
  final List<Widget> actions;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final dot = Text('•', style: TextStyle(color: colors.textMuted));
    final text = Column(
      crossAxisAlignment: narrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: tags),
        const SizedBox(height: 8),
        titleWidget ??
            Text(
              title,
              textAlign: narrow ? TextAlign.center : TextAlign.start,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w900, color: colors.textMain),
            ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: narrow ? WrapAlignment.center : WrapAlignment.start,
            children: [
              for (var i = 0; i < details.length; i++) ...[if (i > 0) dot, details[i]],
            ],
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
        ],
      ],
    );
    if (narrow) {
      // The phone's header: the 220 px artwork with a glow, the title, the details and the quality, all centred.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Column(
          children: [
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: colors.accent.withValues(alpha: 0.22), blurRadius: 50, spreadRadius: -4)],
              ),
              child: artwork,
            ),
            const SizedBox(height: 18),
            titleWidget ??
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: colors.textMain),
                ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < details.length; i++) ...[if (i > 0) dot, details[i]],
                ],
              ),
            ],
            if (tags.any((t) => t is! TagBadge)) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, alignment: WrapAlignment.center, children: [...tags.where((t) => t is! TagBadge)]),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final action in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: action),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
      child: GlassCard(
        hoverColor: colors.accent,
        child: Row(
          children: [
            SizedBox.square(dimension: 120, child: artwork),
            const SizedBox(width: 28),
            Expanded(child: text),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 13, color: context.colors.textMuted));
}

/// The sort buttons of a list page ("Sort by: ABC ↑ | Year"): the active one is filled with the accent.
class _SortButtons extends StatelessWidget {
  const _SortButtons({required this.buttons});

  final List<(String label, bool selected, VoidCallback onTap)> buttons;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        Text(context.tr('SortBy'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
        const SizedBox(width: 8),
        for (final (label, selected, onTap) in buttons)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: selected
                ? FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: style,
                    ),
                    onPressed: onTap,
                    child: Text(label),
                  )
                : OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(72, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: style,
                    ),
                    onPressed: onTap,
                    child: Text(label),
                  ),
          ),
      ],
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
                  _SortButtons(
                    buttons: [
                      (albums.sortTitleLabel, albums.isSortByTitle, () => albums.setSortField(AlbumSortField.title)),
                      (albums.sortYearLabel, albums.isSortByYear, () => albums.setSortField(AlbumSortField.year)),
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
            _bottomSpace,
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
          child: BackLink(text: albums.backText, onPressed: albums.closeAlbumDetail),
        ),
        SliverToBoxAdapter(
          child: DetailHeader(
            artwork: CoverImage(
              path: album.coverArtPath,
              radius: 8,
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
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: colors.palette.purple),
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
        _bottomSpace,
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
            _bottomSpace,
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
          child: BackLink(text: artists.backText, onPressed: artists.closeArtistDetail),
        ),
        SliverToBoxAdapter(
          child: DetailHeader(
            artwork: CoverImage(
              path: artist.picturePath,
              circle: true,
              placeholderIcon: Icons.person,
              placeholderColor: colors.palette.coral,
            ),
            tags: [TagBadge(context.tr('ColArtist'), color: colors.palette.coral)],
            title: artist.name,
            titleSize: 28,
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
              padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 28),
              child: SectionLabel(context.tr('LabelAlbums'), padding: const EdgeInsets.fromLTRB(4, 0, 4, 12)),
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
            padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 28),
            child: SectionLabel(context.tr('LabelAllTracks'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 12)),
          ),
        ),
        TrackSliver(tracks: artists.selectedArtistTracks, onPlay: artists.playArtistTrack, kind: TrackTableKind.artist),
        _bottomSpace,
      ],
    );
  }
}
