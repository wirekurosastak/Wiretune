import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Spectrum bars: one per band, centred on the middle line and growing up and down, in the accent colour bright at
/// the tips and softer at the centre. The look is inspired by the visualizer in FxSound
/// (https://github.com/fxsound2/fxsound-app).
class SpectrumVisualizer extends StatelessWidget {
  const SpectrumVisualizer({super.key, required this.bands, required this.color, this.width = 130, this.height = 36});

  final ValueListenable<Float32List> bands;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _SpectrumPainter(bands, color)),
    ),
  );
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.bands, this.color) : super(repaint: bands);

  final ValueListenable<Float32List> bands;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final values = bands.value;
    final count = values.isEmpty ? 32 : values.length;
    const padding = 2.0;
    final slot = (size.width - padding * 2) / count;
    final barWidth = (slot * 0.70).clamp(2.0, 5.0);
    final available = size.height - padding * 2;
    final centerY = size.height / 2;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color,
          color.withValues(alpha: color.a * 0.45),
          color,
        ],
        stops: const [0, 0.5, 1],
      ).createShader(Offset.zero & size);
    final radius = Radius.circular(math.min(1.5, barWidth / 2));

    for (var i = 0; i < count; i++) {
      final value = i < values.length ? values[i].clamp(0.0, 1.0) : 0.0;
      // At least a bead of 2.5 px, so the centre line glows while it is quiet.
      final h = math.max(2.5, value * available);
      final x = padding + i * slot + (slot - barWidth) / 2;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, centerY - h / 2, barWidth, h), radius), paint);
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => oldDelegate.color != color || oldDelegate.bands != bands;
}
