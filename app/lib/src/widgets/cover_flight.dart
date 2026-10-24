// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'cover_image.dart';

/// A cover that flies: from the tile or the row it was tapped on ([CoverFlightSource]) to the artwork of the page that
/// opens ([CoverFlightTarget]), and back to it when that page closes, if the tile is on the screen again; and from
/// where it is into the player's cover when its music is queued ([toPlayer], [CoverFlightLanding]). The pages swap
/// within one screen, so Flutter's own flights (between routes) can't do it.
abstract final class CoverFlight {
  /// The cover last pressed: what it shows, where it is, its corners, when.
  static ({String tag, Rect rect, double? radius, Widget cover, DateTime at})? _pressed;

  /// The covers on the screen that a flight can land on, by what they show (a preview's over its row's, for one).
  static final Map<String, List<_CoverFlightSourceState>> _sources = {};

  /// The cover showing [tag] on the screen, the last one built if there are several.
  static _CoverFlightSourceState? _source(String tag) {
    for (final source in (_sources[tag] ?? const <_CoverFlightSourceState>[]).reversed) {
      if (source.rect != null) return source;
    }
    return null;
  }

  static void _register(String tag, _CoverFlightSourceState source) => (_sources[tag] ??= []).add(source);

  /// The pages' artworks on the screen, by what they show (a queued page's flies from it).
  static final Map<String, _CoverFlightTargetState> _artworks = {};

  /// The player's cover, where queued music lands.
  static _CoverFlightLandingState? _player;

  /// The music [tag] shows (`album:<id>`, `track:<id>`) was queued: a small copy of its cover, from its tile, row or
  /// page on the screen, arcs into the player's cover, which gives a little bump as it lands. Nothing flies when
  /// neither is on the screen.
  static void toPlayer(String tag) {
    final player = _player;
    final to = player?.rect;
    if (player == null || to == null) return;
    BuildContext? from;
    Rect? rect;
    Widget? cover;
    double? radius;
    if (_source(tag) case final source?) {
      (from, rect, cover, radius) = (source.context, source.rect, source.widget.cover, source.widget.radius);
    } else {
      final artwork = _artworks[tag];
      final found = artwork != null && artwork.mounted ? _rectOf(artwork.context) : null;
      if (found != null) {
        (from, rect, cover, radius) = (
          artwork!.context,
          found,
          artwork.widget.arrival ?? artwork.widget.child,
          artwork.widget.radius,
        );
      }
    }
    if (from == null || rect == null || cover == null) return;
    _fly(
      Overlay.maybeOf(from, rootOverlay: true),
      cover,
      from: rect,
      to: () => player.mounted ? player.rect ?? to : to,
      fromRadius: radius,
      toRadius: player.widget.radius,
      duration: const Duration(milliseconds: 560),
      arc: 90,
      onLanded: () {
        if (!player.mounted) return;
        unawaited(HapticFeedback.lightImpact());
        player.bump();
      },
    );
  }

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

  /// How long a cover takes to fly [distance] pixels: longer the further it goes, so that it moves at most about
  /// 90 px a frame at 60 fps (the most Linux draws), where a fixed time made a flight across the screen jump.
  static Duration _durationFor(double distance) =>
      Duration(milliseconds: (300 + 0.12 * distance).clamp(300.0, 520.0).round());

  /// A press opens the page within this long, or the cover doesn't fly.
  static const Duration _pressToOpen = Duration(milliseconds: 1500);

