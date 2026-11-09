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

  @override
  void dispose() {
    _wait?.cancel();
    _slide.dispose();
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
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: DefaultTextStyle.of(context).style.merge(widget.style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      final height = painter.height;
      painter.dispose();
      final distance = width > constraints.maxWidth ? width + ScrollingText.gap : 0.0;
      if (distance != _distance || widget.text != _text) {
        // Started after this frame: a build must not start or stop what it shows.
        _distance = distance;
        _text = widget.text;
        final text = widget.text;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _distance == distance && _text == text) _restart(distance);
        });
      }
      final line = Text(widget.text, maxLines: 1, softWrap: false, style: widget.style);
      if (distance == 0) return Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
      // As wide as a letter or two, so the ends fade rather than cut a letter through.
      const fade = 36.0;
      return SizedBox(
        height: height,
        child: AnimatedBuilder(
          animation: _slide,
          builder: (context, child) {
            final shift = _slide.value * distance;
            // The start fades only while it is moving away; the end, while there is more to come.
            final start = (shift / fade).clamp(0.0, 1.0);
            return ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 1 - start),
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0, fade / rect.width, 1 - fade / rect.width, 1],
              ).createShader(rect),
              child: ClipRect(
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Transform.translate(offset: Offset(-shift, 0), child: child),
                ),
              ),
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              line,
              const SizedBox(width: ScrollingText.gap),
              line,
            ],
          ),
        ),
      );
    },
  );
}
