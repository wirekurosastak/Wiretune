import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../pages/login_page.dart';
import '../pages/now_playing_page.dart';
import '../pages/playlists_page.dart';
import '../pages/search_page.dart';
import '../pages/section_page.dart';
import '../widgets/cover_image.dart';
import '../widgets/common.dart';

/// The phone layout: the page (each draws its own header with the search and account buttons), the floating mini
/// player and the bottom navigation; search and the full-screen player slide over it.
class PhoneLayout extends StatelessWidget {
  const PhoneLayout({super.key});

  static const List<AppSection> tabs = [
    AppSection.artists,
    AppSection.albums,
    AppSection.tracks,
    AppSection.favorites,
    AppSection.playlists,
  ];

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return PhoneChrome(
      child: ListenableBuilder(
        listenable: vm,
        builder: (context, _) => Stack(
          children: [
            Scaffold(
              backgroundColor: colors.palette.background,
              body: Container(
                decoration: BoxDecoration(gradient: colors.windowGradient),
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      if (vm.isSearchOpen) const _SearchBar(),
                      if (vm.isServerOfflineBannerVisible) const _OfflineBanner(),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: vm.isSearchOpen
                              ? const SearchResults(key: ValueKey('search'))
                              : KeyedSubtree(key: ValueKey(vm.selectedSection), child: sectionPage(vm.selectedSection)),
                        ),
                      ),
                      const _MiniPlayer(),
                    ],
                  ),
                ),
              ),
              bottomNavigationBar: const _BottomNavigation(),
            ),
            const PlaylistDialogsLayer(),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !vm.isNowPlayingOpen,
                child: AnimatedSlide(
                  offset: vm.isNowPlayingOpen ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: vm.isNowPlayingOpen ? const NowPlayingPage() : const SizedBox.shrink(),
                ),
              ),
            ),
            if (vm.isLoginViewActive) const Positioned.fill(child: LoginPage()),
          ],
        ),
      ),
    );
  }
}

/// The five sections at the bottom; the active one takes the colour of its section (no pill), and its icon grows.
class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final palette = colors.palette;
    final items = [
      (AppSection.artists, Icons.person_outline, palette.coral, 'NavArtists'),
      (AppSection.albums, Icons.album, palette.purple, 'NavAlbums'),
      (AppSection.tracks, Icons.music_note, palette.cyan, 'NavSongs'),
      (AppSection.favorites, Icons.favorite, palette.coral, 'NavFavorites'),
      (AppSection.playlists, Icons.queue_music, palette.lime, 'NavPlaylistsShort'),
    ];
    return Container(
      decoration: BoxDecoration(
        // AMOLED black (white in the light theme), and it covers the space under the system's navigation bar.
        color: palette.isDark ? Colors.black : Colors.white,
        border: Border(top: BorderSide(color: colors.glassBorder)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: [
              for (final (section, icon, color, label) in items)
                Expanded(
                  child: _NavItem(
                    icon: icon,
                    label: context.tr(label),
                    color: color,
                    active: !vm.isSearchOpen && vm.selectedSection == section,
                    onTap: () {
                      vm.closeSearch();
                      vm.navigateTo(section);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.textMuted;
    return Semantics(
      selected: active,
      button: true,
      child: InkResponse(
        onTap: onTap,
        highlightShape: BoxShape.rectangle,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: active ? 1.12 : 1,
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutBack,
              child: Icon(icon, size: 26, color: active ? color : muted),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? color : muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  const _SearchBar();

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _controller = TextEditingController(text: context.vm.searchQuery);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: context.tr('Back'),
            onPressed: vm.closeSearch,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (text) => vm.searchQuery = text,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: context.tr('SearchPlaceholder'),
                isDense: true,
                filled: true,
                fillColor: colors.surface1,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: context.tr('TipClearSearch'),
                        onPressed: () {
                          _controller.clear();
                          vm.clearSearch();
                          setState(() {});
                        },
                        icon: const Icon(Icons.cancel_rounded, size: 18),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(color: colors.danger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: colors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              vm.serverBannerMessage,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textMain),
            ),
          ),
          TextButton(onPressed: vm.retryConnectServer, child: Text(context.tr('Reconnect'))),
          IconButton(
            tooltip: context.tr('TipDismissNotice'),
            onPressed: vm.dismissServerBanner,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The mini player: a floating card with the cover, title and artist, play/pause and next, and the progress under it.
/// A tap opens the full-screen player.
class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.currentTrack;
        if (track == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: Material(
            color: colors.palette.isDark ? Colors.black : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: colors.glassBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: vm.openNowPlaying,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                            child: Row(
                              children: [
                                Hero(
                                  tag: 'now-playing-cover',
                                  child: CoverImage(path: track.coverArtPath, size: 48, radius: 8),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        player.nowPlayingTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: colors.textMain,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        player.hasError ? player.errorMessage! : player.nowPlayingArtist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: player.hasError ? colors.danger : colors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          tooltip: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
                          onPressed: player.togglePlayPause,
                          icon: Icon(
                            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 30,
                            color: colors.textMain,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: SizedBox.square(
                          dimension: 44,
                          child: IconButton(
                            tooltip: context.tr('TipNext'),
                            onPressed: player.nextTrack,
                            icon: Icon(Icons.skip_next_rounded, size: 26, color: colors.textMain),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: ValueListenableBuilder(
                    valueListenable: player.position,
                    builder: (context, position, _) {
                      final total = player.duration.inMilliseconds;
                      final fraction = total <= 0 ? 0.0 : (position.inMilliseconds / total).clamp(0.0, 1.0);
                      return LinearProgressIndicator(
                        value: fraction,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                        backgroundColor: colors.palette.glassHighlight,
                        color: colors.accent,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
