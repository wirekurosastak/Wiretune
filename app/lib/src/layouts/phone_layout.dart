// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../pages/login_page.dart';
import '../pages/now_playing_page.dart';
import '../pages/search_page.dart';
import '../pages/section_page.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/player_view_model.dart';
import '../widgets/ambient.dart';
import '../widgets/cover_flight.dart';
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
                        _SearchBarSlot(open: vm.isSearchOpen),
                        if (vm.isServerOfflineBannerVisible) const SafeArea(bottom: false, child: _OfflineBanner()),
                        Expanded(
                          child: _PageSwitcher(
                            section: vm.isSearchOpen ? null : vm.selectedSection,
                            returns: vm.returns,
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

/// The page, changing as the tab does: in from the side of the tab it goes to and out to the other, as the tabs are
/// laid out in the bar; the search, Settings (from the account button) and a page within a tab fade in and grow. Back
/// to where a page was opened from shows that place at once, as back within a tab does.
class _PageSwitcher extends StatefulWidget {
  const _PageSwitcher({required this.section, required this.returns, required this.child});

  /// The tab on show (null: the search).
  final AppSection? section;

  /// [MainViewModel.returns]: a new count is a back to where a page was opened from.
  final int returns;
  final Widget child;

  @override
  State<_PageSwitcher> createState() => _PageSwitcherState();
}

class _PageSwitcherState extends State<_PageSwitcher> {
  /// Which way the last change went: 1 to a tab further right, -1 to one further left, 0 neither.
  double _direction = 0;

  @override
  void didUpdateWidget(_PageSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section == widget.section) return;
    int place(AppSection? section) => section == null ? -1 : _BottomNavigation.order.indexOf(section);
    final from = place(oldWidget.section), to = place(widget.section);
    _direction = from < 0 || to < 0 ? 0 : (to - from).sign.toDouble();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    key: ValueKey(widget.returns),
    duration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (currentChild, previousChildren) =>
        Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
    transitionBuilder: (child, animation) {
      if (_direction == 0) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(animation), child: child),
        );
      }
      // The page coming in starts a little to the side it comes from; the one going out ends a little to the other.
      final incoming = child.key == widget.child.key;
      final side = incoming ? _direction : -_direction;
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: Offset(0.12 * side, 0), end: Offset.zero).animate(animation),
          child: child,
        ),
      );
    },
    child: widget.child,
  );
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

