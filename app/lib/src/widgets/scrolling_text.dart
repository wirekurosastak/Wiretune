// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';

/// One line of text that scrolls through when it doesn't fit, as a music player's title does: it waits, slides along
/// its whole length until it comes round again, and waits again. Its ends fade while it is cut off. Text that fits
/// stands still, and nothing runs for it.
class ScrollingText extends StatefulWidget {
  const ScrollingText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  /// How long it waits before each pass, how fast it slides (logical pixels a second), and the room between the end of
  /// the text and its start coming round again.
  static const Duration pause = Duration(seconds: 3);
  static const double speed = 34, gap = 48;

  @override
  State<ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<ScrollingText> with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(vsync: this);
  Timer? _wait;

  /// The distance one pass slides (the text's width and the gap), 0 while the text fits; and the text it is for.
  double _distance = 0;
  String? _text;

  /// The line as it is painted while it scrolls.
  TextPainter? _line;

  @override
  void dispose() {
    _wait?.cancel();
    _slide.dispose();
    _line?.dispose();
    super.dispose();
  }

  /// From the start again, after the pause; or, for text that fits ([distance] 0), still.
  void _restart(double distance) {
    _distance = distance;
    _wait?.cancel();
    _slide
      ..stop()
      ..value = 0;
    if (distance > 0) _wait = Timer(ScrollingText.pause, _pass);
  }

  void _pass() {
    if (!mounted || _distance <= 0) return;
    _slide.duration = Duration(milliseconds: (_distance / ScrollingText.speed * 1000).round());
    _slide.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted || _slide.value < 1) return;
      _slide.value = 0;
      _wait = Timer(ScrollingText.pause, _pass);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Measured as it is drawn: in the text style around it, with this one's over it.
      final line = TextPainter(
        text: TextSpan(text: widget.text, style: DefaultTextStyle.of(context).style.merge(widget.style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final distance = line.width > constraints.maxWidth ? line.width + ScrollingText.gap : 0.0;
      if (distance != _distance || widget.text != _text) {
        // Started after this frame: a build must not start or stop what it shows.
        _distance = distance;
        _text = widget.text;
        final text = widget.text;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _distance == distance && _text == text) _restart(distance);
        });
      }
      _line?.dispose();
      if (distance == 0) {
        line.dispose();
        _line = null;
        return Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
      }
      _line = line;
      // The line and its fading ends are drawn in one go, on every platform alike: a ShaderMask over sliding text
      // measured its fade against the wrong box on Android, which left the end's fade a sliver.
      return Semantics(
        label: widget.text,
        child: CustomPaint(size: Size(constraints.maxWidth, line.height), painter: _Marquee(line, distance, _slide)),
      );
    },
  );
}

/// [line] slid [slide] of the way along [distance] (its width and the gap), followed by itself coming round, the ends
/// fading: the start only while it moves away, the end while there is more to come.
class _Marquee extends CustomPainter {
  _Marquee(this.line, this.distance, this.slide) : super(repaint: slide);

  final TextPainter line;
  final double distance;
  final Animation<double> slide;

  /// As wide as a letter or two, so the ends fade rather than cut a letter through.
  static const double _fade = 36;

  /// How far the line has slid now.
  double get shift => slide.value * distance;

  @override
  void paint(Canvas canvas, Size size) {
    final shift = this.shift;
    final bounds = Offset.zero & size;
    final start = (shift / _fade).clamp(0.0, 1.0);
    final fade = _fade / size.width;
    final faded = Colors.white.withValues(alpha: 1 - start);
    canvas
      ..saveLayer(bounds.inflate(2), Paint())
      ..save()
      ..clipRect(bounds);
    line
      ..paint(canvas, Offset(-shift, 0))
      ..paint(canvas, Offset(distance - shift, 0));
    canvas.restore();
    // The fade reaches past the box, unclipped: the box's edge falls between pixels, and a fade cut there faded the
    // last column only partly, which left a sliver of the letters at the ends.
    canvas.drawRect(
      bounds.inflate(2),
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          colors: [faded, Colors.white, Colors.white, Colors.transparent],
          stops: [0, fade, 1 - fade, 1],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Marquee oldDelegate) => line != oldDelegate.line || distance != oldDelegate.distance;
}
