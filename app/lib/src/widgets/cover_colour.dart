// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'cover_image.dart';

/// The colour of a cover: its most vivid colours, averaged, read from a tiny copy of it. Null for a grey or black and
/// white cover, which has none to give. Each cover is read once.
abstract final class CoverColour {
  static final Map<String, Color?> _known = {};
  static final Map<String, Future<Color?>> _reading = {};

  /// The colour of the cover at [path], if it has been read.
  static Color? known(String path) => _known[path];

  /// The colour of the cover at [path], read now if it hasn't been.
  static Future<Color?> of(String path) => _reading[path] ??= _read(path).then((colour) => _known[path] = colour);

  /// The pixels a cover is read at, across.
  static const int _size = 24;

  static Future<Color?> _read(String path) async {
    final provider = CoverArt.provider(path, decodeWidth: _size);
    if (provider == null) return null;
    final loaded = Completer<ui.Image?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!loaded.isCompleted) loaded.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!loaded.isCompleted) loaded.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await loaded.future;
    if (image == null) return null;
    final bytes = await image.toByteData();
    image.dispose();
    if (bytes == null) return null;

    // Every pixel weighed by how vivid it is (saturated, neither dark nor washed out); the most vivid fifth averaged.
    final pixels = <(double, Color)>[];
    for (var i = 0; i + 3 < bytes.lengthInBytes; i += 4) {
      final colour = Color.fromARGB(255, bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
      final hsv = HSVColor.fromColor(colour);
      pixels.add((hsv.saturation * hsv.value * (1 - (hsv.value - 0.75).abs()), colour));
    }
    if (pixels.isEmpty) return null;
    pixels.sort((a, b) => b.$1.compareTo(a.$1));
    final top = pixels.take((pixels.length / 5).ceil()).toList();
    if (top.first.$1 < 0.12) return null; // grey: no colour to give
    double channel(double Function(Color c) of) => top.fold(0.0, (sum, p) => sum + of(p.$2)) / top.length;
    return Color.from(alpha: 1, red: channel((c) => c.r), green: channel((c) => c.g), blue: channel((c) => c.b));
  }

  /// [colour] as a wash: as bright and as saturated as the section colours, so it sits with them.
  static Color wash(Color colour, {required bool dark}) {
    final hsl = HSLColor.fromColor(colour);
    return hsl.withSaturation(hsl.saturation.clamp(0.5, 0.9)).withLightness(dark ? 0.66 : 0.45).toColor();
  }
}

/// The colour of the cover at [path] as a [wash] for the area behind it (the accent stays the section's). A cover with
/// no colour of its own gives none. A new cover's colour comes in over a moment, as the cover itself does; [wash]'s
/// alpha is how far it has.
class CoverTint extends StatefulWidget {
  const CoverTint({super.key, required this.path, required this.builder});

  final String? path;

  /// Builds the tinted area from the cover's colour (null: none).
  final Widget Function(BuildContext context, Color? wash) builder;

  @override
  State<CoverTint> createState() => _CoverTintState();
}

class _CoverTintState extends State<CoverTint> {
  Color? _colour;
  Color _last = const Color(0x00000000);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverTint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  void _load() {
    final path = widget.path;
    if (path == null || path.isEmpty) {
      _colour = null;
      return;
    }
    _colour = CoverColour.known(path);
    if (_colour != null) return;
    unawaited(
      CoverColour.of(path).then((colour) {
        if (mounted && widget.path == path) setState(() => _colour = colour);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colour = _colour;
    final target = colour == null ? null : CoverColour.wash(colour, dark: context.colors.palette.isDark);
    if (target != null) _last = target;
    return TweenAnimationBuilder<Color?>(
      // Out of nothing and back into it: from and to the last colour, see-through.
      tween: ColorTween(end: target ?? _last.withValues(alpha: 0)),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, wash, _) => widget.builder(context, wash == null || wash.a == 0 ? null : wash),
    );
  }
}
