// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

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
import '../widgets/ambient.dart';
import '../widgets/cover_image.dart';
import '../widgets/common.dart';
import '../widgets/devices.dart';
import '../widgets/player_controls.dart';

/// The phone layout: the page (each draws its own header with the search and account buttons) over the ambient
/// backdrop, and floating over its lower edge the unified pill with the mini player and bottom navigation;
/// search and the full-screen player slide over it.
class PhoneLayout extends StatelessWidget {
  const PhoneLayout({super.key});

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
              // The page reaches under the floating bars; the Scaffold tells it how much they cover.
              extendBody: true,
              body: Stack(
                children: [
                  const Positioned.fill(child: AmbientBackdrop(colour: 0.70)),
                  Column(
                    children: [
                      if (vm.isSearchOpen) const SafeArea(bottom: false, child: _SearchBar()),
                      if (vm.isServerOfflineBannerVisible) const SafeArea(bottom: false, child: _OfflineBanner()),
                      Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            layoutBuilder: (currentChild, previousChildren) => Stack(
                              fit: StackFit.expand,
                              children: [
                                ...previousChildren,
                                ?currentChild,
                              ],
                            ),
                            transitionBuilder: (child, animation) => FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween(begin: 0.985, end: 1.0).animate(animation),
                                child: child,
                              ),
                            ),
                            child: vm.isSearchOpen
                                ? const SearchResults(key: ValueKey('search'))
                                : KeyedSubtree(
                                    key: ValueKey(vm.selectedSection),
                                    child: sectionPage(vm.selectedSection),
                                  ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              bottomNavigationBar: const _BottomBars(),
            ),
            Positioned.fill(
              child: _NowPlayingOverlay(isOpen: vm.isNowPlayingOpen),
            ),
            // Over the full-screen player too: its menu adds the track to a playlist.
            const PlaylistDialogsLayer(),
            if (vm.isLoginViewActive) const Positioned.fill(child: LoginPage()),
          ],
        ),
      ),
    );
  }
}

/// The full-screen player sliding up from the bottom when opened, and back down when closed.
class _NowPlayingOverlay extends StatefulWidget {
  const _NowPlayingOverlay({required this.isOpen});

  final bool isOpen;

  @override
  State<_NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<_NowPlayingOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  ));

  @override
  void initState() {
    super.initState();
    if (widget.isOpen) _controller.value = 1;
  }

  @override
  void didUpdateWidget(_NowPlayingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen != oldWidget.isOpen) {
      if (widget.isOpen) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isDismissed && !widget.isOpen) return const SizedBox.shrink();
        return SlideTransition(
          position: _slide,
          child: IgnorePointer(
            ignoring: !widget.isOpen,
            child: const NowPlayingPage(),
          ),
        );
      },
    );
  }
}

/// The floating bars at the bottom: a single unified pill containing the mini player and bottom navigation,
/// which smoothly extends upwards when a song is playing (Tidal style).
class _BottomBars extends StatelessWidget {
  const _BottomBars();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final isDark = colors.palette.isDark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: isDark ? const Color(0x2EFFFFFF) : const Color(0x22000000),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.palette.shadow,
                blurRadius: 24,
                spreadRadius: -4,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListenableBuilder(
                      listenable: player,
                      builder: (context, _) {
                        final track = player.currentTrack;
                        if (track == null) return const SizedBox.shrink();
                        return const _MiniPlayerContent();
                      },
                    ),
                    const _BottomNavigation(),
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

/// The five sections at the bottom, on a floating pill bar; the active one takes the colour and glow of its section.
class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final palette = colors.palette;
    final items = [
      (AppSection.artists, Icons.person_rounded, palette.coral, 'NavArtists'),
      (AppSection.albums, Icons.album, palette.purple, 'NavAlbums'),
      (AppSection.tracks, Icons.music_note_rounded, palette.cyan, 'NavTracks'),
      (AppSection.favorites, Icons.favorite_rounded, palette.coral, 'NavFavorites'),
      (AppSection.playlists, Icons.queue_music_rounded, palette.lime, 'NavPlaylistsShort'),
    ];
    return SizedBox(
      height: 64,
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
    const duration = Duration(milliseconds: 320);
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
            SizedBox(
              height: 30,
              child: AnimatedScale(
                scale: active ? 1.08 : 1,
                duration: duration,
                curve: Curves.easeOutBack,
                child: Icon(
                  icon,
                  size: 24,
                  color: active ? color : muted,
                  shadows: active ? [Shadow(color: color.withValues(alpha: 0.75), blurRadius: 16)] : null,
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: duration,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? color : muted,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
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
                fillColor: colors.surface2,
                prefixIcon: Icon(Icons.search_rounded, size: 20, color: colors.accent),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: colors.glassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: colors.accent, width: 1.5),
                ),
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
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: colors.danger.withValues(alpha: 0.45)),
      ),
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

/// The mini player content embedded in the upper part of the floating pill.
class _MiniPlayerContent extends StatelessWidget {
  const _MiniPlayerContent();

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

        return VerticalSwipe(
          upwards: true,
          onSwipe: vm.openNowPlaying,
          child: SizedBox(
            height: 66,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: vm.openNowPlaying,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
                      child: Row(
                        children: [
                          Hero(
                            tag: 'now-playing-cover',
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(Radii.small + 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: colors.palette.shadow,
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: CoverImage(path: track.coverArtPath, size: 44, radius: Radii.small + 2),
                            ),
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
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                    color: colors.textMain,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                if (player.isRemote && !player.hasError)
                                  const PlayingOnLabel(fontSize: 11.5)
                                else
                                  Text(
                                    player.hasError ? player.errorMessage! : player.nowPlayingArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
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
                  dimension: 38,
                  child: IconButton(
                    tooltip: context.tr('TipPrevious'),
                    onPressed: player.previousTrack,
                    icon: Icon(Icons.skip_previous_rounded, size: 24, color: colors.textMain),
                  ),
                ),
                SizedBox.square(
                  dimension: 42,
                  child: IconButton(
                    tooltip: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
                    onPressed: player.togglePlayPause,
                    icon: PlayPauseIcon(playing: player.isPlaying, size: 28, color: colors.accent),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox.square(
                    dimension: 38,
                    child: IconButton(
                      tooltip: context.tr('TipNext'),
                      onPressed: player.nextTrack,
                      icon: Icon(Icons.skip_next_rounded, size: 24, color: colors.textMain),
                    ),
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
