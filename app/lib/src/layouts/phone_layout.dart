// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:ui' as ui;

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
/// backdrop, and floating over its lower edge the glass mini player and bottom navigation, which the page scrolls
/// under; search and the full-screen player slide over it.
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
                  const Positioned.fill(child: AmbientBackdrop(colour: 0.42)),
                  SafeArea(
                    bottom: false,
                    child: Column(
                      children: [
                        if (vm.isSearchOpen) const _SearchBar(),
                        if (vm.isServerOfflineBannerVisible) const _OfflineBanner(),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
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
                  ),
                ],
              ),
              bottomNavigationBar: const _BottomBars(),
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

/// The floating bars at the bottom: the mini player over the navigation, on a fade of the backdrop's colour so the
/// page scrolling under them stays out of their way.
class _BottomBars extends StatelessWidget {
  const _BottomBars();

  @override
  Widget build(BuildContext context) {
    final background = context.colors.palette.background;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [background.withValues(alpha: 0), background.withValues(alpha: 0.85)],
        ),
      ),
      child: const SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [_MiniPlayer(), _BottomNavigation()]),
      ),
    );
  }
}

/// A floating pane of frosted glass: what is behind it is blurred and tinted with the panel colour.
class _Frosted extends StatelessWidget {
  const _Frosted({required this.child, this.radius = 22, this.background});

  final Widget child;
  final double radius;

  /// Painted behind the tint, inside the frost (the mini player's wash of the cover).
  final Widget? background;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(color: colors.palette.shadow, blurRadius: 24, spreadRadius: -6, offset: const Offset(0, 10)),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Stack(
            children: [
              if (background != null) Positioned.fill(child: background!),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.palette.panel.withValues(alpha: colors.palette.isDark ? 0.62 : 0.7),
                    borderRadius: shape,
                    border: Border.all(color: colors.glassBorder),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// The five sections at the bottom, on a floating glass bar; the active one takes the colour of its section, and a
/// pill of that colour grows behind its icon.
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
      (AppSection.tracks, Icons.music_note_rounded, palette.cyan, 'NavSongs'),
      (AppSection.favorites, Icons.favorite_rounded, palette.coral, 'NavFavorites'),
      (AppSection.playlists, Icons.queue_music_rounded, palette.lime, 'NavPlaylistsShort'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: _Frosted(
        radius: 26,
        child: SizedBox(
          height: 66,
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
    const duration = Duration(milliseconds: 320);
    return Semantics(
      selected: active,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // No overshooting curve here: a shadow lerped past its end would get a negative blur.
            AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              width: active ? 56 : 32,
              height: 30,
              decoration: BoxDecoration(
                color: active ? color.withValues(alpha: 0.2) : color.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(999),
                boxShadow: active ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 14)] : const [],
              ),
              child: AnimatedScale(
                scale: active ? 1.08 : 1,
                duration: duration,
                curve: Curves.easeOutBack,
                child: Icon(icon, size: 23, color: active ? color : muted),
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

/// The mini player: a floating glass card washed in the colours of the cover, with the cover, title and artist,
/// play/pause and next, and the progress as a glowing line along its lower edge. A tap opens the full-screen player.
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
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: _Frosted(
            radius: 20,
            background: AmbientArtwork(path: track.coverArtPath, opacity: 0.9),
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                children: [
                  SizedBox(
                    height: 66,
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: vm.openNowPlaying,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(9, 0, 4, 0),
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
                                            blurRadius: 10,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: CoverImage(path: track.coverArtPath, size: 48, radius: Radii.small + 2),
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
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.2,
                                            color: colors.textMain,
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        if (player.isRemote && !player.hasError)
                                          const PlayingOnLabel(fontSize: 12.5)
                                        else
                                          Text(
                                            player.hasError ? player.errorMessage! : player.nowPlayingArtist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12.5,
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
                        const DevicesButton(),
                        SizedBox.square(
                          dimension: 46,
                          child: IconButton(
                            tooltip: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
                            onPressed: player.togglePlayPause,
                            icon: PlayPauseIcon(playing: player.isPlaying, size: 30, color: colors.textMain),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: SizedBox.square(
                            dimension: 46,
                            child: IconButton(
                              tooltip: context.tr('TipNext'),
                              onPressed: player.nextTrack,
                              icon: Icon(Icons.skip_next_rounded, size: 28, color: colors.textMain),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 0,
                    child: ListenableBuilder(
                      listenable: progressOf(player),
                      builder: (context, _) {
                        final total = player.duration.inMilliseconds;
                        final fraction = total <= 0
                            ? 0.0
                            : (player.position.value.inMilliseconds / total).clamp(0.0, 1.0);
                        return Container(
                          height: 2.5,
                          decoration: BoxDecoration(
                            color: colors.palette.glassHighlight,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: fraction,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: colors.accentGradient,
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: [BoxShadow(color: colors.accent.withValues(alpha: 0.7), blurRadius: 6)],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
