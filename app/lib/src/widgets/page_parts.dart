// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

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

/// A sliver built for the width it is laid out in. A [SliverLayoutBuilder]'s constraints carry the scroll, so it builds
/// again at every step of it (every row of a table, every tile of a grid, at every frame); this one only when the width
/// changes, or when it is rebuilt itself.
class SliverWidthBuilder extends StatefulWidget {
  const SliverWidthBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, double width) builder;

  @override
  State<SliverWidthBuilder> createState() => _SliverWidthBuilderState();
}

class _SliverWidthBuilderState extends State<SliverWidthBuilder> {
  double? _width;
  Widget? _sliver;

  @override
  void didUpdateWidget(SliverWidthBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sliver = null;
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      if (width != _width || _sliver == null) {
        _width = width;
        // In a context of its own, which what it looks up (the theme, the phone's chrome) rebuilds when that changes.
        _sliver = Builder(builder: (context) => widget.builder(context, width));
      }
      return _sliver!;
    },
  );
}

/// A tab page (Albums, Artists, Tracks, Favorites, Playlists): its [header] over its list. On a phone the header scrolls
/// with the list and the top bar takes its title over ([PinnedTitleBar]); elsewhere it stays put above the list, as do
/// [columnHeaders] (a table's, [TrackColumnHeaders]) under it, and only the list scrolls. A short page (a TV's) leaves
/// the list the room: there they scroll with it.
class TabPageList extends StatelessWidget {
  const TabPageList({
    super.key,
    required this.title,
    required this.storageKey,
    required this.header,
    this.columnHeaders,
    required this.slivers,
  });

  final String title;

  /// Keeps the list's place while another tab is on show.
  final String storageKey;
  final Widget header;
  final Widget? columnHeaders;
  final List<Widget> slivers;

  /// The page's height from which the header stays put.
  static const double _headerStaysFrom = 520;

  @override
  Widget build(BuildContext context) {
    final phone = PhoneChrome.isPhone(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final apart = !phone && constraints.maxHeight >= _headerStaysFrom;
        final columnHeaders = phone ? null : this.columnHeaders;
        final list = CustomScrollView(
          key: PageStorageKey(storageKey),
          slivers: [
            if (!apart) ...[
              SliverToBoxAdapter(child: header),
              if (columnHeaders != null) SliverToBoxAdapter(child: columnHeaders),
            ],
            ...slivers,
          ],
        );
        // Elsewhere the bar is the page alone, but still brings it back to its top.
        return PinnedTitleBar(
          title: title,
          child: phone || !apart
              ? list
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    ?columnHeaders,
                    Expanded(child: _TopFade(child: list)),
                  ],
                ),
        );
      },
    );
  }
}

/// The top edge of a list under a header that stays: once the list has scrolled, what goes under it fades out, as at
/// the page's bottom edge; at the list's top nothing does, nor while a table's headers are pinned there
/// ([PinnedColumnHeaders]), under which its rows fade instead.
class _TopFade extends StatefulWidget {
  const _TopFade({this.top = 0, required this.child});

  /// What stands over the list's top (a row of its own): what scrolls under it goes, and the fade is below it.
  final double top;
  final Widget child;

  static const double height = 24;

  @override
  State<_TopFade> createState() => _TopFadeState();
}

class _TopFadeState extends State<_TopFade> {
  /// How much of the fade is there, 0 to 1: it comes in over the first [_TopFade.height] of the scroll; and how much of
  /// it is left below [_TopFade.top] by the tables' headers pinned there.
  final ValueNotifier<(double, double)> _shown = ValueNotifier((0, 1));

