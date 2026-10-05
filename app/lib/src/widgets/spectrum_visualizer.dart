// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Spectrum bars: one per band, centred on the middle line and growing up and down, softer at the centre and lit in
/// [highlight] at the tips, over a faint glow of the same colours.
class SpectrumVisualizer extends StatelessWidget {
  const SpectrumVisualizer({
    super.key,
    required this.bands,
    required this.color,
    this.highlight,
    this.width = 130,
    this.height = 36,
  });

  final ValueListenable<Float32List> bands;
  final Color color;

  /// The colour of the tips; [color] when not given.
  final Color? highlight;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _SpectrumPainter(bands, color, highlight ?? color)),
    ),
  );
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.bands, this.color, this.highlight) : super(repaint: bands);

  final ValueListenable<Float32List> bands;
  final Color color;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final values = bands.value;
    final count = values.isEmpty ? 32 : values.length;
    const padding = 2.0;
    final slot = (size.width - padding * 2) / count;
    final barWidth = (slot * 0.70).clamp(2.0, 5.0);
    final available = size.height - padding * 2;
    final centerY = size.height / 2;
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        highlight,
        color.withValues(alpha: color.a * 0.5),
        highlight,
      ],
      stops: const [0, 0.5, 1],
    ).createShader(Offset.zero & size);
    final paint = Paint()..shader = shader;
    final glow = Paint()
      ..shader = shader
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < count; i++) {
      final value = i < values.length ? values[i].clamp(0.0, 1.0) : 0.0;
      // At least a bead of 2.5 px, so the centre line glows while it is quiet.
      final h = math.max(2.5, value * available);
      final x = padding + i * slot + (slot - barWidth) / 2;
      final bar = RRect.fromRectAndRadius(Rect.fromLTWH(x, centerY - h / 2, barWidth, h), radius);
      if (value > 0.2) canvas.drawRRect(bar, glow);
      canvas.drawRRect(bar, paint);
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.highlight != highlight || oldDelegate.bands != bands;
}
