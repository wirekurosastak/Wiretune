// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wiretune_core/wiretune_core.dart' hide RepeatMode;

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/main_view_model.dart';
import '../pages/login_page.dart';
import '../pages/playlists_page.dart';
import '../pages/queue_panel.dart';
import '../pages/search_page.dart';
import '../pages/section_page.dart';
import '../widgets/ambient.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/nav_visualizer.dart';
import '../widgets/player_controls.dart';
import '../widgets/quality_tag.dart';
import '../widgets/spectrum_visualizer.dart';

/// The desktop, tablet and TV layout: the header (logo, search, the mode pills, account, language, theme and, without a
/// system title bar, the window buttons), then floating panels over the ambient backdrop: the sidebar, the page and the
/// player bar, with the status line under them.
class WideLayout extends StatelessWidget {
  const WideLayout({super.key});

  /// The space between the floating panels and around them.
  static const double gap = 10;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Material(
      color: colors.palette.background,
      child: ListenableBuilder(
        listenable: vm,
        builder: (context, _) => Stack(
          children: [
            const Positioned.fill(child: AmbientBackdrop()),
            Column(
              children: [
                const _Header(),
                if (vm.isServerOfflineBannerVisible) const _OfflineBanner(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: gap),
                    child: Row(
                      children: [
                        const _Sidebar(),
                        const SizedBox(width: gap),
                        Expanded(
                          child: _Panel(
                            child: FocusTraversalGroup(child: _Content(vm: vm)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: gap),
                const _PlayerBar(),
                const _Footer(),
              ],
            ),
            const PlaylistDialogsLayer(),
            if (vm.isLoginViewActive) const Positioned.fill(child: LoginPage()),
          ],
        ),
      ),
    );
  }
}

/// A floating panel: rounded, translucent over the backdrop, with a hairline edge; what scrolls inside is clipped to it.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(Radii.panel);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.palette.panel,
        borderRadius: radius,
        border: Border.all(color: colors.glassBorder),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}

/// The page of the selected section, or the search results, or the queue.
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
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(animation),
            child: ScaleTransition(scale: Tween(begin: 0.99, end: 1.0).animate(animation), child: child),
          ),
        ),
        child: page,
      );
    },
  );
}

// ── Header ──────────────────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final compact = MediaQuery.sizeOf(context).width < MainViewModel.compactLayoutWidth;
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
                  listenable: vm.player,
                  builder: (context, _) => Tooltip(
                    message: 'Wiretune Streamer Visualizer',
                    child: NavVisualizer(
                      waveTrigger: vm.waveTrigger,
                      direction: vm.lastWaveDirection,
                      color: colors.accent,
                      isPlaying: vm.player.isPlaying,
                    ),
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
                _HeaderPills(compact: compact),
                if (frameless) ...[const SizedBox(width: 10), const _WindowButtons()],
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

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    final radius = BorderRadius.circular(999);
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
          onChanged: (text) => vm.searchQuery = text,
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 14, color: colors.textMain),
          decoration: InputDecoration(
            hintText: context.tr('SearchPlaceholder'),
            filled: true,
            fillColor: focused ? colors.palette.modal : (_hover ? colors.surface2 : colors.surface1),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Icon(Icons.search_rounded, size: 19, color: focused ? colors.accent : colors.textMuted),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 42),
            suffixIcon: vm.isSearchActive
                ? IconButton(
                    tooltip: context.tr('TipClearSearch'),
                    onPressed: vm.clearSearch,
                    iconSize: 16,
                    icon: Icon(Icons.cancel_rounded, color: colors.textMuted),
                  )
                : null,
            contentPadding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
            border: border(colors.glassBorder, 1),
            enabledBorder: border(_hover ? colors.palette.glassHighlight : colors.glassBorder, 1),
            focusedBorder: border(colors.accent, 1.5),
          ),
        ),
      ),
    );
  }
}

/// A header pill: 32 px high and fully rounded, on the glass; an active mode is tinted with its colour and glows.
class _Pill extends StatelessWidget {
  const _Pill({required this.child, required this.onPressed, required this.tooltip, this.activeColor});

  final Widget child;
  final VoidCallback? onPressed;
  final String tooltip;

