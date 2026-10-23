// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';

/// The phone's full-screen player as a sheet over the pages: [position] runs from 0 (down, closed) to 1 (up, open). It
/// goes where the view model opens or closes it ([follow]), and in between it follows the finger that drags it, up from
/// the mini player or down from the player's top, as in TIDAL and Spotify ([PlayerSheetDrag]). It moves only then.
class PlayerSheet {
  PlayerSheet({required TickerProvider vsync, required bool open})
    : position = AnimationController(vsync: vsync, duration: _duration, value: open ? 1 : 0) {
    // A soft knock when it lands open.
    position.addStatusListener((status) {
      if (status == AnimationStatus.completed) unawaited(HapticFeedback.lightImpact());
    });
  }

  /// The whole way up or down; a part of the way takes that part of it.
  static const Duration _duration = Duration(milliseconds: 320);

  /// A finger that lets go faster than this (logical pixels a second) opens or closes the player, wherever it is.
  static const double _flingVelocity = 700;

  final AnimationController position;

  /// The mini player's cover: the full-screen player pours out of it and back into it ([MagicLamp]).
  final GlobalKey lamp = GlobalKey();
  bool _dragging = false;
  double? _target;

  /// The view model opened or closed the player (a tap, Back, a page opened from it): the sheet goes there from where
  /// it is, unless a finger holds it.
  void follow({required bool open}) {
    if (!_dragging) _settle(open);
  }

  /// Up or down the rest of the way, slowing down to rest (as it did before it could be dragged, and as a finger's
  /// throw would).
  void _settle(bool open) {
    const curve = Curves.easeOutCubic;
    final target = open ? 1.0 : 0.0;
    if (_target == target && position.isAnimating) return;
    _target = target;
    final distance = (target - position.value).abs();
    if (distance == 0) return;
    final duration = _duration * distance;
    if (open) {
      position.animateTo(target, duration: duration, curve: curve);
    } else {
      // A reverse run, which ends dismissed: the closed player is then left out.
      position.animateBack(target, duration: duration, curve: curve);
    }
  }

  void _start() {
    _dragging = true;
    _target = null;
    position.stop();
  }

  /// The finger moved [delta] down (up when negative); [travel] is how far the player's top goes from closed to open.
  /// Past half the way (where letting go opens or closes it) a tick tells the finger so.
  void _move(double delta, double travel) {
    final before = position.value > 0.5;
    position.value -= delta / travel;
    if ((position.value > 0.5) != before) unawaited(HapticFeedback.selectionClick());
  }

  /// How far the player's top goes from closed to open: from the mini player's cover, out of which it pours, to the
  /// screen's top (the whole [height] without a cover). So its top stays under the finger.
  double _travel(double height) {
    final cover = lamp.currentContext?.findRenderObject() as RenderBox?;
    final middle = cover == null || !cover.attached ? 0.0 : cover.localToGlobal(cover.size.center(Offset.zero)).dy;
    return middle > 0 ? middle : height;
  }

  /// The finger let go at [velocity] (down when positive): flung, the sheet goes that way, else to the nearer end.
  /// True when that is open.
  bool _release(double velocity) {
    _dragging = false;
    final open = velocity.abs() > _flingVelocity ? velocity < 0 : position.value > 0.5;
    _settle(open);
    return open;
  }

  void dispose() => position.dispose();
}

/// Makes the phone layout's [PlayerSheet] reachable from the parts that drag it.
class PlayerSheetScope extends InheritedWidget {
  const PlayerSheetScope({super.key, required this.sheet, required super.child});

  final PlayerSheet sheet;

  /// The phone layout's sheet, if [context] is in it.
  static PlayerSheet? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerSheetScope>()?.sheet;

  @override
  bool updateShouldNotify(PlayerSheetScope oldWidget) => sheet != oldWidget.sheet;
}

/// A vertical drag over [child] moves the full-screen player with the finger: up from the mini player, down from the
/// player itself. Let go, it opens or closes the rest of the way (and tells the view model), or goes back. Taps, and
/// horizontal drags such as a slider's, still reach the child.
class PlayerSheetDrag extends StatelessWidget {
  const PlayerSheetDrag({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.maybeOf(context);
    if (sheet == null) return child;
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => sheet._start(),
      onVerticalDragUpdate: (details) => sheet._move(details.primaryDelta ?? 0, sheet._travel(height)),
      onVerticalDragEnd: (details) {
        final vm = context.vm;
        sheet._release(details.primaryVelocity ?? 0) ? vm.openNowPlaying() : vm.closeNowPlaying();
      },
      child: child,
    );
  }
}

/// The full-screen player as it opens and closes, as KDE's magic lamp: it pours out of the mini player's cover
/// ([PlayerSheet.lamp]), a narrow stream that widens towards its top as it rises, and back into it; under a finger, as
/// far as the finger has taken it, see-through while thin and with a window's rounded corners. While it moves, a
/// picture of it is bent; open, it is drawn as itself.
class MagicLamp extends StatefulWidget {
  const MagicLamp({super.key, required this.sheet, required this.child});

  final PlayerSheet sheet;
  final Widget child;

  @override
  State<MagicLamp> createState() => _MagicLampState();
}

