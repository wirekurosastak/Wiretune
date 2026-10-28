// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../pages/login_page.dart';
import '../pages/queue_panel.dart';
import '../pages/search_page.dart';
import '../pages/section_page.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';
import '../view_models/app_section.dart';
import '../view_models/main_view_model.dart';
import '../widgets/ambient.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cover_flight.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/links.dart';
import '../widgets/nav_visualizer.dart';
import '../widgets/player_controls.dart';
import '../widgets/spectrum_visualizer.dart';
import '../widgets/track_list.dart';
import '../widgets/tv_focus.dart';

/// The desktop, tablet and TV layout: the header (logo, search, the mode pills, account, language, theme and, without a
/// system title bar, the window buttons), then floating panels over the ambient backdrop: the sidebar, the page and the
/// player bar, with the status line under them.
class WideLayout extends StatelessWidget {
  const WideLayout({super.key});

  /// The space between the floating panels and around them.
  static const double gap = 10;

  /// Below this width the sidebar shows icons alone, and the header and the player bar leave out what they can spare.
  static const double compactWidth = 1000;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Material(
      color: colors.palette.background,
      child: TvFocusAreas(
        child: ListenableBuilder(
          listenable: vm,
          builder: (context, _) => Stack(
            children: [
              const Positioned.fill(child: AmbientBackdrop()),
              // Under the sign-in page nothing takes the focus: a remote's arrows or Tab would go behind it.
              ExcludeFocus(
                excluding: vm.isLoginViewActive,
                child: Column(
                  children: [
                    const TvFocusArea(area: TvArea.header, child: _Header()),
                    if (vm.isServerOfflineBannerVisible) const _OfflineBanner(),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: gap),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const TvFocusArea(area: TvArea.sidebar, child: _Sidebar()),
                            const SizedBox(width: gap),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(Radii.panel),
                                child: ShaderMask(
                                  shaderCallback: (rect) => const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
                                    stops: [0.0, 0.035, 0.965, 1.0],
                                  ).createShader(rect),
                                  blendMode: BlendMode.dstIn,
                                  child: TvFocusArea(
                                    area: TvArea.content,
                                    child: FocusTraversalGroup(child: _Content(vm: vm)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: gap),
                    const TvFocusArea(area: TvArea.player, child: _PlayerBar()),
                    const _Footer(),
                  ],
                ),
              ),
              if (vm.isLoginViewActive) const Positioned.fill(child: LoginPage()),
            ],
          ),
        ),
      ),
    );
  }
}

/// A floating panel: rounded, solid, with a hairline edge.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.colors.palette;
    final radius = BorderRadius.circular(Radii.panel);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.modal,
        borderRadius: radius,
        border: Border.all(color: palette.panelBorder),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}

/// The page of the selected section, or the search results, or the queue, fading in. A page opened from another
/// section or the search, and back from it to there, shows at once, as within a section ([MainViewModel.jumps]).
class _Content extends StatelessWidget {
  const _Content({required this.vm});

  final MainViewModel vm;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm.player,
    builder: (context, _) {
      final Widget page;
      if (vm.player.isQueueOpen) {
        page = const QueueLyricsPanel(key: ValueKey('queue'));
      } else if (vm.isSearchActive) {
        page = const SearchResults(key: ValueKey('search'));
      } else {
        page = KeyedSubtree(key: ValueKey(vm.selectedSection), child: sectionPage(vm.selectedSection));
      }
      return _TilePinch(
        child: AnimatedSwitcher(
          key: ValueKey(vm.jumps),
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          layoutBuilder: (currentChild, previousChildren) =>
              Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(animation),
              child: ScaleTransition(scale: Tween(begin: 0.99, end: 1.0).animate(animation), child: child),
            ),
          ),
          child: page,
        ),
      );
    },
  );
}

/// Two fingers on a touch screen, or a touchpad's pinch, spread or pinched over the page: its tiles grow or shrink
/// (`MainViewModel.tileSize`), as many columns fitting as their size leaves room for.
class _TilePinch extends StatefulWidget {
  const _TilePinch({required this.child});

  final Widget child;

  @override
  State<_TilePinch> createState() => _TilePinchState();
}

class _TilePinchState extends State<_TilePinch> {
  final Map<int, Offset> _touches = {};
  double? _startSpan;
  double _startSize = MainViewModel.tileSizeDefault;

  double get _span => (_touches.values.first - _touches.values.last).distance;