  static Rect? _rectOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// [cover] flies from [from] to where [to] is (asked every frame: the page under it may still be settling), its
  /// corners rounding from [fromRadius] to [toRadius] (null: round, as it is), over everything in [overlay] (none: it
  /// lands at once); then [onLanded]. With an [arc] it rises that high on the way, as if thrown. It takes [duration], or
  /// as long as its distance asks ([_durationFor]); its speed rises and falls gently (an ease in and out whose top
  /// speed is 1.7 times the average, where a cubic one's is 2.8). Each frame shows it blurred along the way it went
  /// since the last ([_MotionBlur]), so that it glides even where frames are few and far between.
  static void _fly(
    OverlayState? overlay,
    Widget cover, {
    required Rect from,
    required Rect? Function() to,
    required double? fromRadius,
    required double? toRadius,
    required VoidCallback onLanded,
    Duration? duration,
    double arc = 0,
  }) {
    if (overlay == null || !overlay.mounted) {
      onLanded();
      return;
    }
    // Once, from where it goes at the start: the builder runs again whenever the overlay does.
    final time = duration ?? _durationFor(((to() ?? from).center - from.center).distance);
    late final OverlayEntry entry;
    // When the last frame was, how far through the flight, and how much of it its blur spanned.
    var lastAt = Duration.zero;
    var lastProgress = 0.0;
    var span = 16.7 / time.inMilliseconds;
    entry = OverlayEntry(
      builder: (context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: time,
        onEnd: () {
          entry.remove();
          entry.dispose();
          onLanded();
        },
        builder: (context, progress, child) {
          final target = to() ?? from;
          Rect at(double progress) {
            final t = Curves.easeInOut.transform(progress.clamp(0.0, 1.0));
            return Rect.lerp(from, target, t)!.shift(Offset(0, -arc * math.sin(math.pi * t)));
          }

          // The blur spans a frame's time, centred on now: as long as the last frame came before this one (one
          // frame at 60 fps for the first, or after frames stopped coming for a while; built again within a frame,
          // what it was).
          final now = SchedulerBinding.instance.currentFrameTimeStamp;
          final gap = now - lastAt;
          if (gap > Duration.zero) {
            span = lastAt == Duration.zero || gap > const Duration(milliseconds: 50)
                ? 16.7 / time.inMilliseconds
                : progress - lastProgress;
            lastAt = now;
            lastProgress = progress;
          }
          final rect = at(progress);
          final radius = fromRadius == null || toRadius == null ? null : ui.lerpDouble(fromRadius, toRadius, progress)!;
          return Positioned.fromRect(
            rect: rect,
            child: _MotionBlur(
              from: at(progress - span / 2).shift(-rect.topLeft),
              to: at(progress + span / 2).shift(-rect.topLeft),
              child: radius == null ? child! : ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
            ),
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

  /// What flew in, to fly back out; a page opened otherwise (by a link, from the search) sends its
  /// [CoverFlightTarget.arrival] to its tile.
  Widget? _cover;

  /// The screen's overlay, the flights' sky: kept, as a closing page can't look it up.
  OverlayState? _overlay;

  @override
  void initState() {
    super.initState();
    CoverFlight._artworks[widget.tag] = this;
    final pressed = CoverFlight._pressed;
    if (pressed != null &&
        pressed.tag == widget.tag &&
        DateTime.now().difference(pressed.at) < CoverFlight._pressToOpen) {
      CoverFlight._pressed = null;
      _waiting = true;
      _cover = pressed.cover;
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
            if (!mounted) return;
            _measure();
            setState(() => _waiting = false);
          },
        );
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measure();
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
    if (CoverFlight._artworks[widget.tag] == this) CoverFlight._artworks.remove(widget.tag);
    super.dispose();
  }

  /// The page closes: the cover flies back to its tile, once the list is built again, if the tile is on the screen.
  void _flyBack() {
    final from = _rect;
    final cover = _cover ?? widget.arrival;
    if (from == null || cover == null) return;
    _cover = null;
    final tag = widget.tag;
    final overlay = _overlay;
    if (overlay == null || !overlay.mounted) return;
    CoverFlight._landing = tag;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final source = CoverFlight._source(tag);
      final to = source?.rect;
      final screen = overlay.mounted ? MediaQuery.maybeSizeOf(overlay.context) : null;
      void landed() => CoverFlight._land(tag);

      final onScreen = screen == null ? null : Offset.zero & screen;
      if (source == null ||
          to == null ||
          onScreen == null ||
          !onScreen.overlaps(to) ||
          !onScreen.overlaps(from) ||
          !overlay.mounted) {
        landed();
        return;
      }
      CoverFlight._fly(
        overlay,
        cover,
        from: from,
        // The list grows into place as it comes back, and its tile with it.
        to: () => CoverFlight._source(tag)?.rect ?? to,
        fromRadius: widget.radius,
        toRadius: source.widget.radius,
        onLanded: landed,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Opacity(opacity: _waiting ? 0 : 1, child: widget.child);
}

/// The player's cover (the mini player's, the player bar's), where the cover of queued music lands
/// ([CoverFlight.toPlayer]): it gives a little bump when one does.
class CoverFlightLanding extends StatefulWidget {
  const CoverFlightLanding({super.key, required this.radius, required this.child});

  /// The cover's corners.
  final double radius;
  final Widget child;

  @override
  State<CoverFlightLanding> createState() => _CoverFlightLandingState();
}

class _CoverFlightLandingState extends State<CoverFlightLanding> with SingleTickerProviderStateMixin {
  late final AnimationController _bump = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));

  @override
  void initState() {
    super.initState();
    CoverFlight._player = this;
  }

  @override
  void dispose() {
    if (CoverFlight._player == this) CoverFlight._player = null;
    _bump.dispose();
    super.dispose();
  }

  Rect? get rect => CoverFlight._rectOf(context);

  void bump() => _bump.forward(from: 0);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _bump,
    builder: (context, child) => Transform.scale(scale: 1 + 0.14 * math.sin(math.pi * _bump.value), child: child),
    child: widget.child,
  );
}

/// Its child, painted as the average of where it is over a frame's time: from [from] to [to] (where it is then, by its
/// own box), as a film camera's shutter blurs what moves while it is open. A cover crossing the screen in a few dozen
/// frames then glides instead of jumping from one place to the next; one hardly moving is painted once, sharp.
class _MotionBlur extends SingleChildRenderObjectWidget {
  const _MotionBlur({required this.from, required this.to, required super.child});

  final Rect from;
  final Rect to;

  @override
  _RenderMotionBlur createRenderObject(BuildContext context) => _RenderMotionBlur(from, to);

  @override
  void updateRenderObject(BuildContext context, _RenderMotionBlur renderObject) => renderObject
    ..from = from
    ..to = to;
}

class _RenderMotionBlur extends RenderProxyBox {
  _RenderMotionBlur(this._from, this._to);

  /// How far apart the copies the blur is made of may be, in pixels: closer than the eye tells apart in a moving
  /// cover.
  static const double _step = 4;

  /// The most copies a frame paints: a cover moving further than this many steps a frame is blurred in coarser
  /// steps.
  static const int _copies = 12;

  Rect _from;
  set from(Rect value) {
    if (value == _from) return;
    _from = value;
    markNeedsPaint();
  }

  Rect _to;
  set to(Rect value) {
    if (value == _to) return;
    _to = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final moved = math.max((_to.topLeft - _from.topLeft).distance, (_to.bottomRight - _from.bottomRight).distance);
    final copies = (moved / _step).ceil().clamp(1, _copies);
    // Painted more than once only when the child is a plain picture (a cover is); layers can't be.
    if (copies == 1 || child.needsCompositing) {
      context.paintChild(child, offset);
      return;
    }
    final canvas = context.canvas;
    final bounds = _from.expandToInclude(_to).shift(offset).inflate(1);
    // Each copy adds its share, so that together they make the average, see-through where only some of them are.
    final share = Paint()
      ..blendMode = BlendMode.plus
      ..color = Color.fromRGBO(0, 0, 0, 1 / copies);
    canvas.saveLayer(bounds, Paint());
    for (var i = 0; i < copies; i++) {
      final rect = Rect.lerp(_from, _to, (i + 0.5) / copies)!;
      canvas
        ..saveLayer(bounds, share)
        ..translate(offset.dx + rect.left, offset.dy + rect.top)
        ..scale(rect.width / size.width, rect.height / size.height);
      context.paintChild(child, Offset.zero);
      canvas.restore();
    }
    canvas.restore();
  }
}
