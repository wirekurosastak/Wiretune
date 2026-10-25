// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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

  /// How often the picture is taken again while it moves, so that what arrives meanwhile (the cover, its colours)
  /// shows in it soon rather than when it has opened. Not every frame: drawing the whole player into a picture is the
  /// one costly part of a step (the corners are the painter's, so they need none).
  static const Duration _repicture = Duration(milliseconds: 100);

  /// When the picture was taken, by the frames' clock.
  Duration _pictureAt = Duration.zero;

  /// A picture while it moves, itself once it is open; a new picture as it starts moving, then every [_repicture].
  void _follow() {
    final moving = widget.sheet.position.value < 1;
    // The last frame's time: a finger moves it between frames.
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (moving != _snapshot.allowSnapshotting) {
      _snapshot.allowSnapshotting = moving;
      _pictureAt = now;
    } else if (moving && now - _pictureAt >= _repicture) {
      _snapshot.clear();
      _pictureAt = now;
    }
  }

  /// The cover, in this widget's box; null while it isn't there.
  Rect? _lamp() {
    final cover = widget.sheet.lamp.currentContext?.findRenderObject() as RenderBox?;
    final own = context.findRenderObject() as RenderBox?;
    if (cover == null || own == null || !cover.attached || !own.attached) return null;
    return MatrixUtils.transformRect(cover.getTransformTo(own), Offset.zero & cover.size);
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(controller: _snapshot, painter: _painter, child: widget.child);
}

/// Bends the player's picture into the lamp's stream: a fine grid of it (fine enough that no cell shears what it
/// shows), whose rows come out of the cover top first (the top with the sheet, so with a finger), each widening as it
/// leaves the cover behind, so that the sides curve into a neck at the cover, as in KDE's magic lamp. The stream has a
/// window's rounded corners, squeezed and stretched with the picture, straightening over the last of the way.
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

  /// The corners of the stream while it moves, as a window's.
  static const double _radius = 32;

  /// The last part of the way open, over which the corners straighten (where the screen's own rounded corners are).
  static const double _straighten = 0.15;

  /// The corners' radius at [t] of the way open.
  static double _cornersAt(double t) => _radius * ((1 - t) / _straighten).clamp(0.0, 1.0);

  /// The point [distance] along the line through [points] from its first one (its last one past the end).
  static Offset _along(List<Offset> points, double distance) {
    for (var i = 1; i < points.length; i++) {
      final step = (points[i] - points[i - 1]).distance;
      if (distance <= step && step > 0) return Offset.lerp(points[i - 1], points[i], distance / step)!;
      distance -= step;
    }
    return points.last;
  }

  /// The points of [points] more than [from] and less than [to] along the line through them.
  static Iterable<Offset> _between(List<Offset> points, double from, double to) sync* {
    var travelled = 0.0;
    for (var i = 1; i < points.length - 1; i++) {
      travelled += (points[i] - points[i - 1]).distance;
      if (travelled > from && travelled < to) yield points[i];
    }
  }

  /// The stream's outline: the top row, the [right] side down, the bottom row and the [left] side up, each corner
  /// rounded: [top] and [bottom] are how far the corners reach along their row and along the sides.
  static Path _outline(List<Offset> left, List<Offset> right, Size top, Size bottom) {
    var side = 0.0;
    for (var i = 1; i < right.length; i++) {
      side += (right[i] - right[i - 1]).distance;
    }
    final topX = math.min(top.width, (right.first.dx - left.first.dx) / 2), topY = math.min(top.height, side / 2);
    final bottomX = math.min(bottom.width, (right.last.dx - left.last.dx) / 2);
    final bottomY = math.min(bottom.height, side / 2);
    final up = left.reversed.toList();
    final path = Path()..moveTo(left.first.dx + topX, left.first.dy);
    void corner(Offset at, Offset to) => path.quadraticBezierTo(at.dx, at.dy, to.dx, to.dy);
    void line(Offset to) => path.lineTo(to.dx, to.dy);
    line(right.first - Offset(topX, 0));
    corner(right.first, _along(right, topY));
    _between(right, topY, side - bottomY).forEach(line);
    line(_along(right, side - bottomY));
    corner(right.last, right.last - Offset(bottomX, 0));
    line(left.last + Offset(bottomX, 0));
    corner(left.last, _along(up, bottomY));
    _between(up, bottomY, side - topY).forEach(line);
    line(_along(up, side - topY));
    corner(left.first, left.first + Offset(topX, 0));
    return path..close();
  }

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
    final canvas = context.canvas;
    final radius = _cornersAt(t);
    if (radius > 0) {
      final left = [for (var i = 0; i <= _rows; i++) positions[i * (_columns + 1)]];
      final right = [for (var i = 0; i <= _rows; i++) positions[i * (_columns + 1) + _columns]];
      // The picture's corners, as far as the stream squeezes or stretches it there.
      Size corner(int row, int next) => Size(
        radius * (right[row].dx - left[row].dx) / size.width,
        radius * (right[next] - right[row]).distance * _rows / size.height,
      );
      canvas
        ..save()
        ..clipPath(_outline(left, right, corner(0, 1), corner(_rows, _rows - 1)));
    }
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
    if (radius > 0) canvas.restore();
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