  /// The tables' headers in the list, which take the edge over once they reach it.
  final Set<_PinnedColumnHeadersState> _pinned = {};

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  // The metrics' also tell where a list brought back to its place starts.
  bool _onScroll(Notification notification) {
    final (depth, metrics) = switch (notification) {
      ScrollNotification(:final depth, :final metrics) => (depth, metrics),
      ScrollMetricsNotification(:final depth, :final metrics) => (depth, metrics),
      _ => (-1, null),
    };
    if (depth == 0 && metrics != null) {
      final scrolled = metrics.pixels - metrics.minScrollExtent;
      var below = 1.0;
      for (final headers in _pinned) {
        // Gone as they reach the edge, so as not to fade them.
        if (headers.pinsAt case final pinsAt?) {
          final distance = pinsAt - metrics.minScrollExtent - widget.top - scrolled;
          below = math.min(below, (distance / _TopFade.height).clamp(0.0, 1.0));
        }
      }
      _shown.value = ((scrolled / _TopFade.height).clamp(0.0, 1.0), below);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<Notification>(
      onNotification: _onScroll,
      child: _TopFadeScope(
        state: this,
        child: ValueListenableBuilder<(double, double)>(
          valueListenable: _shown,
          builder: (context, shown, child) => ShaderMask(
            shaderCallback: (rect) {
              final (t, below) = shown;
              final top = (widget.top / rect.height).clamp(0.0, 1.0);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 1 - t),
                  Colors.black.withValues(alpha: 1 - t),
                  Colors.black.withValues(alpha: 1 - t * below),
                  Colors.black,
                ],
                stops: [0, top, top, ((widget.top + _TopFade.height) / rect.height).clamp(top, 1.0)],
              ).createShader(rect);
            },
            blendMode: BlendMode.dstIn,
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _TopFadeScope extends InheritedWidget {
  const _TopFadeScope({required this.state, required super.child});

  final _TopFadeState state;

  @override
  bool updateShouldNotify(_TopFadeScope oldWidget) => state != oldWidget.state;
}

/// A table's column headers over its [rows], as slivers: once they reach the top of the list they stay there while
/// the rows go on under them, fading out below them as at the list's edge; at the table's end they go up with it.
class PinnedColumnHeaders extends StatefulWidget {
  const PinnedColumnHeaders({super.key, required this.headers, required this.rows});

  final Widget headers;
  final Widget rows;

  @override
  State<PinnedColumnHeaders> createState() => _PinnedColumnHeadersState();
}

class _PinnedColumnHeadersState extends State<PinnedColumnHeaders> {
  final GlobalKey _headers = GlobalKey();
  _TopFadeState? _fade;

  /// The scroll at which the headers reach the top of the list; null before they are laid out.
  double? get pinsAt {
    final sliver = _headers.currentContext?.findRenderObject() as RenderSliver?;
    if (sliver == null || !sliver.attached || sliver.geometry == null) return null;
    return sliver.constraints.precedingScrollExtent;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fade = context.getInheritedWidgetOfExactType<_TopFadeScope>()?.state;
    if (fade == _fade) return;
    _fade?._pinned.remove(this);
    _fade = fade?.._pinned.add(this);
  }

  @override
  void dispose() {
    _fade?._pinned.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      PinnedHeaderSliver(key: _headers, child: widget.headers),
      _FadeUnder(sliver: widget.rows),
    ],
  );
}

/// [sliver], fading out where something pinned over it covers it (its overlap), and below that over [_TopFade.height].
class _FadeUnder extends SingleChildRenderObjectWidget {
  const _FadeUnder({required Widget sliver}) : super(child: sliver);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFadeUnder();
}

class _RenderFadeUnder extends RenderProxySliver {
  double _overlap = 0;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void performLayout() {
    super.performLayout();
    if (constraints.overlap != _overlap) {
      _overlap = constraints.overlap;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !geometry!.visible) return;
    final height = geometry!.paintExtent;
    if (_overlap <= 0 || height <= 0 || constraints.axis != Axis.vertical) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    final size = Size(constraints.crossAxisExtent, height);
    // Wholly under what covers it; from there coming in, the fade growing as it slides under.
    final covered = (_overlap / height).clamp(0.0, 1.0);
    final clear = ((_overlap + _TopFade.height) / height).clamp(covered, 1.0);
    final start = 1 - (_overlap / _TopFade.height).clamp(0.0, 1.0);
    final mask = (layer as ShaderMaskLayer?) ?? ShaderMaskLayer();
    mask
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.transparent,
          Colors.black.withValues(alpha: start),
          Colors.black,
        ],
        stops: [0, covered, covered, clear],
      ).createShader(Offset.zero & size)
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    layer = mask;
    context.pushLayer(mask, (context, offset) => context.paintChild(child, offset), offset);
  }
}

/// A computer's or a tablet's detail page: a row over its list with the way back, beside which the page's title ends
/// up, as in the phone's bar. A title of one line (marked by [PinnedTitleBar.pageTitle]) is taken over by the row as it
/// reaches the list's top edge, goes on up with the page to the row's middle, and from there shrinks and glides in
/// beside the way back; a longer one goes under the edge, and the row's own comes in meanwhile. The row stays over the
/// list, which scrolls under it, fading out there ([_TopFade]). All of it follows the scroll.
class _WideBackBar extends StatefulWidget {
  const _WideBackBar({required this.title, required this.onBack, required this.backText, required this.child});

