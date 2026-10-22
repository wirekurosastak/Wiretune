// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import 'buttons.dart';
import 'devices.dart';

/// A page's title block: a big title, a line of details, and the page's actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (PhoneChrome.isPhone(context)) return _PhonePageHeader(title: title, subtitle: subtitle, actions: actions);
    return _wide(context);
  }

  Widget _wide(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 20),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 34,
                  height: 1.1,
                  letterSpacing: -1.0,
                  fontWeight: FontWeight.w800,
                  color: colors.textMain,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: colors.textMuted),
                  ),
                ),
            ],
          ),
          if (actions.isNotEmpty)
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
        ],
      ),
    );
  }
}

/// A phone page's header: the title (30 px) and its details, the page's buttons below. The buttons at the top right
/// (the devices, the search and the account) are the top bar's, which stays ([PinnedTitleBar]); a page without one
/// has them here.
class _PhonePageHeader extends StatelessWidget {
  const _PhonePageHeader({required this.title, required this.subtitle, required this.actions});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final buttons = PinnedTitleBar.hasBar(context) ? null : _topButtons(context);
    final titleStyle = TextStyle(
      fontSize: 30,
      letterSpacing: -0.8,
      fontWeight: FontWeight.w800,
      color: colors.textMain,
    );
    final titleRow = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The top bar's, which shrinks it into itself with the scroll.
                  PinnedTitleBar.pageTitle(
                    context,
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                    shrinkStyle: titleStyle,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) _fading(context, subtitle!),
                ],
              ),
            ),
            // The top bar's buttons stand here: the title stops short of them.
            if (buttons == null) SizedBox(width: PinnedTitleBar.buttonSize * _topButtonCount(context)) else ...buttons,
          ],
        ),
      ),
    );
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (actions.isEmpty) PinnedTitleBar.anchor(context, titleRow) else titleRow,
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              // One line as tall as Play, whether the page has it or not, so the lists start at the same place: the
              // round buttons at their size, Play last, the others (the sort first, a genre filter, a new playlist)
              // one height, sharing the rest.
              child: PinnedTitleBar.anchor(
                context,
                SizedBox(
                  height: PhoneChrome.playSize,
                  child: Row(
                    children: [
                      for (final (i, action) in actions.indexed) ...[
                        if (i > 0) const SizedBox(width: 10),
                        if (action is PlayShuffleButtons)
                          action
                        else
                          Expanded(
                            child: SizedBox(height: PhoneChrome.controlHeight, child: action),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tab page's details under its big title: they fade as the title shrinks into the top bar, over them.
Widget _fading(BuildContext context, String text) {
  final line = Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 12, color: context.colors.textMuted),
  );
  final collapse = PinnedTitleBar.collapseOf(context);
  if (collapse == null) return line;
  return ValueListenableBuilder<double>(
    valueListenable: collapse,
    builder: (context, t, child) => Opacity(opacity: (1 - t * 3).clamp(0.0, 1.0), child: child),
    child: line,
  );
}

/// A phone tab page's buttons at the top right: the way to another device (also while nothing plays here, with no mini
/// player then), the search and the account (not on the Settings page: nothing to search there, and the account
/// button leads to it).
List<Widget> _topButtons(BuildContext context) {
  final vm = context.vm;
  final colors = context.colors;
  return [
    const DevicesButton(dimension: PinnedTitleBar.buttonSize, iconSize: 23),
    if (vm.selectedSection != AppSection.settings) ...[
      _searchButton(context),
      SizedBox.square(
        dimension: PinnedTitleBar.buttonSize,
        child: IconButton(
          tooltip: context.tr('NavSettings'),
          onPressed: () => vm.navigateTo(AppSection.settings),
          icon: Icon(
            vm.isUserLoggedIn ? Icons.account_circle : Icons.account_circle_outlined,
            size: 26,
            color: vm.isUserLoggedIn ? colors.textMain : colors.textMuted,
          ),
        ),
      ),
    ],
  ];
}

int _topButtonCount(BuildContext context) => context.vm.selectedSection == AppSection.settings ? 1 : 3;

Widget _searchButton(BuildContext context) => SizedBox.square(
  dimension: PinnedTitleBar.buttonSize,
  child: IconButton(
    tooltip: context.tr('Search'),
    onPressed: context.vm.openSearch,
    icon: Icon(Icons.search_rounded, size: 24, color: context.colors.textMain),
  ),
);

/// On a phone, the bar over the top of a page, as in TIDAL. Its buttons stay at hand however far the page scrolls: a
/// detail page's way back ([onBack]) on the left, the search and the page's [menu] (its ⋮) on the right; a tab page's
/// devices, search and account buttons, which its header leaves to it. As the page's header scrolls away under it, a
/// light shade of the background darkens it from the top. The page's [title] in the header ([pageTitle]) goes up with
/// the page until it reaches the bar, which then takes it over and shrinks it into its own title, gliding it beside
/// the way back (a tab page's big title is there from the start). A title that can't shrink so (on two lines, a
/// playlist's that renames it) fades as it reaches the bar, which then brings the name up into itself. All of it
/// follows the scroll, never moving by itself. Elsewhere [child] alone. The header marks the part whose leaving
/// completes the shade ([anchor]): the line of its buttons, else its title. Choosing the page's section again in the
/// navigation scrolls it back to its top (`MainViewModel.scrollToTopRequested`).
class PinnedTitleBar extends StatefulWidget {
  const PinnedTitleBar({super.key, required this.title, this.onBack, this.menu, required this.child});

  final String title;
  final VoidCallback? onBack;

  /// A detail page's ⋮: the rest of its menu, where a tab page has its account button.
  final Widget? menu;

  /// The page's scroll view.
  final Widget child;

  static const double height = 56;

  /// The bar's buttons, square.
  static const double buttonSize = 44;

  /// How far the shade reaches below the bar, fading out.
  static const double _shadeFade = 40;

  /// The scroll over which a title shrinks into the bar once it has reached it.
  static const double _collapse = 56;

  /// The bar's title, as large as a title ends up in it.
  static const TextStyle _barTitle = TextStyle(fontSize: 17, letterSpacing: -0.3, fontWeight: FontWeight.w800);

  /// [child] (a part of the page's header), marked as the one whose leaving completes the shade when there is a bar.
  static Widget anchor(BuildContext context, Widget child) {
    final key = context.dependOnInheritedWidgetOfExactType<_PinnedTitleBarScope>()?.anchor;
    return key == null ? child : KeyedSubtree(key: key, child: child);
  }

  /// [child], the page's own title in its header, marked for the bar. A title of one line in [shrinkStyle] the bar
  /// takes over once it has reached it, and shrinks (its place in the header left empty meanwhile); another fades as it
  /// reaches the bar, which brings the name up into itself.
  static Widget pageTitle(BuildContext context, Widget child, {TextStyle? shrinkStyle}) {
    final scope = context.dependOnInheritedWidgetOfExactType<_PinnedTitleBarScope>();
    if (scope == null) return child;
    return _TitleMark(
      key: scope.title,
      shrinkStyle: shrinkStyle,
      child: shrinkStyle != null
          ? ValueListenableBuilder<bool>(
              valueListenable: scope.taken,
              builder: (context, taken, child) => Opacity(opacity: taken ? 0 : 1, child: child),
              child: child,
            )
          : ValueListenableBuilder<double>(
              valueListenable: scope.titleIn,
              builder: (context, t, child) => Opacity(opacity: (1 - 2 * t).clamp(0.0, 1.0), child: child),
              child: child,
            ),
    );
  }

  /// How far the page's title has gone into the bar, 0 to 1 (a tab page's details fade with it); null without a bar.
  static ValueListenable<double>? collapseOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_PinnedTitleBarScope>()?.titleIn;

  /// Whether the page has the bar (a phone's page): its header then leaves the bar's buttons to it.
  static bool hasBar(BuildContext context) => context.getInheritedWidgetOfExactType<_PinnedTitleBarScope>() != null;

  @override
  State<PinnedTitleBar> createState() => _PinnedTitleBarState();
}

/// Where a shrinking title stands at the page's top (in the bar's box): its middle's height, its left edge, its size,
/// and the style it has there.
typedef _TitleRest = ({double middle, double left, double width, double height, TextStyle style});

class _PinnedTitleBarState extends State<PinnedTitleBar> {
  final GlobalKey _anchor = GlobalKey();
  final GlobalKey _title = GlobalKey();

  /// How far the shade has come in, 0 to 1.
  double _progress = 0;

  /// How far the title has gone into the bar, 0 to 1: shrinking, or for a title that can't, coming up.
  final ValueNotifier<double> _titleIn = ValueNotifier(0);

  /// Whether the bar draws the title, its place in the header left empty.
  final ValueNotifier<bool> _taken = ValueNotifier(false);

  /// How far the page is scrolled, which moves a title the bar has taken before it shrinks.
  final ValueNotifier<double> _scrolled = ValueNotifier(0);

  /// What the title the bar draws follows.
  late final Listenable _titleMotion = Listenable.merge([_taken, _titleIn, _scrolled]);

  /// Where a shrinking title stands at the page's top; null while unknown, or for a title that doesn't shrink.
  _TitleRest? _rest;

  /// Whether the page's title shrinks into the bar (else it fades over to it).
  bool _shrinks = true;

  /// The least scroll the shade takes to come in, where the header is close under the bar already.
  static const double _minFade = 40;
  late final void Function() _unsubscribe;

  @override
  void initState() {
    super.initState();
    // A page that comes back scrolled (its place is kept) shows the shade and its title at once.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    _unsubscribe = context.vm.scrollToTopRequested.listen((_) => _scrollToTop());
  }

  @override
  void dispose() {
    _unsubscribe();
    _titleIn.dispose();
    _taken.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    final anchor = _anchor.currentContext;
    final position = anchor == null ? null : Scrollable.maybeOf(anchor)?.position;
    if (position == null || position.pixels <= position.minScrollExtent) return;
    unawaited(
      position.animateTo(
        position.minScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  bool _onNotification(Notification notification) {
    if (notification case ScrollNotification(depth: 0) || ScrollMetricsNotification(depth: 0)) _update();
    return false;
  }

  RenderBox? _box(GlobalKey key, RenderBox own) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.attached && own.attached ? box : null;
  }

  /// The left edge of the bar's title: beside the way back, else where the page's own edge is.
  double get _barLeft => widget.onBack == null ? 20 : 4 + PinnedTitleBar.buttonSize;

  /// The middle of the bar, in its box.
  double _barMiddle(BuildContext context) => MediaQuery.paddingOf(context).top + PinnedTitleBar.height / 2;

  /// The scroll at which a shrinking title reaches the bar's middle and starts shrinking: at once for a tab page's,
  /// whose title stands there already.
  double _shrinksAt(_TitleRest rest) => math.max(0, rest.middle - _barMiddle(context));

  /// The scroll at which the bar takes a shrinking title over: as it reaches the shade, which would darken it in the
  /// page, and the bar draws it over its shade. Until it reaches the bar's middle it goes on up with the page.
  double _takenAt(_TitleRest rest) => math.max(
    0,
    rest.middle -
        rest.height / 2 -
        (MediaQuery.paddingOf(context).top + PinnedTitleBar.height + PinnedTitleBar._shadeFade),
  );

  /// The shade comes in with the scroll, from none at the page's top to whole where the anchor's bottom has gone under
  /// the bar (or the page ends). The title shrinks over [PinnedTitleBar._collapse] from where it reaches the bar's
  /// middle; one that doesn't shrink passes over while it goes under the bar's edge.
  void _update() {
    if (!mounted) return;
    final own = context.findRenderObject() as RenderBox?;
    if (own == null) return;
    final anchor = _box(_anchor, own);
    final position = anchor == null ? null : Scrollable.maybeOf(_anchor.currentContext!)?.position;
    final measured = position != null && position.hasPixels && position.hasContentDimensions;
    final scrolled = measured ? math.max(0.0, position.pixels - position.minScrollExtent) : 0.0;
    final edge = MediaQuery.paddingOf(context).top + PinnedTitleBar.height;

    var progress = _progress;
    if (anchor != null) {
      final top = anchor.localToGlobal(Offset.zero, ancestor: own).dy;
      // The scroll from the page's top to where the shade is whole; a short page (an album of a few tracks) that can't
      // scroll so far has it whole at its end.
      final reach = measured ? position.maxScrollExtent - position.minScrollExtent : double.infinity;
      final distance = math.max(math.min(top + anchor.size.height - edge + scrolled, reach), math.min(_minFade, reach));
      progress = distance <= 0 ? 0.0 : (scrolled / distance).clamp(0.0, 1.0);
    }

    final title = _box(_title, own);
    var rest = _rest;
    var shrinks = _shrinks;
    if (title != null) {
      final style = (_title.currentWidget as _TitleMark?)?.shrinkStyle;
      shrinks = style != null;
      if (style != null) {
        final topLeft = title.localToGlobal(Offset.zero, ancestor: own);
        final size = title.size;
        rest = (
          middle: topLeft.dy + size.height / 2 + scrolled,
          left: topLeft.dx,
          width: size.width,
          height: size.height,
          style: style,
        );
      } else {
        rest = null;
      }
    } else if (rest == null && shrinks && scrolled > 0) {
      // Back far down the page, its header not built: the title is wholly the bar's, as it ends up.
      rest = (
        middle: _barMiddle(context),
        left: _barLeft,
        width: double.infinity,
        height: 24,
        style: PinnedTitleBar._barTitle,
      );
    }

    final double titleIn;
    final bool taken;
    if (rest != null) {
      taken = scrolled >= _takenAt(rest);
      titleIn = title == null ? 1.0 : ((scrolled - _shrinksAt(rest)) / PinnedTitleBar._collapse).clamp(0.0, 1.0);
    } else if (title != null) {
      // From its top at the bar's edge to its bottom there: the header's fades over the first half, the bar's comes in
      // over the second.
      final top = title.localToGlobal(Offset.zero, ancestor: own).dy;
      titleIn = ((edge - top) / title.size.height).clamp(0.0, 1.0);
      taken = false;
    } else {
      titleIn = scrolled > 0 ? 1.0 : 0.0;
      taken = false;
    }
    _titleIn.value = titleIn;
    _taken.value = taken;
    _scrolled.value = scrolled;
    if (progress != _progress || rest != _rest || shrinks != _shrinks) {
      setState(() {
        _progress = progress;
        _rest = rest;
        _shrinks = shrinks;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) return widget.child;
    final colors = context.colors;
    final onBack = widget.onBack;
    final background = colors.palette.background;
    final safeTop = MediaQuery.paddingOf(context).top;
    final shadeHeight = safeTop + PinnedTitleBar.height + PinnedTitleBar._shadeFade;
    final rest = _rest;
    final shade = IgnorePointer(
      child: Opacity(
        opacity: _progress,
        child: Container(
          height: shadeHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Light, as TIDAL's, and fading over its whole height, from the screen's top edge down: the page shows
              // through, darkened enough for the title and the buttons.
              colors: [
                for (final alpha in const [0.8, 0.58, 0.36, 0.15, 0.0]) background.withValues(alpha: alpha),
              ],
            ),
          ),
        ),
      ),
    );
    final bar = SafeArea(
      bottom: false,
      child: SizedBox(
        height: PinnedTitleBar.height,
        child: Padding(
          padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 4, 0, 8, 0),
          child: Row(
            children: [
              if (onBack != null)
                SizedBox.square(
                  dimension: PinnedTitleBar.buttonSize,
                  child: IconButton(
                    tooltip: context.tr('Back'),
                    onPressed: onBack,
                    icon: Icon(Icons.arrow_back_rounded, size: 24, color: colors.textMain),
                  ),
                ),
              // A shrinking title is drawn over the bar (below); one that doesn't shrink rises in here.
              Expanded(child: rest != null || _shrinks ? const SizedBox.shrink() : _risingTitle(colors)),
              if (onBack != null) ...[_searchButton(context), ?widget.menu] else ..._topButtons(context),
            ],
          ),
        ),
      ),
    );
    return _PinnedTitleBarScope(
      anchor: _anchor,
      title: _title,
      taken: _taken,
      titleIn: _titleIn,
      child: NotificationListener<Notification>(
        onNotification: _onNotification,
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            Positioned(top: 0, left: 0, right: 0, child: shade),
            Positioned(top: 0, left: 0, right: 0, child: bar),
            if (rest != null) _shrinkingTitle(context, rest),
          ],
        ),
      ),
    );
  }

  /// The title in the bar's own size, rising into it as the header's fades.
  Widget _risingTitle(WiretuneColors colors) => IgnorePointer(
    child: ValueListenableBuilder<double>(
      valueListenable: _titleIn,
      builder: (context, t, child) => Opacity(
        opacity: (2 * t - 1).clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
      ),
      child: Text(
        widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: PinnedTitleBar._barTitle.copyWith(
          color: colors.textMain,
          shadows: [Shadow(color: colors.palette.background.withValues(alpha: 0.8), blurRadius: 12)],
        ),
      ),
    ),
  );

  /// The page's title once the bar has taken it: up with the page to the bar's middle, then from there to the bar's
  /// title beside the way back, shrinking and gliding on the way.
  Widget _shrinkingTitle(BuildContext context, _TitleRest rest) {
    final colors = context.colors;
    final background = colors.palette.background;
    final barMiddle = _barMiddle(context);
    final available =
        MediaQuery.sizeOf(context).width -
        _barLeft -
        8 -
        PinnedTitleBar.buttonSize * (widget.onBack == null ? _topButtonCount(context) : (widget.menu == null ? 1 : 2));
    final start = math.min(rest.middle, barMiddle);
    final end = PinnedTitleBar._barTitle.fontSize! / (rest.style.fontSize ?? PinnedTitleBar._barTitle.fontSize!);
    final shrinksAt = _shrinksAt(rest);
    return ListenableBuilder(
      listenable: _titleMotion,
      builder: (context, _) {
        if (!_taken.value) return const SizedBox.shrink();
        final t = _titleIn.value;
        final scrolled = _scrolled.value;
        final middle = scrolled < shrinksAt ? rest.middle - scrolled : start + (barMiddle - start) * t;
        final scale = 1 - t * (1 - end);
        // As wide as it was in the header at first, as the bar leaves it at the end.
        final width = math.max(0.0, rest.width.isFinite ? rest.width + (available - rest.width) * t : available);
        return Positioned(
          left: rest.left + (_barLeft - rest.left) * t,
          top: middle - rest.height / 2,
          width: width,
          height: rest.height,
          child: IgnorePointer(
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.centerLeft,
              child: OverflowBox(
                minWidth: 0,
                // Laid out wider while smaller, so it is cut short only where it has to be.
                maxWidth: width / scale + 1,
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: rest.style.copyWith(
                    color: colors.textMain,
                    shadows: [Shadow(color: background.withValues(alpha: 0.8 * t), blurRadius: 12)],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The page's title in its header, marked for the bar, with the style it shrinks from (none: it doesn't).
class _TitleMark extends StatelessWidget {
  const _TitleMark({super.key, required this.shrinkStyle, required this.child});

  final TextStyle? shrinkStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _PinnedTitleBarScope extends InheritedWidget {
  const _PinnedTitleBarScope({
    required this.anchor,
    required this.title,
    required this.taken,
    required this.titleIn,
    required super.child,
  });

  final GlobalKey anchor;
  final GlobalKey title;

  /// Whether the bar draws the page's title, its place in the header left empty.
  final ValueListenable<bool> taken;

  /// How far the title has gone into the bar, 0 to 1.
  final ValueListenable<double> titleIn;

  @override
  bool updateShouldNotify(_PinnedTitleBarScope oldWidget) => anchor != oldWidget.anchor;
}

/// Marks the phone layout, whose pages draw the phone's headers and full-width buttons.
class PhoneChrome extends InheritedWidget {
  const PhoneChrome({super.key, required super.child});

  static bool isPhone(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PhoneChrome>() != null;

  /// The height of every button in a phone's page and detail headers but Play (shuffle, the sort, a filter, a
  /// download, the menu), so a line of them is even.
  static const double controlHeight = 44;

  /// A list's Play on a phone: a little larger than the buttons beside it, as in Spotify.
  static const double playSize = 48;

  /// How far from the right edge a phone page's Play is centred: over the ⋮ that ends the rows of its list (the list's
  /// 8 px padding, the row's 8 px and half of the 48 px button).
  static const double playCenterInset = 40;

  /// The room right of a phone page's Play: 16 px, as at every phone page's edges.
  static const double playEndPadding = playCenterInset - playSize / 2;

  @override
  bool updateShouldNotify(PhoneChrome oldWidget) => false;
}

/// A small heading over a group of items ("ALBUMS", "LIBRARY").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 12)});

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w800,
        color: context.colors.textMuted,
      ),
    ),
  );
}

/// A message in place of a list that has nothing to show.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.hint, this.actions = const []});

  final IconData icon;
  final String title;
  final String? hint;

  /// Buttons under the message, side by side (wrapping on a narrow screen).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // Centers the empty state block naturally on the screen.
    // Anchoring to a consistent reference height (260px) guarantees that:
    // 1. Every empty page (Favorites, Playlists, Albums, etc.) has its icon, title and hint at the exact same vertical level.
    // 2. The block sits comfortably in the true visual center of the window instead of sinking towards the bottom.
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight;
        final usableHeight = availableHeight - bottomInset;
        final topSpacing = usableHeight.isFinite ? math.max(20.0, (usableHeight - 260.0) / 2) : 48.0;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(32, topSpacing, 32, 32 + bottomInset),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The icon in an orb of the accent: a soft halo, a glass disc and a thin ring.
                  Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [colors.accent.withValues(alpha: 0.28), colors.accent.withValues(alpha: 0)],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.palette.panel,
                        border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
                        boxShadow: colors.accentGlow(0.8),
                      ),
                      child: Icon(icon, size: 34, color: colors.accent),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: colors.textMain,
                    ),
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      hint!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13.5, height: 1.45, color: colors.textMuted),
                    ),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Wrap(spacing: 12, runSpacing: 10, alignment: WrapAlignment.center, children: actions),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The space at the end of a page: a little air, and the room the phone's floating bars cover.
class PageEndSpace extends StatelessWidget {
  const PageEndSpace({super.key});

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom));
}

/// A rounded card of glass: a faint sheen from its top-left corner and a hairline edge.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding, this.hoverColor, this.opaque = false});

  final Widget child;

  /// The space inside the card: 24 px, 18 on a phone, unless given.
  final EdgeInsets? padding;

  /// The border's colour under the mouse (the section's accent); none keeps it unchanged.
  final Color? hoverColor;

  /// A solid card with the panels' edge (the settings), rather than translucent glass.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(Radii.panel);
    return _HoverBorder(
      hoverColor: hoverColor,
      builder: (border) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: opaque ? colors.palette.modal : null,
          gradient: opaque
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [colors.surface2, colors.surface1, colors.palette.glassBackground],
                  stops: const [0, 0.35, 1],
                ),
        ),
        // A Material, so the ink of the tiles and buttons inside is painted on the card.
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: opaque ? colors.palette.panelBorder : border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding ?? EdgeInsets.all(PhoneChrome.isPhone(context) ? 18 : 24), child: child),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] with the border colour for the mouse's state.
class _HoverBorder extends StatefulWidget {
  const _HoverBorder({required this.hoverColor, required this.builder});

  final Color? hoverColor;
  final Widget Function(Color border) builder;

  @override
  State<_HoverBorder> createState() => _HoverBorderState();
}

class _HoverBorderState extends State<_HoverBorder> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final border = _hover && widget.hoverColor != null ? widget.hoverColor! : context.colors.glassBorder;
    if (widget.hoverColor == null) return widget.builder(border);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(border),
    );
  }
}