  /// Two fingers down: the pinch starts from them; any other number of them, none.
  void _begin() {
    _startSize = context.vm.tileSize.value;
    _startSpan = _touches.length == 2 ? _span : null;
  }

  void _resize(double scale) =>
      context.vm.tileSize.value = (_startSize * scale).clamp(MainViewModel.tileSizeMin, MainViewModel.tileSizeMax);

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.kind != PointerDeviceKind.touch) return;
      _touches[event.pointer] = event.position;
      _begin();
    },
    onPointerMove: (event) {
      if (!_touches.containsKey(event.pointer)) return;
      _touches[event.pointer] = event.position;
      final start = _startSpan;
      if (start != null && start > 0 && _touches.length == 2) _resize(_span / start);
    },
    onPointerUp: (event) {
      _touches.remove(event.pointer);
      _begin();
    },
    onPointerCancel: (event) {
      _touches.remove(event.pointer);
      _begin();
    },
    onPointerPanZoomStart: (_) => _startSize = context.vm.tileSize.value,
    onPointerPanZoomUpdate: (event) => _resize(event.scale),
    child: widget.child,
  );
}

// ── Header ──────────────────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final compact = MediaQuery.sizeOf(context).width < WideLayout.compactWidth;
    final frameless = AppPlatform.current.hasCustomWindowFrame;
    final content = CustomMultiChildLayout(
      delegate: _HeaderLayout(),
      children: [
        LayoutId(
          id: _HeaderSlot.brand,
          child: Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([vm, vm.player]),
                  builder: (context, _) => NavVisualizer(
                    waveTrigger: vm.waveTrigger,
                    direction: vm.lastWaveDirection,
                    color: context.colors.accent,
                    isPlaying: vm.player.isPlaying,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 14),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The wordmark fades into the section's colour towards its end.
                      ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (rect) => LinearGradient(
                          colors: [colors.textMain, colors.textMain, colors.hover],
                          stops: const [0, 0.45, 1],
                        ).createShader(rect),
                        child: const Text(
                          'WIRETUNE',
                          style: TextStyle(fontSize: 17, letterSpacing: 3.2, fontWeight: FontWeight.w900, height: 1.1),
                        ),
                      ),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 350),
                        style: TextStyle(
                          fontSize: 8.5,
                          letterSpacing: 1.9,
                          fontWeight: FontWeight.w800,
                          color: colors.accent,
                        ),
                        child: const Text('STREAMER & PLAYER'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        LayoutId(id: _HeaderSlot.search, child: const _SearchField()),
        LayoutId(
          id: _HeaderSlot.actions,
          child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderModes(compact: compact),
                if (frameless) const _WindowButtons(),
              ],
            ),
          ),
        ),
      ],
    );
    return SizedBox(
      height: 66,
      // Without a system title bar the header is the title bar: dragging it moves the window, a double click
      // maximizes or restores it. The empty parts of the header reach the drag area behind the controls.
      child: frameless
          ? Stack(
              fit: StackFit.expand,
              children: [
                const DragToMoveArea(child: SizedBox.expand()),
                content,
              ],
            )
          : content,
    );
  }
}

enum _HeaderSlot { brand, search, actions }

/// The header's layout: the brand on the left, the buttons on the right, and the search box in the middle of the window
/// (not of the room between them), as wide as it can be there. Only when that leaves it narrower than [_minCentred]
/// does it move aside into the room between them.
class _HeaderLayout extends MultiChildLayoutDelegate {
  static const double _gap = 16;
  static const double _minCentred = 220;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final brand = layoutChild(_HeaderSlot.brand, loose);
    final actions = layoutChild(_HeaderSlot.actions, loose);
    positionChild(_HeaderSlot.brand, Offset(0, (size.height - brand.height) / 2));
    positionChild(_HeaderSlot.actions, Offset(size.width - actions.width, (size.height - actions.height) / 2));

    final left = brand.width + _gap;
    final right = size.width - actions.width - _gap;
    final half = size.width / 2;
    // The widest box centred on the window that clears both sides.
    final centred = 2 * math.min<double>(half - left, right - half);
    final room = centred >= _minCentred ? centred : math.max(0.0, right - left);
    final search = layoutChild(_HeaderSlot.search, BoxConstraints(maxWidth: room, maxHeight: size.height));
    final x = ((size.width - search.width) / 2).clamp(left, math.max(left, right - search.width)).toDouble();
    positionChild(_HeaderSlot.search, Offset(x, (size.height - search.height) / 2));
  }

  @override
  bool shouldRelayout(_HeaderLayout oldDelegate) => false;
}

