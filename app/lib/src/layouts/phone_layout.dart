// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../pages/login_page.dart';
import '../pages/now_playing_page.dart';
import '../pages/search_page.dart';
import '../pages/section_page.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../widgets/ambient.dart';
import '../widgets/cover_colour.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/page_parts.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_sheet.dart';

/// The phone layout: the page (each draws its own header with the search and account buttons) over the ambient
/// backdrop, and floating over its lower edge the unified pill with the mini player and bottom navigation;
/// search and the full-screen player slide over it, the player with the finger that drags it ([PlayerSheet]).
class PhoneLayout extends StatefulWidget {
  const PhoneLayout({super.key});

  @override
  State<PhoneLayout> createState() => _PhoneLayoutState();
}

class _PhoneLayoutState extends State<PhoneLayout> with SingleTickerProviderStateMixin {
  late final PlayerSheet _sheet = PlayerSheet(vsync: this, open: context.vm.isNowPlayingOpen);

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return PlayerSheetScope(
      sheet: _sheet,
      child: PhoneChrome(
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
                            layoutBuilder: (currentChild, previousChildren) =>
                                Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
                            transitionBuilder: (child, animation) => FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween(begin: 0.985, end: 1.0).animate(animation),
                                child: child,
                              ),
                            ),
                            child: vm.isSearchOpen
                                // A touch on the results puts the keyboard away (as in Spotify): a menu opened there
                                // then has no field to give the focus back to when it closes.
                                ? Listener(
                                    key: const ValueKey('search'),
                                    onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                                    child: const SearchResults(),
                                  )
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
                child: _NowPlayingOverlay(sheet: _sheet, isOpen: vm.isNowPlayingOpen),
              ),
              if (vm.isLoginViewActive) const Positioned.fill(child: LoginPage()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full-screen player, as far open as its [sheet] is: pouring out of the mini player's cover when opened and back
/// into it when closed, or with the finger ([MagicLamp]).
class _NowPlayingOverlay extends StatefulWidget {
  const _NowPlayingOverlay({required this.sheet, required this.isOpen});

  final PlayerSheet sheet;
  final bool isOpen;

  @override
  State<_NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<_NowPlayingOverlay> {
  @override
  void didUpdateWidget(_NowPlayingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen != oldWidget.isOpen) widget.sheet.follow(open: widget.isOpen);
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.sheet.position;
    return AnimatedBuilder(
      animation: position,
      builder: (context, _) {
        if (position.isDismissed && !widget.isOpen) return const SizedBox.shrink();
        return MagicLamp(
          sheet: widget.sheet,
          child: IgnorePointer(ignoring: !widget.isOpen, child: const NowPlayingPage()),
        );
      },
    );
  }
}

/// The floating bars at the bottom: a single unified pill containing the mini player and bottom navigation,
/// which smoothly extends upwards when a song is playing (Tidal style).
class _BottomBars extends StatelessWidget {
  const _BottomBars();

  /// The pill's shape and place, TIDAL's: 9 from the sides, 18 above the screen's edge (over a gesture bar, clear of
  /// the system's buttons), corners of 40.
  static const double _side = 9, _bottom = 18, _radius = 40;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    return MediaQuery.removePadding(
      context: context,
      removeBottom: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_side, 0, _side, math.max(_bottom, inset - 6)),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.palette.modal,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: colors.palette.panelBorder),
            boxShadow: [
              BoxShadow(color: colors.palette.shadow, blurRadius: 24, spreadRadius: -4, offset: const Offset(0, 8)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: Material(
              type: MaterialType.transparency,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: const Column(mainAxisSize: MainAxisSize.min, children: [_MiniPlayer(), _BottomNavigation()]),
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
    // Room under it, as in TIDAL's pill, so the labels clear the pill's rounded bottom.
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: SizedBox(
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
                  onTap: () => vm.navigateTo(section),
                ),
              ),
          ],
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
      child: Material(
        type: MaterialType.transparency,
        // No ripple and no bounce: the section's colour and glow say which is active, as elsewhere.
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.card),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // The icon, its glow and the label take the colour together, in step with the page's fade.
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: active ? 1 : 0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (context, lit, _) {
                final tint = Color.lerp(muted, color, lit)!;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 30,
                      child: Icon(
                        icon,
                        size: 24,
                        color: tint,
                        shadows: lit > 0 ? [Shadow(color: color.withValues(alpha: 0.75 * lit), blurRadius: 16)] : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: lit > 0.5 ? FontWeight.w700 : FontWeight.w600,
                        color: tint,
                      ),
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                );
              },
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

  // It follows the query itself (its clear button the typing): as a const child it isn't rebuilt with the page.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
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
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide(color: colors.glassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide(color: colors.accent, width: 1.5),
                ),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: context.tr('TipClearSearch'),
                        onPressed: () {
                          _controller.clear();
                          vm.clearSearch();
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
          Icon(
            vm.serverBannerNeedsSignIn ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
            color: colors.danger,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              vm.serverBannerMessage,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textMain),
            ),
          ),
          TextButton(
            onPressed: vm.serverBannerNeedsSignIn ? vm.showLoginScreen : vm.retryConnectServer,
            child: Text(context.tr(vm.serverBannerNeedsSignIn ? 'SignIn' : 'Reconnect')),
          ),
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