  final String title;
  final VoidCallback onBack;
  final String? backText;
  final Widget child;

  @override
  State<_WideBackBar> createState() => _WideBackBarState();
}

class _WideBackBarState extends State<_WideBackBar> {
  final GlobalKey _title = GlobalKey();

  /// The list's scroll from its top.
  final ValueNotifier<double> _scrolled = ValueNotifier(0);

  /// Whether the row has taken the header's title over (it is hidden in the header meanwhile).
  final ValueNotifier<bool> _taken = ValueNotifier(false);

  /// How far a title that doesn't shrink has gone under the list's edge, 0 to 1: the row's comes in with it.
  final ValueNotifier<double> _titleIn = ValueNotifier(0);
  late final Listenable _titleMotion = Listenable.merge([_scrolled, _taken]);

  /// Where a shrinking title stands at the list's top, in this box; null while unknown, or for one that doesn't.
  _TitleRest? _rest;

  /// The top of a title that doesn't shrink at the list's top, as last measured.
  double? _fadingTitleTop;
  bool _measureScheduled = false;

  /// The row's title: its left edge (beside the way back), its middle and its size.
  static const double _rowTop = 8, _left = 20, _right = 30;
  static const double _titleLeft = _left + PinnedTitleBar.buttonSize + 8;
  static const double _titleMiddle = _rowTop + (PinnedTitleBar.height - _rowTop) / 2;
  static const TextStyle _rowTitle = TextStyle(fontSize: 20, letterSpacing: -0.4, fontWeight: FontWeight.w800);

  @override
  void dispose() {
    _scrolled.dispose();
    _taken.dispose();
    _titleIn.dispose();
    super.dispose();
  }