class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _hover = false;

  late final ValueNotifier<int> _focusRequests = context.vm.searchFocusRequests;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    _focusRequests.addListener(_focusField);
  }

  void _focusField() {
    _focus.requestFocus();
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  @override
  void dispose() {
    _focusRequests.removeListener(_focusField);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  // It follows the query itself: as a const child it isn't rebuilt with the header around it, and the query also
  // changes elsewhere (cleared by back, a result opened, another section).
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    if (_controller.text != vm.searchQuery) {
      _controller.value = TextEditingValue(
        text: vm.searchQuery,
        selection: TextSelection.collapsed(offset: vm.searchQuery.length),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final focused = _focus.hasFocus;
    final radius = BorderRadius.circular(Radii.pill);
    OutlineInputBorder border(Color color, double thickness) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color, width: thickness),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        constraints: BoxConstraints(
          maxWidth: (width < 900 ? 280 : 420) + (focused ? 40 : 0),
          minHeight: 40,
          maxHeight: 40,
        ),
        decoration: BoxDecoration(borderRadius: radius, boxShadow: focused ? colors.accentGlow(0.8) : const []),
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          // The header's field has no open page of its own: emptied, the search is over, as with Escape.
          onChanged: (text) {
            if (text.isEmpty) {
              vm.closeSearch();
            } else {
              vm.searchQuery = text;
            }
          },
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 14, color: colors.textMain),
          decoration: InputDecoration(
            hintText: withShortcut(context.tr('SearchPlaceholder'), 'Ctrl+F'),
            filled: true,
            fillColor: colors.palette.modal,
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Icon(Icons.search_rounded, size: 19, color: focused ? colors.accent : colors.textMuted),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 42),
            suffixIcon: vm.isSearchActive
                ? IconButton(
                    tooltip: context.tr('TipClearSearch'),
                    onPressed: vm.closeSearch,
                    iconSize: 16,
                    icon: Icon(Icons.cancel_rounded, color: colors.textMuted),
                  )
                : null,
            contentPadding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
            border: border(colors.palette.panelBorder, 1),
            enabledBorder: border(_hover ? colors.palette.glassHighlight : colors.palette.panelBorder, 1),
            focusedBorder: border(colors.accent, 1.5),
          ),
        ),
      ),
    );
  }
}

class _HeaderModes extends StatelessWidget {
  const _HeaderModes({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: vm.player,
      builder: (context, _) {
        final player = vm.player;
        Widget modeBadge({
          required String label,
          required bool on,
          required QualityTier tier,
          required VoidCallback onTap,
          required String tip,
        }) {
          final bg = on ? MedalColors.bg(tier) : colors.surface1;
          final border = on ? MedalColors.border(tier) : colors.glassBorder;
          final fg = on ? MedalColors.fg(tier) : colors.textMuted;
          return Tooltip(
            message: context.tr(tip),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.tag),
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: bg,
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(Radii.tag),
                    boxShadow: on
                        ? [BoxShadow(color: fg.withValues(alpha: 0.25), blurRadius: 10, spreadRadius: -2)]
                        : const [],
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final modes = !compact && AppPlatform.current.isDesktop && !player.isRemote;
        if (!modes) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            modeBadge(
              label: 'BIT-PERFECT',
              on: player.isBitPerfect,
              tier: QualityTier.gold,
              onTap: player.toggleBitPerfect,
              tip: 'TipBitPerfect',
            ),
            const SizedBox(width: 8),
            modeBadge(
              label: 'EXCLUSIVE',
              on: player.isExclusiveMode,
              tier: QualityTier.silver,
              onTap: player.toggleExclusiveMode,
              tip: 'TipExclusive',
            ),
            const SizedBox(width: 12),
          ],
        );
      },
    );
  }
}