class _MagicLampState extends State<MagicLamp> {
  final SnapshotController _snapshot = SnapshotController();
  late final _LampPainter _painter = _LampPainter(widget.sheet.position, _lamp);

  @override
  void initState() {
    super.initState();
    widget.sheet.position.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.sheet.position.removeListener(_follow);
    _snapshot.dispose();
    _painter.dispose();
    super.dispose();
  }

  /// The corners of the player while it moves, as a window's.
  static const double _radius = 32;

  /// The last part of the way open, over which the corners straighten (where the screen's own rounded corners are).
  static const double _straighten = 0.15;

  /// The corners' radius at [t] of the way open.
  static double _cornersAt(double t) => _radius * ((1 - t) / _straighten).clamp(0.0, 1.0);

  /// A picture while it moves, itself once it is open. The picture is taken again every few steps, so what arrives
  /// meanwhile (the cover, its colours) shows in it soon rather than when it has opened, without the cost of a picture
  /// a frame; at every step while its corners change.
  void _follow() {
    final t = widget.sheet.position.value;
    final moving = t < 1;
    _snapshot.allowSnapshotting = moving;
    if (moving && (t > 1 - _straighten || _steps++ % 3 == 2)) _snapshot.clear();
  }

  int _steps = 0;

  /// The cover, in this widget's box; null while it isn't there.
  Rect? _lamp() {
    final cover = widget.sheet.lamp.currentContext?.findRenderObject() as RenderBox?;
    final own = context.findRenderObject() as RenderBox?;
    if (cover == null || own == null || !cover.attached || !own.attached) return null;
    return MatrixUtils.transformRect(cover.getTransformTo(own), Offset.zero & cover.size);
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _snapshot,
    painter: _painter,
    child: ValueListenableBuilder<double>(
      valueListenable: widget.sheet.position,
      // Always there (the player under it stays as it is), clipping only while the corners are round.
      builder: (context, t, child) {
        final radius = _cornersAt(t);
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          clipBehavior: radius == 0 ? Clip.none : Clip.antiAlias,
          child: child,
        );
      },
      child: widget.child,
    ),
  );
}

/// Bends the player's picture into the lamp's stream: a fine grid of it (fine enough that no cell shears what it
/// shows), whose rows come out of the cover top first (the top with the sheet, so with a finger), each widening as it
/// leaves the cover behind, so that the sides curve into a neck at the cover, as in KDE's magic lamp.
class _LampPainter extends SnapshotPainter {
  _LampPainter(this.position, this.lamp) {
    position.addListener(notifyListeners);
  }

  final Animation<double> position;
  final Rect? Function() lamp;

  /// The grid the picture is cut into.
  static const int _rows = 48, _columns = 8;

  /// The grid's cells, two triangles each (the same every frame).
  static final List<int> _triangles = [
    for (var i = 0; i < _rows; i++)
      for (var j = 0; j < _columns; j++) ...[
        i * (_columns + 1) + j,
        i * (_columns + 1) + j + 1,
        (i + 1) * (_columns + 1) + j,
        i * (_columns + 1) + j + 1,
        (i + 1) * (_columns + 1) + j + 1,
        (i + 1) * (_columns + 1) + j,
      ],
  ];

  /// How far behind the top the bottom row starts out of the cover (a part of the whole way); it catches up by the
  /// end.
  static const double _lag = 0.5;

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final t = position.value;
    final cover = lamp() ?? Rect.fromCenter(center: Offset(size.width / 2, size.height - 60), width: 44, height: 44);
    final positions = <Offset>[];
    final pixels = <Offset>[];
    for (var i = 0; i <= _rows; i++) {
      final v = i / _rows;
      // This row's own way out: the top's is the sheet's, the bottom's starts [_lag] later; all are out when it is
      // open.
      final out = ((t - v * _lag) / (1 - v * _lag)).clamp(0.0, 1.0);
      final y = cover.center.dy + (v * size.height - cover.center.dy) * out;
      // Wide as it leaves the cover: slowly at first and last, so the sides curve.
      final wide = Curves.easeInOutCubic.transform(out);
      final left = cover.left * (1 - wide);
      final right = cover.right + (size.width - cover.right) * wide;
      for (var j = 0; j <= _columns; j++) {
        final u = j / _columns;
        positions.add(offset + Offset(left + (right - left) * u, y));
        pixels.add(Offset(u * sourceSize.width, v * sourceSize.height));
      }
    }
    final vertices = ui.Vertices(ui.VertexMode.triangles, positions, textureCoordinates: pixels, indices: _triangles);
    final paint = Paint()
      // See-through while a thin stream, solid as it widens.
      ..color = Color.fromRGBO(0, 0, 0, Curves.easeOut.transform((t * 2.5).clamp(0.0, 1.0)))
      ..shader = ImageShader(image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage)
      ..filterQuality = FilterQuality.medium;
    context.canvas.drawVertices(vertices, BlendMode.srcOver, paint);
    vertices.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset, Size size, PaintingContextCallback painter) =>
      painter(context, offset);

  @override
  bool shouldRepaint(_LampPainter oldPainter) => oldPainter.position != position;

  @override
  void dispose() {
    position.removeListener(notifyListeners);
    super.dispose();
  }
}