  bool _onScroll(Notification notification) {
    if (notification case ScrollNotification(depth: 0, :final metrics)) {
      // The list has scrolled but isn't laid out there yet: the title follows the scroll now, and is measured once it
      // is (measured in between it would be off by the step, and jitter).
      _update(metrics, measure: false);
      if (!_measureScheduled) {
        _measureScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measureScheduled = false;
          _update(metrics);
        });
      }
    }
    if (notification case ScrollMetricsNotification(depth: 0, :final metrics)) _update(metrics);
    return false;
  }

  void _update(ScrollMetrics metrics, {bool measure = true}) {
    if (!mounted) return;
    final own = context.findRenderObject() as RenderBox?;
    if (own == null || !own.attached) return;
    final offset = math.max(0.0, metrics.pixels - metrics.minScrollExtent);
    final box = _title.currentContext?.findRenderObject() as RenderBox?;
    final title = box != null && box.attached && box.hasSize ? box : null;
    var rest = _rest;
    var titleIn = _titleIn.value;
    if (title != null) {
      final style = (_title.currentWidget as _TitleMark?)?.shrinkStyle;
      final topLeft = title.localToGlobal(Offset.zero, ancestor: own);
      if (style == null) {
        rest = null;
        if (measure || _fadingTitleTop == null) _fadingTitleTop = topLeft.dy + offset;
        final top = _fadingTitleTop! - offset;
        titleIn = ((PinnedTitleBar.height - top) / title.size.height).clamp(0.0, 1.0);
      } else if (measure) {
        rest = (
          middle: topLeft.dy + title.size.height / 2 + offset,
          left: topLeft.dx,
          width: title.size.width,
          height: title.size.height,
          style: style,
        );
      }
    } else if (rest == null) {
      // Far down the page, its header not built: the row's title is there whole.
      titleIn = offset > 0 ? 1.0 : 0.0;
    }
    _scrolled.value = offset;
    _titleIn.value = titleIn;
    // Taken as it reaches the list's edge, where it would go under the fade.
    _taken.value = rest != null && offset >= rest.middle - rest.height / 2 - PinnedTitleBar.height - _TopFade.height;
    if (rest != _rest) setState(() => _rest = rest);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rest = _rest;
    return Stack(
      children: [
        // The list reaches under the row (its first sliver keeps the room, [PinnedTitleBar.room]), so that nothing in
        // its header is cut at the row's edge (the artwork's glow); scrolled, what goes under the row fades out.
        Positioned.fill(
          child: NotificationListener<Notification>(
            onNotification: _onScroll,
            child: _TopFade(
              top: PinnedTitleBar.height,
              child: _WideBackBarScope(title: _title, taken: _taken, child: widget.child),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SizedBox(
            height: PinnedTitleBar.height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_left, _rowTop, _right, 0),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: PinnedTitleBar.buttonSize,
                    child: IconButton(
                      tooltip: widget.backText ?? context.tr('Back'),
                      onPressed: widget.onBack,
                      icon: Icon(Icons.arrow_back_rounded, size: 24, color: colors.textMain),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // A shrinking title is drawn over the row (below); one that doesn't comes in here.
                  Expanded(
                    child: rest != null
                        ? const SizedBox.shrink()
                        : ValueListenableBuilder<double>(
                            valueListenable: _titleIn,
                            builder: (context, t, child) => Opacity(
                              opacity: t,
                              child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
                            ),
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _rowTitle.copyWith(color: colors.textMain),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (rest != null) _shrinkingTitle(rest),
      ],
    );
  }

  /// The header's title once the row has taken it: up with the page to the row's middle, then shrinking and gliding
  /// from there to beside the way back.
  Widget _shrinkingTitle(_TitleRest rest) {
    final colors = context.colors;
    final end = _rowTitle.fontSize! / (rest.style.fontSize ?? _rowTitle.fontSize!);
    final shrinksAt = math.max(0.0, rest.middle - _titleMiddle);
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = math.max(0.0, constraints.maxWidth - _titleLeft - _right);
          return ListenableBuilder(
            listenable: _titleMotion,
            builder: (context, _) {
              if (!_taken.value) return const SizedBox.shrink();
              final scrolled = _scrolled.value;
              final t = ((scrolled - shrinksAt) / PinnedTitleBar._collapse).clamp(0.0, 1.0);
              final middle = scrolled < shrinksAt ? rest.middle - scrolled : _titleMiddle;
              final scale = 1 - t * (1 - end);
              final width = rest.width + (available - rest.width) * t;
              return Stack(
                children: [
                  Positioned(
                    left: rest.left + (_titleLeft - rest.left) * t,
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
                            style: rest.style.copyWith(color: colors.textMain),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _RowRoom extends StatelessWidget {
  const _RowRoom();

  @override
  Widget build(BuildContext context) => context.getInheritedWidgetOfExactType<_WideBackBarScope>() == null
      ? const SliverToBoxAdapter()
      : const PinnedHeaderSliver(
          child: AbsorbPointer(child: SizedBox(height: PinnedTitleBar.height)),
        );
}

/// Where a wide detail page's title is, and whether its row has taken it over ([_WideBackBar]).
class _WideBackBarScope extends InheritedWidget {
  const _WideBackBarScope({required this.title, required this.taken, required super.child});

  final GlobalKey title;
  final ValueListenable<bool> taken;

  @override
  bool updateShouldNotify(_WideBackBarScope oldWidget) => title != oldWidget.title || taken != oldWidget.taken;
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
List<Widget> _topButtons(BuildContext context, {ValueListenable<double>? pullIn}) {
  final vm = context.vm;
  final colors = context.colors;
  const devices = DevicesButton(dimension: PinnedTitleBar.buttonSize, iconSize: 23);
  return [
    if (pullIn == null)
      devices
    else
      // While the page is pulled towards the search, the cast button moves into the search's place.
      ValueListenableBuilder<double>(
        valueListenable: pullIn,
        builder: (context, t, child) => Transform.translate(
          offset: Offset(PinnedTitleBar.buttonSize * Curves.easeOut.transform(t), 0),
          child: child,
        ),
        child: devices,
      ),
    if (vm.selectedSection != AppSection.settings) ...[
      if (pullIn == null)
        _searchButton(context)
      else
        // ... which leaves it for the middle, where letting go opens it.
        ValueListenableBuilder<double>(
          valueListenable: pullIn,
          builder: (context, t, child) => Opacity(
            opacity: (1 - 2 * t).clamp(0.0, 1.0),
            child: Transform.scale(scale: 1 - 0.4 * t, child: child),
          ),
          child: _searchButton(context),
        ),
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
  child: Builder(
    builder: (button) => IconButton(
      tooltip: context.tr('Search'),
      onPressed: () {
        // The field grows out of this button.
        final box = button.findRenderObject() as RenderBox?;
        PinnedTitleBar.searchFrom = box == null || !box.attached ? null : box.localToGlobal(Offset.zero) & box.size;
        context.vm.openSearch();
      },
      icon: Icon(Icons.search_rounded, size: 24, color: context.colors.textMain),
    ),
  ),
);

/// On a phone, the bar over the top of a page, as in TIDAL. Its buttons stay at hand however far the page scrolls: a
/// detail page's way back ([onBack]) on the left, the search and the page's [menu] (its ⋮) on the right; a tab page's
/// devices, search and account buttons, which its header leaves to it. As the page's header scrolls away under it, a
/// light shade of the background darkens it from the top. The page's [title] in the header ([pageTitle]) goes up with
/// the page until it reaches the bar, which then takes it over and shrinks it into its own title, gliding it beside
/// the way back (a tab page's big title is there from the start). A title that can't shrink so (on two lines, a
/// playlist's that renames it) fades as it reaches the bar, which then brings the name up into itself. All of it
/// follows the scroll, never moving by itself. Elsewhere a detail page has a row of its own over its list, with the way
/// back, into which its title goes the same way ([_WideBackBar]); a tab page is [child] alone (its header stays,
/// [TabPageList]). The header marks the part whose leaving completes the shade ([anchor]): the line of its buttons, else
/// its title. Choosing the page's section again in the navigation scrolls it back to its top
/// (`MainViewModel.scrollToTopRequested`).
class PinnedTitleBar extends StatefulWidget {
  const PinnedTitleBar({super.key, required this.title, this.onBack, this.backText, this.menu, required this.child});

  final String title;
  final VoidCallback? onBack;

  /// Where [onBack] leads (the section, the artist, the search): the tooltip of the way back over a wide page.
  final String? backText;

  /// A detail page's ⋮: the rest of its menu, where a tab page has its account button.
  final Widget? menu;

  /// The page's scroll view.
  final Widget child;

  static const double height = 56;

  /// The bar's buttons, square.
  static const double buttonSize = 44;

  /// Where on the screen the search was opened from (its button, or the one a pull brought out): the search field
  /// grows out of it, and goes back into it. Taken by the field as it opens.
  static Rect? searchFrom;

  /// How far the shade reaches below the bar, fading out.
  static const double _shadeFade = 40;

  /// The scroll over which a title shrinks into the bar once it has reached it.
  static const double _collapse = 56;

  /// The bar's title, as large as a title ends up in it.
  static const TextStyle _barTitle = TextStyle(fontSize: 17, letterSpacing: -0.3, fontWeight: FontWeight.w800);

  /// The page's first sliver: over a computer's or a tablet's detail page, the room its row of the way back stands
  /// in, which stays (a table's headers pin under it) and takes the pointer there; elsewhere nothing.
  static const Widget room = _RowRoom();

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
    if (scope == null) {
      final wide = context.dependOnInheritedWidgetOfExactType<_WideBackBarScope>();
      if (wide == null) return child;
      return _TitleMark(
        key: wide.title,
        shrinkStyle: shrinkStyle,
        child: shrinkStyle == null
            ? child
            : ValueListenableBuilder<bool>(
                valueListenable: wide.taken,
                builder: (context, taken, child) => Opacity(opacity: taken ? 0 : 1, child: child),
                child: child,
              ),
      );
    }
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

  /// How far the page is scrolled (below 0 while it is pulled down past its top), which moves a title the bar has taken
  /// before it shrinks.
  final ValueNotifier<double> _scrolled = ValueNotifier(0);

  /// How far a tab page is pulled down past its top towards opening the search, 0 to 1: the bar's search gives its
  /// place to the cast button and comes out in the middle.
  final ValueNotifier<double> _pullIn = ValueNotifier(0);

  /// While a tab page is pulled down past its top: how far the finger pulled it before it let go.
  double _pulled = 0;
  bool _dragging = false;

  /// How far a tab page is pulled down past its top for search to open when the finger lets go.
  static const double _pullToSearch = 88;

  /// The search that comes out in the bar's middle as the page is pulled, across.
  static const double _pullHintSize = 40;

  /// What the title the bar draws follows.
  late final Listenable _titleMotion = Listenable.merge([_taken, _titleIn, _scrolled]);

  /// Where a shrinking title stands at the page's top; null while unknown, or for a title that doesn't shrink.
  _TitleRest? _rest;

  /// Whether the page's title shrinks into the bar (else it fades over to it).
  bool _shrinks = true;

  /// The scroll over which the shade comes in, and the top of a title that doesn't shrink in the page, as last
  /// measured.
  double? _shadeDistance, _fadingTitleTop;

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
    _pullIn.dispose();
    super.dispose();
  }

  /// The page's list: the first one under it that scrolls up and down (its header's may scroll sideways).
  ScrollPosition? _listPosition() {
    ScrollableState? list;
    void visit(Element element) {
      if (list != null) return;
      if (element is StatefulElement) {
        if (element.state case final ScrollableState scrollable
            when axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical) {
          list = scrollable;
          return;
        }
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return list?.position;
  }

  // Found from here, not from the header: far down the page the header isn't built, and a computer's has none marked.
  void _scrollToTop() {
    final position = _listPosition();
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
    if (notification case ScrollNotification(depth: 0)) {
      // The page has scrolled but isn't laid out there yet: what follows the scroll follows it now, and the header is
      // measured once it is.
      _update(measure: false);
      _measureAfterLayout();
    }
    if (notification case ScrollMetricsNotification(depth: 0)) _update();
    if (notification case ScrollUpdateNotification(depth: 0) when _pullSearches) _pullOnUpdate(notification);
    return false;
  }

  bool _measureScheduled = false;

  void _measureAfterLayout() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _update();
    });
  }

  /// Whether pulling the page down past its top opens the search: a tab page's, not the Settings page (nothing to
  /// search there).
  bool get _pullSearches => widget.onBack == null && context.vm.selectedSection != AppSection.settings;

  /// A tab page pulled down past its top opens the search once the finger lets go far enough down, as a second way to
  /// it; a tick tells the finger where that is.
  void _pullOnUpdate(ScrollUpdateNotification notification) {
    final pull = math.max(0.0, notification.metrics.minScrollExtent - notification.metrics.pixels);
    if (notification.dragDetails != null) {
      if ((pull >= _pullToSearch) != (_pulled >= _pullToSearch)) unawaited(HapticFeedback.selectionClick());
      _pulled = pull;
      _dragging = true;
      return;
    }
    // The first step after the finger let go.
    if (_dragging && _pulled >= _pullToSearch) {
      PinnedTitleBar.searchFrom = Rect.fromCenter(
        center: Offset(MediaQuery.sizeOf(context).width / 2, _barMiddle(context)),
        width: _pullHintSize,
        height: _pullHintSize,
      );
      context.vm.openSearch();
    }
    _dragging = false;
    _pulled = 0;
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
  ///
  /// Where the header's parts are in the page is [measure]d only once it is laid out at the scroll: measured in between
  /// (a scroll's step comes before the page moves), they would be off by that step, and the title would jitter.
  void _update({bool measure = true}) {
    if (!mounted) return;
    final own = context.findRenderObject() as RenderBox?;
    if (own == null) return;
    final anchor = _box(_anchor, own);
    final position = anchor == null ? null : Scrollable.maybeOf(_anchor.currentContext!)?.position;
    final measured = position != null && position.hasPixels && position.hasContentDimensions;
    // Signed: below 0 while the page is pulled down past its top.
    final offset = measured ? position.pixels - position.minScrollExtent : 0.0;
    final scrolled = math.max(0.0, offset);
    final edge = MediaQuery.paddingOf(context).top + PinnedTitleBar.height;

    var progress = _progress;
    if (anchor != null && measure) {
      final top = anchor.localToGlobal(Offset.zero, ancestor: own).dy;
      // The scroll from the page's top to where the shade is whole; a short page (an album of a few tracks) that can't
      // scroll so far has it whole at its end.
      final reach = measured ? position.maxScrollExtent - position.minScrollExtent : double.infinity;
      _shadeDistance = math.max(math.min(top + anchor.size.height - edge + offset, reach), math.min(_minFade, reach));
    }
    final distance = _shadeDistance;
    if (anchor != null && distance != null) progress = distance <= 0 ? 0.0 : (scrolled / distance).clamp(0.0, 1.0);

    final title = _box(_title, own);
    var rest = _rest;
    var shrinks = _shrinks;
    if (title != null) {
      final style = (_title.currentWidget as _TitleMark?)?.shrinkStyle;
      shrinks = style != null;
      if (style == null) {
        rest = null;
      } else if (measure) {
        // Where it stands in the page, which the scroll doesn't change: between layouts, as last measured.
        final topLeft = title.localToGlobal(Offset.zero, ancestor: own);
        final size = title.size;
        rest = (
          middle: topLeft.dy + size.height / 2 + offset,
          left: topLeft.dx,
          width: size.width,
          height: size.height,
          style: style,
        );
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
      // Where its top is in the page (as for a shrinking one's place), and so on the screen at this scroll.
      if (measure || _fadingTitleTop == null) {
        _fadingTitleTop = title.localToGlobal(Offset.zero, ancestor: own).dy + offset;
      }
      final top = _fadingTitleTop! - offset;
      titleIn = ((edge - top) / title.size.height).clamp(0.0, 1.0);
      taken = false;
    } else {
      titleIn = scrolled > 0 ? 1.0 : 0.0;
      taken = false;
    }
    _titleIn.value = titleIn;
    _taken.value = taken;
    _scrolled.value = offset;
    _pullIn.value = _pullSearches ? (-offset / _pullToSearch).clamp(0.0, 1.0) : 0.0;
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
    if (!PhoneChrome.isPhone(context)) {
      final onBack = widget.onBack;
      return onBack == null
          ? widget.child
          : _WideBackBar(title: widget.title, onBack: onBack, backText: widget.backText, child: widget.child);
    }
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
              if (onBack != null) ...[
                _searchButton(context),
                ?widget.menu,
              ] else
                ..._topButtons(context, pullIn: _pullIn),
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
            // The page gives past its ends, as on an iPhone: pulled down at its top, a detail page's artwork
            // stretches ([PhoneArtworkStretch]) and a tab page offers the search.
            Positioned.fill(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())),
                child: widget.child,
              ),
            ),
            if (_pullSearches) _pullHint(context),
            Positioned(top: 0, left: 0, right: 0, child: shade),
            Positioned(top: 0, left: 0, right: 0, child: bar),
            if (rest != null) _shrinkingTitle(context, rest),
          ],
        ),
      ),
    );
  }

  /// The search, out of the bar's right into its middle as a tab page is pulled down past its top (the bar's own
  /// fading as it comes): whole, and in the accent, where letting go opens it.
  Widget _pullHint(BuildContext context) {
    final colors = context.colors;
    const size = _pullHintSize;
    return Positioned(
      top: _barMiddle(context) - size / 2,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<double>(
        valueListenable: _pullIn,
        builder: (context, t, _) {
          if (t == 0) return const SizedBox.shrink();
          final ready = t >= 1;
          // In as the bar's goes out, a little behind it.
          final shown = ((t - 0.2) / 0.8).clamp(0.0, 1.0);
          return IgnorePointer(
            child: Center(
              child: Opacity(
                opacity: shown,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * Curves.easeOut.transform(shown),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ready ? colors.accent : colors.surface2,
                      boxShadow: ready ? colors.accentGlow(0.6) : null,
                    ),
                    child: Icon(Icons.search_rounded, size: 22, color: ready ? colors.onAccent : colors.textMain),
                  ),
                ),
              ),
            ),
          );
        },
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

/// A detail page's artwork on a phone, stretching as the page is pulled down past its top (larger, growing up into the
/// gap from its bottom edge) and back as it lets go: it follows the finger only.
class PhoneArtworkStretch extends StatefulWidget {
  const PhoneArtworkStretch({super.key, required this.child});

  final Widget child;

  @override
  State<PhoneArtworkStretch> createState() => _PhoneArtworkStretchState();
}

class _PhoneArtworkStretchState extends State<PhoneArtworkStretch> {
  ScrollPosition? _position;

  /// The most it grows (a part of its size), however far it is pulled.
  static const double _maxGrowth = 0.3;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position == _position) return;
    _position?.removeListener(_changed);
    _position = position?..addListener(_changed);
  }

  @override
  void dispose() {
    _position?.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final pull = position == null || !position.hasPixels || !position.hasContentDimensions
        ? 0.0
        : math.max(0.0, position.minScrollExtent - position.pixels);
    // As fast as the finger at first, slower the further it goes, never past [_maxGrowth].
    final growth = _maxGrowth * pull / (pull + _maxGrowth * 220);
    return Transform.scale(scale: 1 + growth, alignment: Alignment.bottomCenter, child: widget.child);
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