/// Minimize, maximize/restore and close, for a window without a system title bar.
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _WindowButton(
        icon: Icons.minimize_rounded,
        tooltip: context.tr('TipMinimize'),
        onPressed: windowManager.minimize,
      ),
      const SizedBox(width: 4),
      _WindowButton(
        icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
        tooltip: context.tr(_maximized ? 'TipRestore' : 'TipMaximize'),
        onPressed: () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
      ),
      const SizedBox(width: 4),
      _WindowButton(
        icon: Icons.close_rounded,
        tooltip: context.tr('Close'),
        onPressed: windowManager.close,
        close: true,
      ),
    ],
  );
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({required this.icon, required this.tooltip, required this.onPressed, this.close = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool close;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final red = widget.close && _hover;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: red ? const Color(0xFFE5484D) : (_hover ? colors.surface2 : Colors.transparent),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onPressed,
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(widget.icon, size: 15, color: red ? Colors.white : colors.textMain),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small dot of the status line, slowly fading in and out while music plays, as the logo breathes; a steady one
/// otherwise and on a phone or tablet, so that an idle window draws nothing.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.size, required this.pulsing});

  final Color color;
  final double size;
  final bool pulsing;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _animate();
  }

  @override
  void didUpdateWidget(_PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _animate();
  }

  void _animate() {
    final pulse = widget.pulsing && !AppPlatform.current.isMobile;
    if (pulse && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!pulse && _controller.isAnimating) {
      // Back to full, then still.
      _controller.animateTo(1, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.7), blurRadius: widget.size)],
      ),
    ),
  );
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(WideLayout.gap, 0, WideLayout.gap, WideLayout.gap),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: colors.danger.withValues(alpha: 0.55)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            vm.serverBannerNeedsSignIn ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
            color: colors.danger,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              vm.serverBannerMessage,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.textMain),
            ),
          ),
          const SizedBox(width: 16),
          PressShrink(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: vm.serverBannerNeedsSignIn ? vm.showLoginScreen : vm.retryConnectServer,
              icon: Icon(vm.serverBannerNeedsSignIn ? Icons.login_rounded : Icons.refresh_rounded, size: 16),
              label: Text(
                context.tr(vm.serverBannerNeedsSignIn ? 'SignIn' : 'Reconnect'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: () => vm.navigateTo(AppSection.settings),
            icon: const Icon(Icons.settings_outlined, size: 16),
            label: Text(context.tr('NavSettings'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: context.tr('TipDismissNotice'),
            onPressed: vm.dismissServerBanner,
            iconSize: 16,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

// ── Sidebar ─────────────────────────────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final palette = colors.palette;
    final compact = MediaQuery.sizeOf(context).width < WideLayout.compactWidth;
    return SizedBox(
      width: compact ? 68 : 232,
      child: _Panel(
        child: ListenableBuilder(
          // The counts follow the library (the view model tells of its changes), the favourites and the playlists.
          listenable: Listenable.merge([vm, vm.player, vm.favorites, vm.playlists]),
          builder: (context, _) {
            final library = vm.library;
            Widget item(AppSection section, String label, int? count, {bool autofocus = false}) => _SidebarItem(
              selected: vm.selectedSection == section && !vm.isSearchActive && !vm.player.isQueueOpen,
              icon: sectionIcon(section),
              // Settings, apart from the music, in the text's colour.
              color: section == AppSection.settings ? colors.textMain : palette.accentFor(section),
              label: label,
              count: count,
              compact: compact,
              autofocus: autofocus,
              onTap: () => vm.navigateTo(section),
            );
            return FocusTraversalGroup(
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: 18),
                children: [
                  if (!compact) _GroupTitle(context.tr('SectionLibrary')),
                  item(
                    AppSection.artists,
                    context.tr('NavArtists'),
                    library.artists.length,
                    autofocus: AppPlatform.current.isTv,
                  ),
                  item(AppSection.albums, context.tr('NavAlbums'), library.albums.length),
                  item(AppSection.tracks, context.tr('NavTracks'), library.tracks.length),
                  const SizedBox(height: 22),
                  if (!compact) _GroupTitle(context.tr('SectionCollection')),
                  item(AppSection.favorites, context.tr('NavFavorites'), vm.favorites.tracks.length),
                  item(AppSection.playlists, context.tr('NavPlaylists'), vm.playlists.allPlaylists.length),
                  // Settings alone needs no heading: the gap sets it apart.
                  const SizedBox(height: 22),
                  item(AppSection.settings, context.tr('NavSettings'), null),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 0, 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w800,
        color: context.colors.textMuted,
      ),
    ),
  );
}

/// A sidebar entry: the section's icon on a tile of its colour, its name and a counter. The selected one is washed
/// in its colour, and its tile lights up and glows.
class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.selected,
    required this.icon,
    required this.color,
    required this.label,
    required this.count,
    required this.compact,
    required this.onTap,
    this.autofocus = false,
  });

  final bool selected;
  final IconData icon;
  final Color color;
  final String label;
  final int? count;
  final bool compact;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = widget.selected;
    final color = widget.color;
    const duration = Duration(milliseconds: 260);
    // The tile pops under the mouse: quick, with a small overshoot, rather than the slower fade of the rest.
    final tile = AnimatedScale(
      scale: _hover && !selected ? 1.08 : 1,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.small),
          boxShadow: selected
              ? [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 14, spreadRadius: -2)]
              : const [],
        ),
        child: Icon(widget.icon, color: selected ? colors.onAccent : color, size: 17),
      ),
    );
    final content = Row(
      mainAxisAlignment: widget.compact ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        tile,
        if (!widget.compact) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? colors.textMain : colors.textMain.withValues(alpha: 0.85),
              ),
            ),
          ),
          if (widget.count != null)
            Text(
              '${widget.count}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: selected ? color : colors.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          const SizedBox(width: 4),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: widget.compact ? widget.label : '',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.medium),
              color: selected ? null : (_hover ? colors.surface1 : Colors.transparent),
              gradient: selected
                  ? LinearGradient(colors: [color.withValues(alpha: 0.24), color.withValues(alpha: 0.04)])
                  : null,
              border: Border.all(color: selected ? color.withValues(alpha: 0.28) : Colors.transparent),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                autofocus: widget.autofocus,
                borderRadius: BorderRadius.circular(Radii.medium),
                focusColor: color.withValues(alpha: 0.30),
                onTap: widget.onTap,
                child: SizedBox(
                  height: 46,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 8),
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Player bar ──────────────────────────────────────────────────────────────────────────────────────

/// The floating player bar: the cover and the track on the left, the transport and the seek bar in the middle, the
/// spectrum, the quality and the volume on the right.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final platform = AppPlatform.current;
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < WideLayout.compactWidth;
    // A 540 px middle, narrower when the window is (its two sides keep at least 180 px each).
    final centerWidth = math.min(540.0, math.max(300.0, width - 64 - 2 * 280));
    return Container(
      // The controls and the times grow with the user's font size; the bar grows with them.
      height: 80 + MediaQuery.textScalerOf(context).scale(16),
      margin: const EdgeInsets.symmetric(horizontal: WideLayout.gap),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.palette.modal,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: colors.palette.panelBorder),
        boxShadow: [
          BoxShadow(color: colors.palette.shadow, blurRadius: 30, spreadRadius: -8, offset: const Offset(0, 12)),
        ],
      ),
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final track = player.currentTrack;
          return Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const _QueueCover(),
                    const SizedBox(width: 14),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Tooltip(
                              message: track?.title ?? '',
                              child: Text(
                                player.nowPlayingTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.1,
                                  color: colors.textMain,
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            if (player.hasError)
                              Tooltip(
                                message: player.errorMessage!,
                                child: Text(
                                  player.errorMessage!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: colors.danger),
                                ),
                              )
                            else if (track == null)
                              Text(
                                player.nowPlayingArtist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: colors.textMuted),
                              )
                            else
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Tooltip(
                                      message: track.artist,
                                      child: ArtistLinks(
                                        track.artistNames,
                                        hoverColor: colors.palette.coral,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: colors.textMuted,
                                        ),
                                        onOpen: vm.openArtistByName,
                                      ),
                                    ),
                                  ),
                                  if (track.album.trim().isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Text(
                                        '•',
                                        style: TextStyle(fontSize: 11, color: colors.textMuted.withValues(alpha: 0.6)),
                                      ),
                                    ),
                                    Flexible(
                                      child: Tooltip(
                                        message: track.album,
                                        child: LinkText(
                                          track.album,
                                          hoverColor: colors.palette.purple,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            color: colors.textMuted,
                                          ),
                                          onTap: () => vm.openAlbumOfTrack(track),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            if (player.isRemote) ...[const SizedBox(height: 3), const PlayingOnLabel(fontSize: 11)],
                          ],
                        ),
                      ),
                    ),
                    // The heart and the track's menu with the rest, as on its row and in the phone's player.
                    if (track != null) ...[
                      const SizedBox(width: 8),
                      const FavoriteCurrentButton(size: 19, visualDensity: VisualDensity.compact),
                      TrackMenu(track: track, kind: TrackTableKind.tracks, width: 40, iconSize: 19),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: centerWidth,
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [TransportControls(), SizedBox(height: 2), SeekBar()],
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Spectrum, tags and volume, as many as fit: the volume first, then the track's tags, then the
                    // spectrum in what is left, down to 160 px.
                    final scale = MediaQuery.textScalerOf(context).scale(1);
                    // The devices button (while there are other devices to reach) takes its place first.
                    final devices = player.canReachDevices || player.isRemote;
                    // A computer's volume is a button with its slider above it. A tablet's and a TV's own buttons set
                    // their own volume, but not another device's: a slider in the bar for that, where it fits.
                    final volumeButton = platform.isDesktop;
                    final volumeSlider = !volumeButton && player.isRemote && constraints.maxWidth >= 12 + 36 + 8 + 95;
                    final room =
                        constraints.maxWidth -
                        12 -
                        (volumeButton ? 40 : 0) -
                        (volumeSlider ? 36 + 8 + 95 : 0) -
                        (devices ? 40 : 0) -
                        40 -
                        8;
                    final showTags = !compact && track != null && room >= 125 * scale;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (!compact && platform.isDesktop)
                            Flexible(
                              child: LayoutBuilder(
                                builder: (context, space) {
                                  final width = math.min(260.0, space.maxWidth - 14);
                                  if (width < 160) return const SizedBox.shrink();
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SpectrumVisualizer(
                                        bands: player.spectrum,
                                        color: colors.accent,
                                        highlight: colors.hover,
                                        width: width,
                                      ),
                                      const SizedBox(width: 14),
                                    ],
                                  );
                                },
                              ),
                            ),
                          if (showTags) ...[
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: room),
                              child: PlayerTags(track: track, stacked: true),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (volumeButton) const VolumeButton(iconSize: 19, dimension: 40),
                          const SleepTimerButton(iconSize: 19, dimension: 40),
                          if (devices) const DevicesButton(iconSize: 19, dimension: 40),
                          if (volumeSlider) const VolumeControl(sliderWidth: 95),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The cover of the current track, which opens and closes the queue: a dark veil with a chevron under the mouse or the
