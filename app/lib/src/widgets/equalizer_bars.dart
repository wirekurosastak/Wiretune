import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// The four bouncing bars that mark the track that is playing (14 px tall, in the accent colour). Each bar moves on its
/// own period, so together they never repeat in step.
class EqualizerBars extends StatefulWidget {
  const EqualizerBars({super.key, this.height = 14, this.color});

  final double height;
  final Color? color;

  static const int _barCount = 4;
  static const double _barWidth = 2.5;
  static const double _barGap = 2;

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _time.value = DateTime.now().millisecondsSinceEpoch / 1000.0)
    ..start();
  final ValueNotifier<double> _time = ValueNotifier(0);

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size(
        EqualizerBars._barCount * EqualizerBars._barWidth + (EqualizerBars._barCount - 1) * EqualizerBars._barGap,
        widget.height,
      ),
      painter: _BarsPainter(_time, widget.color ?? context.colors.accent),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.time, this.color) : super(repaint: time);

  final ValueNotifier<double> time;
  final Color color;

  static const List<double> _low = [0.25, 0.30, 0.40, 0.20];
  static const List<double> _high = [1.00, 0.90, 0.95, 0.70];
  static const List<double> _period = [1.10, 1.60, 1.32, 1.88];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var i = 0; i < EqualizerBars._barCount; i++) {
      final wave = 0.5 - 0.5 * math.cos(2 * math.pi * time.value / _period[i]);
      final height = size.height * (_low[i] + (_high[i] - _low[i]) * wave);
      final x = i * (EqualizerBars._barWidth + EqualizerBars._barGap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, EqualizerBars._barWidth, height),
          const Radius.circular(1.25),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) => oldDelegate.color != color;
}