/// The five sections at the bottom, on a floating pill bar; the active one takes the colour of its section, and its
/// glow glides over from the one that was.
class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation();

  /// The tabs as the bar lays them out, left to right.
  static const List<AppSection> order = [
    AppSection.artists,
    AppSection.albums,
    AppSection.tracks,
    AppSection.favorites,
    AppSection.playlists,
  ];

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final palette = context.colors.palette;
    final items = [
      for (final (section, label) in const [
        (AppSection.artists, 'NavArtists'),
        (AppSection.albums, 'NavAlbums'),
        (AppSection.tracks, 'NavTracks'),
        (AppSection.favorites, 'NavFavorites'),
        (AppSection.playlists, 'NavPlaylistsShort'),
      ])
        (section, sectionIcon(section), palette.accentFor(section), label),
    ];
    assert(listEquals([for (final item in items) item.$1], order));
    final active = vm.isSearchOpen ? -1 : items.indexWhere((item) => item.$1 == vm.selectedSection);
    // Room under it, as in TIDAL's pill, so the labels clear the pill's rounded bottom.
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: SizedBox(
        height: 64,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth / items.length;
            return Stack(
              children: [
                // The glow behind the active icon, moving from tab to tab in the colour of the one it goes to; gone
                // while none is (the search, Settings).
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  left: width * math.max(active, 0) + (width - _NavItem.glowSize) / 2,
                  top: _NavItem.iconMiddle - _NavItem.glowSize / 2,
                  width: _NavItem.glowSize,
                  height: _NavItem.glowSize,
                  child: IgnorePointer(
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: active < 0 ? items.first.$3.withValues(alpha: 0) : items[active].$3),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      builder: (context, color, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              color!.withValues(alpha: 0.34 * color.a),
                              color.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final (i, (section, icon, color, label)) in items.indexed)
                      Expanded(
                        child: _NavItem(
                          icon: icon,
                          label: context.tr(label),
                          color: color,
                          active: i == active,
                          onTap: () => vm.navigateTo(section),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
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

  /// The glow behind the active icon ([_BottomNavigation]'s), and the height of the icon's middle in the bar: the
  /// icon's 30 and the label's line (about 13 at 11 px) under it, centred in the bar's 64 less the 4 above and below.
  static const double glowSize = 56, iconMiddle = 4 + (56 - 30 - 3 - 13) / 2 + 15;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.textMuted;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        // No ripple: the section's colour and glow say which is active, as elsewhere.
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.card),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // The icon and the label take the colour together, in step with the page's fade; the icon that becomes the
            // active one gives a small bounce.
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: active ? 1 : 0),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              builder: (context, lit, _) {
                final tint = Color.lerp(muted, color, lit)!;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 30,
                      child: Transform.scale(
                        scale: active ? 1 + 0.16 * math.sin(math.pi * lit) : 1,
                        child: Icon(
                          icon,
                          size: 24,
                          color: tint,
                          shadows: lit > 0 ? [Shadow(color: color.withValues(alpha: 0.4 * lit), blurRadius: 10)] : null,
                        ),
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

/// The search field over the page while the search is open: it grows out of the button that opened it
/// ([PinnedTitleBar.searchFrom]) into the whole bar, pushing the page down, and goes back into it as the search
/// closes.
class _SearchBarSlot extends StatefulWidget {
  const _SearchBarSlot({required this.open});

  final bool open;

  @override
  State<_SearchBarSlot> createState() => _SearchBarSlotState();
}

class _SearchBarSlotState extends State<_SearchBarSlot> with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _shown,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// Where it grows out of and goes back into, on the screen (the field's box is at the screen's top left).
  Rect? _from;

  @override
  void initState() {
    super.initState();
    if (widget.open) _from = _takeFrom();
  }

  @override
  void didUpdateWidget(_SearchBarSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (widget.open) {
      _from = _takeFrom() ?? _from;
      _shown.forward(from: 0);
    } else {
      _shown.reverse();
    }
  }

  static Rect? _takeFrom() {
    final from = PinnedTitleBar.searchFrom;
    PinnedTitleBar.searchFrom = null;
    return from;
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _shown,
    builder: (context, child) {
      if (_shown.isDismissed) return const SizedBox.shrink();
      final t = _curve.value;
      // One tree throughout (the field keeps its focus and its text), clipping only while it moves.
      return SizeTransition(
        sizeFactor: _curve,
        alignment: Alignment.topCenter,
        child: ClipPath(
          clipBehavior: t >= 1 ? Clip.none : Clip.antiAlias,
          clipper: _GrowFrom(from: _from, t: t, top: MediaQuery.paddingOf(context).top),
          child: Opacity(opacity: (t * 2).clamp(0.0, 1.0), child: child),
        ),
      );
    },
    child: const SafeArea(bottom: false, child: _SearchBar()),
  );
}

/// The part of the search bar shown [t] of the way open: a pill from [from] (the button, else the bar's right end) to
/// the whole bar below the status bar ([top]).
class _GrowFrom extends CustomClipper<Path> {
  const _GrowFrom({required this.from, required this.t, required this.top});

  final Rect? from;
  final double t;
  final double top;

  @override
  Path getClip(Size size) {
    final whole = Rect.fromLTRB(0, top, size.width, size.height);
    final start = from ?? Rect.fromLTWH(size.width - 52, top + 8, 44, 44);
    final rect = Rect.lerp(start, whole, t)!;
    final radius = Radius.circular(start.shortestSide / 2 * (1 - t));
    return Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
  }

  @override
  bool shouldReclip(_GrowFrom oldClipper) => oldClipper.t != t || oldClipper.from != from || oldClipper.top != top;
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

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (player.currentTrack == null) return const SizedBox.shrink();

        // Room above it, as in TIDAL's pill, under the pill's rounded top.
        return Padding(
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
                        child: InkWell(
                          onTap: vm.openNowPlaying,
                          child: _SkipSwipe(
                            player: player,
                            builder: (context, track, {required current}) => Padding(
                              padding: EdgeInsets.fromLTRB(math.max(0, (column - _coverSize) / 2), 0, 4, 0),
                              child: _MiniTrack(track: track, current: current),
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
        );
      },
    );
  }
}

/// A track in the mini player: its cover and titles. The [current] one is where the full-screen player pours out
/// of and queued music lands, and says what is wrong or where it plays; the one beside it while it changes, only
/// what it is.
class _MiniTrack extends StatelessWidget {
  const _MiniTrack({required this.track, required this.current});

  final Track track;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    Widget cover = DecoratedBox(
      key: current ? PlayerSheetScope.maybeOf(context)?.lamp : null,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.small),
        boxShadow: [BoxShadow(color: colors.palette.shadow, blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: CoverImage(path: track.coverArtPath, size: _MiniPlayer._coverSize, radius: Radii.small),
    );
    if (current) cover = CoverFlightLanding(radius: Radii.small, child: cover);
    final error = current && player.hasError;
    return Row(
      children: [
        cover,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current ? player.nowPlayingTitle : track.title,
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
              if (current && player.isRemote && !error)
                const PlayingOnLabel(fontSize: 11.5)
              else
                Text(
                  error ? player.errorMessage! : (current ? player.nowPlayingArtist : track.artist),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: error ? colors.danger : colors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The mini player's track as one of the queue's in a row, as in TIDAL and Spotify: a swipe left or right moves it with
/// the finger, the next track (left) or the one before (right) coming in beside it, and let go past a third of the
/// way, or flung, that one plays; else they go back. Changed any other way (it ran out, a button, another device),
/// the new track comes in from the side it lies on in the queue too, so the pill shows which way it can be swiped. A
/// screen reader, which takes the swipes for itself, offers Next and Previous as its actions.
class _SkipSwipe extends StatefulWidget {
  const _SkipSwipe({required this.player, required this.builder});

  final PlayerViewModel player;

  /// A track's part of the mini player: the one playing ([current]) or one beside it.
  final Widget Function(BuildContext context, Track track, {required bool current}) builder;

  @override
  State<_SkipSwipe> createState() => _SkipSwipeState();
}

class _SkipSwipeState extends State<_SkipSwipe> with SingleTickerProviderStateMixin {
  /// How far the playing track is off its place, in pixels (left when negative).
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);
  double _width = 1;

  /// The track beside the playing one while they move: on its right (the next) when [_offset] is negative, on its
  /// left when positive.
  Track? _beside;

  /// The track last shown as playing, and whether the swipe itself changed it (it is in place already).
  late Track? _shown = widget.player.currentTrack;
  bool _swiped = false;

  PlayerViewModel get _player => widget.player;

  @override
  void didUpdateWidget(_SkipSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    final track = _player.currentTrack;
    final previous = _shown;
    if (track == null || identical(track, previous)) return;
    _shown = track;
    if (_swiped || previous == null || track.id == previous.id) {
      _swiped = false;
      return;
    }
    // Changed elsewhere: in from the side it lies on in the queue, the old one going out the other way; from the
    // right unless it is the one before.
    final back =
        identical(_besideOf(track, next: true), previous) && !identical(_besideOf(track, next: false), previous);
    _beside = previous;
    _offset.value = back ? -_width : _width;
    unawaited(_settle(duration: 260));
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  /// The track after the playing one in the queue, or ([next] false) the one before; none at an end the queue doesn't
  /// go round.
  Track? _neighbour({required bool next}) => _besideOf(_player.currentTrack, next: next);

  Track? _besideOf(Track? track, {required bool next}) {
    final queue = _player.queueTracks;
    final index = track == null ? -1 : queue.indexWhere((t) => identical(t, track));
    if (index < 0) return null;
    final at = index + (next ? 1 : -1);
    if (at >= 0 && at < queue.length) return queue[at];
    return _player.repeatMode == RepeatMode.all && queue.length > 1 ? queue[at % queue.length] : null;
  }

  Future<void> _settle({required int duration}) async {
    await _offset.animateTo(
      0,
      duration: Duration(milliseconds: duration),
      curve: Curves.easeOutCubic,
    );
    if (mounted && _offset.value == 0) setState(() => _beside = null);
  }

  void _drag(double delta) {
    final offset = _offset.value;
    final next = (offset + delta) < 0;
    final beside = _neighbour(next: next);
    // Past an end of the queue it gives, but only a little.
    _offset.value = offset + (beside == null ? delta * 0.3 : delta);
    if (!identical(beside, _beside)) setState(() => _beside = beside);
  }

  Future<void> _release(double velocity) async {
    final offset = _offset.value;
    final skip = velocity.abs() > 600 ? -velocity.sign : (offset.abs() > _width / 3 ? -offset.sign : 0.0);
    final next = skip > 0;
    if (skip == 0 || _neighbour(next: next) == null || (velocity.abs() > 600 && velocity.sign == offset.sign * -1)) {
      await _settle(duration: 220);
      return;
    }
    // On out the way it went, the other in place.
    await _offset.animateTo(-skip * _width, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    _swiped = true;
    next ? _player.nextTrack() : _player.previousTrack(restart: false);
    _offset.value = 0;
    setState(() => _beside = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth;
      final track = _player.currentTrack;
      if (track == null) return const SizedBox.shrink();
      final gestures = GestureDetector(
        onHorizontalDragStart: (_) => _offset.stop(),
        onHorizontalDragUpdate: (details) => _drag(details.primaryDelta ?? 0),
        onHorizontalDragEnd: (details) => unawaited(_release(details.primaryVelocity ?? 0)),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, _) {
              final offset = _offset.value;
              final beside = _beside;
              Widget at(double x, Widget child) => Opacity(
                opacity: (1 - x.abs() / _width).clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset(x, 0), child: child),
              );
              return Stack(
                children: [
                  if (beside != null && offset != 0)
                    Positioned.fill(
                      child: at(offset - offset.sign * _width, widget.builder(context, beside, current: false)),
                    ),
                  Positioned.fill(child: at(offset, widget.builder(context, track, current: true))),
                ],
              );
            },
          ),
        ),
      );
      return Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: context.tr('TipNext')): _player.nextTrack,
          CustomSemanticsAction(label: context.tr('TipPrevious')): _player.previousTrack,
        },
        child: gestures,
      );
    },
  );
}
