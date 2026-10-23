// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'cover_image.dart';

/// A cover that flies: from the tile or the row it was tapped on ([CoverFlightSource]) to the artwork of the page that
/// opens ([CoverFlightTarget]), and back to it when that page closes, if the tile is on the screen again. The pages
/// swap within one screen, so Flutter's own flights (between routes) can't do it.
abstract final class CoverFlight {
  /// The cover last pressed: what it shows, where it is, its corners, when.
  static ({String tag, Rect rect, double? radius, Widget cover, DateTime at})? _pressed;

  /// The covers on the screen that a flight can land on, by what they show (a preview's over its row's, for one).
  static final Map<String, List<_CoverFlightSourceState>> _sources = {};

  /// Where the cover showing [tag] is on the screen, the last one built if there are several.
  static Rect? _sourceRect(String tag) {
    for (final source in (_sources[tag] ?? const []).reversed) {
      final rect = source.rect;
      if (rect != null) return rect;
    }
    return null;
  }

  static void _register(String tag, _CoverFlightSourceState source) => (_sources[tag] ??= []).add(source);

  static void _unregister(String tag, _CoverFlightSourceState source) {
    final sources = _sources[tag];
    if (sources == null) return;
    sources.remove(source);
    if (sources.isEmpty) _sources.remove(tag);
  }

  /// The tag of the cover a flight is landing on: it waits, hidden, for the flight. Set while a page closes (in the
  /// middle of a build), so the list built next has it hidden from the start; [_landed] tells it when to show again.
  static String? _landing;
  static final ValueNotifier<int> _landed = ValueNotifier(0);

  static void _land(String tag) {
    if (_landing != tag) return;
    _landing = null;
    _landed.value++;
  }

  static const Duration _duration = Duration(milliseconds: 380);

  /// A press opens the page within this long, or the cover doesn't fly.
  static const Duration _pressToOpen = Duration(milliseconds: 1500);

  static Rect? _rectOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// [cover] flies from [from] to where [to] is (asked every frame: the page under it may still be settling), its
  /// corners rounding from [fromRadius] to [toRadius] (null: round, as it is), over everything in [overlay] (none: it
  /// lands at once); then [onLanded].
  static void _fly(
    OverlayState? overlay,
    Widget cover, {
    required Rect from,
    required Rect? Function() to,
    required double? fromRadius,
    required double? toRadius,
    required VoidCallback onLanded,
  }) {
    if (overlay == null || !overlay.mounted) {
      onLanded();
      return;
    }
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: _duration,
        curve: Curves.easeInOutCubic,
        onEnd: () {
          entry.remove();
          entry.dispose();
          onLanded();
        },
        builder: (context, t, child) {
          final radius = fromRadius == null || toRadius == null ? null : ui.lerpDouble(fromRadius, toRadius, t)!;
          return Positioned.fromRect(
            rect: Rect.lerp(from, to() ?? from, t)!,
            child: radius == null ? child! : ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
          );
        },
        child: IgnorePointer(child: cover),
      ),
    );
    overlay.insert(entry);
  }
}

/// A cover a flight can start from and come back to: [builder] draws the tile or the row with it (a press anywhere on
/// them counts), [cover] being what flies.
class CoverFlightSource extends StatefulWidget {
  const CoverFlightSource({
    super.key,
    required this.tag,
    required this.radius,
    required this.cover,
    required this.builder,
  });

  /// What the cover shows (`album:<id>`), the same as its page's [CoverFlightTarget.tag].
  final String tag;

  /// The cover's corners (null: it is round).
  final double? radius;
  final Widget cover;
  final Widget Function(BuildContext context, Widget cover) builder;

  @override
  State<CoverFlightSource> createState() => _CoverFlightSourceState();
}

class _CoverFlightSourceState extends State<CoverFlightSource> {
  final GlobalKey _cover = GlobalKey();

  @override
  void initState() {
    super.initState();
    CoverFlight._register(widget.tag, this);
  }

  @override
  void didUpdateWidget(CoverFlightSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tag == widget.tag) return;
    CoverFlight._unregister(oldWidget.tag, this);
    CoverFlight._register(widget.tag, this);
  }

  @override
  void dispose() {
    CoverFlight._unregister(widget.tag, this);
    super.dispose();
  }

  Rect? get rect {
    final context = _cover.currentContext;
    return context == null ? null : CoverFlight._rectOf(context);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      final rect = this.rect;
      if (rect == null) return;
      CoverFlight._pressed = (
        tag: widget.tag,
        rect: rect,
        radius: widget.radius,
        cover: widget.cover,
        at: DateTime.now(),
      );
    },
    child: widget.builder(
      context,
      KeyedSubtree(
        key: _cover,
        child: ValueListenableBuilder<int>(
          valueListenable: CoverFlight._landed,
          builder: (context, _, child) => Opacity(opacity: CoverFlight._landing == widget.tag ? 0 : 1, child: child),
          child: widget.cover,
        ),
      ),
    ),
  );
}