/// keyboard's focus (and while the queue is open), a small chevron at its foot on a touch screen, and a glow of the
/// accent while a track plays. It holds still.
class _QueueCover extends StatelessWidget {
  const _QueueCover();

  // It follows the player itself: as a const child it isn't rebuilt with the bar around it.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    final open = player.isQueueOpen;
    return Tooltip(
      message: context.tr('TipQueueToggle'),
      // A remote's arrows and the keyboard reach it too: the queue opens nowhere else on a wide screen. Queued music lands
      // on it.
      child: CoverFlightLanding(
        radius: Radii.medium,
        child: Pressable(
          onPressed: player.toggleQueue,
          builder: (context, lit) => AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: BorderRadius.circular(Radii.medium),
              boxShadow: [
                BoxShadow(
                  color: player.isPlaying ? colors.accent.withValues(alpha: 0.4) : colors.palette.shadow,
                  blurRadius: 18,
                  spreadRadius: -4,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CoverImage(path: player.currentTrack?.coverArtPath, radius: 0, placeholderColor: colors.palette.cyan),
                // A touch screen has no mouse to bring the veil: there a small chevron stays at the cover's foot.
                if (AppPlatform.current.isMobile)
                  AnimatedOpacity(
                    opacity: lit || open ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x8C000000)],
                          stops: [0.45, 1],
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: lit ? 1 : (open ? 0.85 : 0),
                  duration: const Duration(milliseconds: 180),
                  child: ColoredBox(
                    color: const Color(0x8C000000),
                    child: AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_up_rounded, size: 26, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Status line ─────────────────────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final compact = MediaQuery.sizeOf(context).width < WideLayout.compactWidth;
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ListenableBuilder(
          listenable: vm.player,
          builder: (context, _) => Row(
            children: [
              if (vm.player.hasError) ...[
                Icon(Icons.error_outline_rounded, size: 14, color: colors.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    vm.player.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colors.danger),
                  ),
                ),
                Tooltip(
                  message: context.tr('TipDismissError'),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: vm.player.dismissError,
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: Icon(Icons.close_rounded, size: 12, color: colors.textMuted),
                    ),
                  ),
                ),
              ] else ...[
                _PulsingDot(color: colors.palette.success, size: 6, pulsing: vm.player.isPlaying),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    vm.statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colors.textMuted),
                  ),
                ),
              ],
              if (!compact) ...[
                const SizedBox(width: 16),
                Text(vm.rightFooterStatusText, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