  /// The mode's colour when the mode is on; null for an inactive or a plain pill.
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = activeColor;
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: active == null
              ? const []
              : [BoxShadow(color: active.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: -3)],
        ),
        child: Material(
          color: active != null ? active.withValues(alpha: 0.16) : colors.surface1,
          shape: StadiumBorder(side: BorderSide(color: active?.withValues(alpha: 0.7) ?? colors.glassBorder)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderPills extends StatelessWidget {
  const _HeaderPills({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: vm.player,
      builder: (context, _) {
        final player = vm.player;
        Widget modePill(String label, bool on, Color color, VoidCallback onTap, String tip) => _Pill(
          tooltip: context.tr(tip),
          activeColor: on ? color : null,
          onPressed: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A status light, dim while the mode is off: the pill keeps its width, so nothing beside it moves.
              if (on)
                _PulsingDot(color: color, size: 7)
              else
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: colors.textMuted.withValues(alpha: 0.35), shape: BoxShape.circle),
                ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w800,
                  color: on ? color : colors.textMuted,
                ),
              ),
            ],
          ),
        );
        // The mode pills exist where the modes do: on a desktop, outside the compact layout, and not while the player
        // shows another device (the modes are this one's).
        final modes = !compact && AppPlatform.current.isDesktop && !player.isRemote;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (modes) ...[
              const SizedBox(width: 16),
              modePill(
                'BIT-PERFECT',
                player.isBitperfect,
                colors.palette.purple,
                player.toggleBitperfect,
                'TipBitPerfect',
              ),
              const SizedBox(width: 8),
              modePill(
                'EXCLUSIVE',
                player.isExclusiveMode,
                colors.palette.lime,
                player.toggleExclusiveMode,
                'TipExclusive',
              ),
              const SizedBox(width: 8),
            ] else
              const SizedBox(width: 16),
            _Pill(
              tooltip: context.tr('TipAccount'),
              onPressed: vm.showLoginScreen,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    vm.isUserLoggedIn ? Icons.account_circle_rounded : Icons.key_rounded,
                    size: 17,
                    color: vm.isUserLoggedIn ? colors.palette.cyan : colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    vm.currentUserBadge,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colors.textMain),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: context.tr('TipLanguage'),
              onSelected: vm.changeLanguage,
              position: PopupMenuPosition.under,
              itemBuilder: (context) => [
                for (final l in Localizer.languages)
                  CheckedPopupMenuItem(value: l.code, checked: l.code == vm.language, child: Text(l.nativeName)),
              ],
              child: IgnorePointer(
                child: _Pill(
                  tooltip: context.tr('TipLanguage'),
                  onPressed: () {},
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.translate_rounded, size: 16, color: colors.palette.cyan),
                      const SizedBox(width: 6),
                      Text(
                        vm.languageBadge,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colors.textMain),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: context.tr('TipToggleTheme'),
              onPressed: vm.toggleTheme,
              iconSize: 20,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, animation) => RotationTransition(
                  turns: Tween(
                    begin: 0.6,
                    end: 1.0,
                  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Icon(
                  vm.isLight ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  key: ValueKey(vm.isLight),
                  color: vm.isLight ? colors.palette.purple : colors.palette.warning,
                ),
              ),
            ),
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
        tooltip: context.tr('TipMaximize'),
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

/// A small dot that slowly fades in and out (the "live" mark of an active mode and of the status line); a steady one on
/// a phone or tablet.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.size});

  final Color color;
  final double size;

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
    if (!AppPlatform.current.isMobile) _controller.repeat(reverse: true);
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
          Icon(Icons.cloud_off_rounded, color: colors.danger, size: 20),
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
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: vm.retryConnectServer,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(context.tr('Reconnect'), style: const TextStyle(fontSize: 12)),
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
    final compact = MediaQuery.sizeOf(context).width < MainViewModel.compactLayoutWidth;
    return SizedBox(
      width: compact ? 68 : 232,
      child: _Panel(
        child: ListenableBuilder(
          listenable: Listenable.merge([vm, vm.serverSettings, vm.player]),
          builder: (context, _) {
            final stats = vm.serverSettings;
            Widget item(
              AppSection section,
              IconData icon,
              Color color,
              String label,
              int? count, {
              bool autofocus = false,
            }) => _SidebarItem(
              selected: vm.selectedSection == section && !vm.isSearchActive && !vm.player.isQueueOpen,
              icon: icon,
              color: color,
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
                    Icons.person_rounded,
                    palette.coral,
                    context.tr('NavArtists'),
                    stats.totalArtistsCount,
                    autofocus: AppPlatform.current.isTv,
                  ),
                  item(AppSection.albums, Icons.album, palette.purple, context.tr('NavAlbums'), stats.totalAlbumsCount),
                  item(
                    AppSection.tracks,
                    Icons.music_note_rounded,
                    palette.cyan,
                    context.tr('NavTracks'),
                    stats.totalTracksCount,
                  ),
                  const SizedBox(height: 22),
                  if (!compact) _GroupTitle(context.tr('SectionCollection')),
                  item(
                    AppSection.favorites,
                    Icons.favorite_rounded,
                    palette.coral,
                    context.tr('NavFavorites'),
                    stats.totalFavoritesCount,
                  ),
                  item(
                    AppSection.playlists,
                    Icons.queue_music_rounded,
                    palette.lime,
                    context.tr('NavPlaylists'),
                    stats.totalPlaylistsCount,
                  ),
                  const SizedBox(height: 22),
                  if (!compact) _GroupTitle(context.tr('SectionSettings')),
                  item(AppSection.settings, Icons.tune_rounded, palette.cyan, context.tr('NavSettings'), null),
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
    final tile = AnimatedScale(
      scale: _hover && !selected ? 1.08 : 1,
      duration: duration,
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
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
              borderRadius: BorderRadius.circular(Radii.card),
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
                borderRadius: BorderRadius.circular(Radii.card),
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
    final compact = width < MainViewModel.compactLayoutWidth;
    // A 540 px middle, narrower when the window is (its two sides keep at least 180 px each).
    final centerWidth = math.min(540.0, math.max(300.0, width - 64 - 2 * 280));
    return Container(
      // The controls and the times grow with the user's font size; the bar grows with them.
      height: 80 + MediaQuery.textScalerOf(context).scale(16),
      margin: const EdgeInsets.symmetric(horizontal: WideLayout.gap),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.palette.panel,
        borderRadius: BorderRadius.circular(Radii.panel + 2),
        border: Border.all(color: colors.glassBorder),
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
                    _QueueCover(),
                    const SizedBox(width: 14),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 190),
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
                            else
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: track == null ? null : () => vm.openArtistByName(track.artist),
                                child: Text(
                                  player.nowPlayingArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                                ),
                              ),
                            if (player.isRemote) ...[const SizedBox(height: 3), const PlayingOnLabel(fontSize: 11)],
                          ],
                        ),
                      ),
                    ),
                    if (track != null) ...[const SizedBox(width: 4), const FavoriteCurrentButton(size: 19)],
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
                    // Spectrum, quality and volume, as many as fit: the volume first, then the full quality tag (the
                    // short one when the full one doesn't fit), then the spectrum in what is left, down to 80 px.
                    final scale = MediaQuery.textScalerOf(context).scale(1);
                    // The devices button (while there are other devices to reach) takes its place first.
                    final devices = player.canReachDevices || player.isRemote;
                    final volume = platform.isDesktop && constraints.maxWidth >= 12 + 36 + 8 + 95;
                    var room = constraints.maxWidth - 12 - (volume ? 36 + 8 + 95 : 0) - (devices ? 40 : 0);
                    final showTag = !compact && track != null && room >= 90 * scale;
                    final fullTag = showTag && room >= 125 * scale;
                    if (showTag) room -= (fullTag ? 125 : 90) * scale + 8;
                    final spectrumWidth = math.min(130.0, room - 14);
                    final showSpectrum = !compact && platform.isDesktop && spectrumWidth >= 80;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (showSpectrum) ...[
                            Tooltip(
                              message: context.tr('TipSpectrum'),
                              child: SpectrumVisualizer(
                                bands: player.spectrum,
                                color: colors.accent,
                                highlight: colors.hover,
                                width: spectrumWidth,
                              ),
                            ),
                            const SizedBox(width: 14),
                          ],
                          if (showTag) ...[
                            Flexible(
                              child: QualityTag(
                                tier: player.currentTier,
                                spec: player.currentTagSpec,
                                compact: !fullTag,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (devices) const DevicesButton(iconSize: 19, dimension: 40),
                          if (volume) const VolumeControl(sliderWidth: 95),
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

/// The cover of the current track, which opens and closes the queue: a dark veil with a chevron under the mouse (and
/// while the queue is open), and a glow of the accent while a track plays, with a slow "breath" (not on a phone or
/// tablet).
class _QueueCover extends StatefulWidget {
  @override
  State<_QueueCover> createState() => _QueueCoverState();
}

class _QueueCoverState extends State<_QueueCover> with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    final open = player.isQueueOpen;
    final breathe = player.isPlaying && !AppPlatform.current.isMobile;
    if (breathe && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!breathe && _breath.isAnimating) {
      _breath.animateTo(0, duration: const Duration(milliseconds: 400));
    }
    return Tooltip(
      message: context.tr('TipQueueToggle'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: player.toggleQueue,
          child: ScaleTransition(
            scale: Tween(begin: 1.0, end: 1.05).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: colors.surface2,
                borderRadius: BorderRadius.circular(12),
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
                  AnimatedOpacity(
                    opacity: _hover ? 1 : (open ? 0.85 : 0),
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
    final compact = MediaQuery.sizeOf(context).width < MainViewModel.compactLayoutWidth;
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
                _PulsingDot(color: colors.palette.success, size: 6),
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