/// A page's artwork that a cover flies into when it opens from a press on that cover ([CoverFlightSource]), and back
/// out of when it closes. Hidden while the cover is on its way.
class CoverFlightTarget extends StatefulWidget {
  const CoverFlightTarget({super.key, required this.tag, required this.radius, this.arrival, required this.child});

  final String tag;

  /// The artwork's corners (null: it is round).
  final double? radius;

  /// The artwork alone, sharp, laid over the flying cover (the tile's smaller picture) as it loads.
  final Widget? arrival;
  final Widget child;

  @override
  State<CoverFlightTarget> createState() => _CoverFlightTargetState();
}

class _CoverFlightTargetState extends State<CoverFlightTarget> {
  bool _waiting = false;
  ScrollPosition? _position;

  /// Where the artwork is on the screen, kept up to date while the page scrolls: a closed page can't be measured.
  Rect? _rect;

  /// What flew in, and its corners, to fly back out.
  Widget? _cover;
  double? _coverRadius;

  /// The screen's overlay, the flights' sky: kept, as a closing page can't look it up.
  OverlayState? _overlay;

  @override
  void initState() {
    super.initState();
    final pressed = CoverFlight._pressed;
    if (pressed != null &&
        pressed.tag == widget.tag &&
        DateTime.now().difference(pressed.at) < CoverFlight._pressToOpen) {
      CoverFlight._pressed = null;
      _waiting = true;
      _cover = pressed.cover;
      _coverRadius = pressed.radius;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final to = mounted ? CoverFlight._rectOf(context) : null;
        if (to == null) {
          if (mounted) setState(() => _waiting = false);
          return;
        }
        _rect = to;
        final arrival = widget.arrival;
        final cover = arrival == null
            ? pressed.cover
            : Stack(fit: StackFit.expand, children: [pressed.cover, CoverImage.withoutPlaceholders(arrival)]);
        // Towards where the artwork is when it gets there: the page grows into place as it comes in.
        CoverFlight._fly(
          _overlay,
          cover,
          from: pressed.rect,
          to: () => mounted ? CoverFlight._rectOf(context) ?? _rect : _rect,
          fromRadius: pressed.radius,
          toRadius: widget.radius,
          onLanded: () {
            if (mounted) setState(() => _waiting = false);
          },
        );
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _overlay = Overlay.maybeOf(context, rootOverlay: true);
    final position = Scrollable.maybeOf(context)?.position;
    if (position == _position) return;
    _position?.removeListener(_measure);
    _position = position?..addListener(_measure);
  }

  void _measure() => _rect = CoverFlight._rectOf(context) ?? _rect;

  @override
  void deactivate() {
    _flyBack();
    super.deactivate();
  }

  @override
  void dispose() {
    _position?.removeListener(_measure);
    super.dispose();
  }

  /// The page closes: the cover flies back to its tile, once the list is built again, if the tile is on the screen.
  void _flyBack() {
    final from = _rect;
    final cover = _cover;
    final radius = _coverRadius;
    if (from == null || cover == null) return;
    _cover = null;
    final tag = widget.tag;
    final overlay = _overlay;
    if (overlay == null || !overlay.mounted) return;
    CoverFlight._landing = tag;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final to = CoverFlight._sourceRect(tag);
      final screen = overlay.mounted ? MediaQuery.maybeSizeOf(overlay.context) : null;
      void landed() => CoverFlight._land(tag);

      final onScreen = screen == null ? null : Offset.zero & screen;
      if (to == null || onScreen == null || !onScreen.overlaps(to) || !onScreen.overlaps(from) || !overlay.mounted) {
        landed();
        return;
      }
      CoverFlight._fly(
        overlay,
        cover,
        from: from,
        // The list grows into place as it comes back, and its tile with it.
        to: () => CoverFlight._sourceRect(tag) ?? to,
        fromRadius: widget.radius,
        toRadius: radius,
        onLanded: landed,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Opacity(opacity: _waiting ? 0 : 1, child: widget.child);
}