/// The mini player in the upper part of the floating pill, while a track is loaded.
class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer();

  static const double _coverSize = 44, _playSize = 38;

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

        // A faint wash of the cover's colour from the pill's top; Play stays in the section's, as everywhere.
        return CoverTint(
          path: track.coverArtPath,
          builder: (context, wash) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: wash == null
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        wash.withValues(alpha: 0.2 * wash.a),
                        wash.withValues(alpha: 0),
                      ],
                    ),
            ),
            // Room above it, as in TIDAL's pill, under the pill's rounded top.
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: PlayerSheetDrag(
                // The cover and Play stand over the nav's outer icons (Artists and Playlists): each is centred in a fifth
                // of the pill's width, as they are. A swipe over the track skips (no buttons for it, as in TIDAL and
                // Spotify).
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final column = constraints.maxWidth / 5;
                    return SizedBox(
                      height: 66,
                      child: Row(
                        children: [
                          Expanded(
                            child: _SkipSwipe(
                              onNext: player.nextTrack,
                              onPrevious: player.previousTrack,
                              child: InkWell(
                                onTap: vm.openNowPlaying,
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(math.max(0, (column - _coverSize) / 2), 0, 4, 0),
                                  child: Row(
                                    children: [
                                      // The lamp the full-screen player pours out of.
                                      DecoratedBox(
                                        key: PlayerSheetScope.maybeOf(context)?.lamp,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(Radii.small),
                                          boxShadow: [
                                            BoxShadow(
                                              color: colors.palette.shadow,
                                              blurRadius: 8,
                                              offset: const Offset(0, 3),
                                            ),
                                          ],
                                        ),
                                        child: CoverImage(
                                          path: track.coverArtPath,
                                          size: _coverSize,
                                          radius: Radii.small,
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
                          ),
                          // The players' round Play, as in the full-screen player and on a computer.
                          Padding(
                            padding: EdgeInsets.only(right: math.max(0, (column - _playSize) / 2)),
                            child: const PlayButton(size: _playSize),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A swipe left or right over the mini player's track (the cover and the titles), as in TIDAL and Spotify: the track
/// follows the finger, and let go past a third of the way, or flung, it goes on out and the next (left) or the previous
/// (right) comes in from the other side; else it goes back. A screen reader, which takes the swipes for itself, offers
/// Next and Previous as its actions.
class _SkipSwipe extends StatefulWidget {
  const _SkipSwipe({required this.onNext, required this.onPrevious, required this.child});

  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Widget child;

  @override
  State<_SkipSwipe> createState() => _SkipSwipeState();
}

class _SkipSwipeState extends State<_SkipSwipe> with SingleTickerProviderStateMixin {
  /// How far the track is off its place, in pixels (left when negative).
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);
  double _width = 1;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  Future<void> _release(double velocity) async {
    final offset = _offset.value;
    final skip = velocity.abs() > 600 ? velocity.sign : (offset.abs() > _width / 3 ? offset.sign : 0.0);
    if (skip == 0) {
      await _offset.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      return;
    }
    // Out the way it went, the other track in from the far side.
    await _offset.animateTo(skip * _width, duration: const Duration(milliseconds: 140), curve: Curves.easeIn);
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    skip < 0 ? widget.onNext() : widget.onPrevious();
    _offset.value = -skip * _width * 0.6;
    await _offset.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      final gestures = GestureDetector(
        onHorizontalDragStart: (_) => _offset.stop(),
        onHorizontalDragUpdate: (details) => _offset.value += details.primaryDelta ?? 0,
        onHorizontalDragEnd: (details) => unawaited(_release(details.primaryVelocity ?? 0)),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => Opacity(
              opacity: (1 - _offset.value.abs() / _width).clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(_offset.value, 0), child: child),
            ),
            child: widget.child,
          ),
        ),
      );
      return Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: context.tr('TipNext')): widget.onNext,
          CustomSemanticsAction(label: context.tr('TipPrevious')): widget.onPrevious,
        },
        child: gestures,
      );
    },
  );
}
