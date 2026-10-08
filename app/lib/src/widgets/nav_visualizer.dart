// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../platform.dart';
import '../view_models/app_section.dart';

/// Wiretune's animated logo: eight bars that breathe while music plays (not on a phone or tablet), and a wave that sweeps
/// across them (and recolours them in the section's accent) whenever the user navigates: left to right going down or
/// in, right to left going up or back.
class NavVisualizer extends StatefulWidget {
  const NavVisualizer({
    super.key,
    required this.waveTrigger,
    required this.direction,
    required this.color,
    required this.isPlaying,
    this.width = 38,
    this.height = 28,
  });

  final int waveTrigger;
  final NavWaveDirection direction;
  final Color color;
  final bool isPlaying;
  final double width;
  final double height;

  @override
  State<NavVisualizer> createState() => _NavVisualizerState();
}

class _NavVisualizerState extends State<NavVisualizer> with SingleTickerProviderStateMixin {
  static const int _bands = 8;
  static const double _waveMs = 420;
  static const List<double> _baseHeights = [0.24, 0.40, 0.62, 0.46, 0.54, 0.70, 0.44, 0.26];

  late final Ticker _ticker = createTicker(_tick);
  final List<double> _heights = [for (final h in _baseHeights) h * 0.32];
  late List<Color> _source = List.filled(_bands, widget.color);
  late final List<Color> _current = List.filled(_bands, widget.color);
  double _waveProgress = 1;
  bool _waveActive = false;
  NavWaveDirection _activeDirection = NavWaveDirection.leftToRight;
  double _pulse = 0;
  Duration _last = Duration.zero;

  bool get _breathing => widget.isPlaying && !AppPlatform.current.isMobile;

  @override
  void didUpdateWidget(NavVisualizer old) {
    super.didUpdateWidget(old);
    if (widget.waveTrigger != old.waveTrigger) _triggerWave(widget.direction);
    if (widget.color != old.color) _source = List.of(_current);
    _ensureTicking();
  }

  @override
  void initState() {
    super.initState();
    _ensureTicking();
  }

  void _triggerWave(NavWaveDirection direction) {
    _activeDirection = direction;
    _waveProgress = 0;
    _waveActive = true;
    _source = List.of(_current);
    _ensureTicking();
  }

  void _ensureTicking() {
    final mismatch = _current.any((c) => c != widget.color);
    if ((_waveActive || _breathing || mismatch) && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dtMs = _last == Duration.zero ? 16.0 : (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final step = (dtMs / 16.0).clamp(0.5, 3.0);

    double crest = -99;
    if (_waveActive) {
      _waveProgress += dtMs / _waveMs;
      if (_waveProgress >= 1) {
        _waveProgress = 1;
        _waveActive = false;
      }
      crest = _activeDirection == NavWaveDirection.leftToRight ? -1.5 + _waveProgress * 10 : 8.5 - _waveProgress * 10;
    }
    if (_breathing) _pulse = (_pulse + 0.08 * step) % (math.pi * 2);

    var moving = false;
    for (var i = 0; i < _bands; i++) {
      final rest = _breathing
          ? (_baseHeights[i] * (0.82 + 0.18 * math.sin(_pulse + i * 0.7)) * 0.45).clamp(0.12, 0.60)
          : (_baseHeights[i] * 0.30).clamp(0.12, 0.40);
      var target = rest;
      if (_waveActive) {
        final distance = (i - crest).abs();
        if (distance < 3) {
          final peak = math.exp(-(distance * distance) / (2 * 0.75 * 0.75));
          target = (rest + peak * 0.88).clamp(0.12, 0.98);
        }
        final factor = _activeDirection == NavWaveDirection.leftToRight
            ? ((crest - (i - 1)) / 2).clamp(0.0, 1.0)
            : (((i + 1) - crest) / 2).clamp(0.0, 1.0);
        _current[i] = Color.lerp(_source[i], widget.color, factor)!;
      } else if (_current[i] != widget.color) {
        final next = Color.lerp(_current[i], widget.color, 0.16 * step)!;
        _current[i] = (next.toARGB32() == _current[i].toARGB32()) ? widget.color : next;
      }

      if (target > _heights[i]) {
        _heights[i] += (target - _heights[i]) * 0.70;
        moving = true;
      } else {
        final delta = target - _heights[i];
        if (delta.abs() > 0.005) {
          _heights[i] += delta * 0.24;
          moving = true;
        } else {
          _heights[i] = target;
        }
      }
    }

    setState(() {});
    final mismatch = _current.any((c) => c != widget.color);
    if (!_waveActive && !_breathing && !moving && !mismatch) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _triggerWave(NavWaveDirection.leftToRight),
    child: SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(painter: _BarsPainter(List.of(_heights), List.of(_current))),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.heights, this.colors);

  final List<double> heights;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 2.0;
    final count = heights.length;
    final barWidth = math.max(2.0, (size.width - (count - 1) * gap) / count);
    final centerY = size.height / 2;
    for (var i = 0; i < count; i++) {
      final h = (heights[i] * size.height).clamp(3.2, size.height);
      final rect = Rect.fromLTWH(i * (barWidth + gap), centerY - h / 2, barWidth, h);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)), Paint()..color = colors[i]);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}
