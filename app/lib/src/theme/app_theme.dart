// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../view_models/app_section.dart';
import 'palette.dart';

/// The palette and the active section's accent, reachable from any widget through `context.colors`.
class WiretuneColors extends ThemeExtension<WiretuneColors> {
  const WiretuneColors(this.palette, this.accent, this.section);

  final Palette palette;
  final Color accent;
  final AppSection section;

  Color get hover => palette.hoverOf(accent);
  Color get textMain => palette.textMain;
  Color get textMuted => palette.textMuted;
  Color get surface1 => palette.surface1;
  Color get surface2 => palette.surface2;
  Color get glassBorder => palette.glassBorder;
  Color get danger => palette.danger;
  Color get onAccent => palette.onAccent;
  Gradient get windowGradient => palette.gradientFor(section);

  /// The accent as a gradient, from its lighter hover shade to the accent itself (filled buttons, the active slider).
  Gradient get accentGradient =>
      LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [hover, accent]);

  /// The coloured glow under an accent-filled control.
  List<BoxShadow> accentGlow([double strength = 1]) => [
    BoxShadow(
      color: accent.withValues(alpha: (palette.isDark ? 0.45 : 0.35) * strength),
      blurRadius: 18 * strength,
      spreadRadius: -2,
      offset: Offset(0, 4 * strength),
    ),
  ];

  @override
  WiretuneColors copyWith({Palette? palette, Color? accent, AppSection? section}) =>
      WiretuneColors(palette ?? this.palette, accent ?? this.accent, section ?? this.section);

  @override
  WiretuneColors lerp(WiretuneColors? other, double t) {
    if (other == null) return this;
    return WiretuneColors(
      t < 0.5 ? palette : other.palette,
      Color.lerp(accent, other.accent, t)!,
      t < 0.5 ? section : other.section,
    );
  }
}

extension WiretuneThemeContext on BuildContext {
  WiretuneColors get colors => Theme.of(this).extension<WiretuneColors>()!;
}

/// Corner radii: small controls, cards and rows, the floating panels.
abstract final class Radii {
  static const double small = 8;
  static const double card = 14;
  static const double panel = 20;
}

ThemeData buildTheme({
  required bool light,
  required AppSection section,
  required bool isTv,
  bool desktopFonts = false,
}) {
  final palette = light ? Palette.light : Palette.dark;
  final accent = palette.accentFor(section);
  // Text and icons on an accent-filled button: near-black on the dark theme's bright accents, white on the light one's.
  final onAccent = palette.onAccent;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: light ? Brightness.light : Brightness.dark)
      .copyWith(
        primary: accent,
        onPrimary: onAccent,
        secondary: accent,
        surface: palette.modal,
        onSurface: palette.textMain,
        error: palette.danger,
      );

  final focus = accent.withValues(alpha: isTv ? 0.45 : 0.25);
  const stadium = StadiumBorder();
  OutlineInputBorder field(Color color, [double width = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color, width: width),
  );
  final textTheme = Typography.material2021(platform: TargetPlatform.android).englishLike
      .merge(light ? Typography.blackMountainView : Typography.whiteMountainView)
      .apply(bodyColor: palette.textMain, displayColor: palette.textMain);
  return ThemeData(
    useMaterial3: true,
    // The font chain: Segoe UI Variable on Windows, Inter where installed, otherwise the system's sans-serif
    // (Noto Sans on most Linux desktops). Phones and TVs keep their own system font.
    fontFamily: desktopFonts ? 'Segoe UI Variable' : null,
    fontFamilyFallback: desktopFonts
        ? const ['Segoe UI', 'Inter', 'Noto Sans', 'Cantarell', 'DejaVu Sans', 'Arial']
        : null,
    colorScheme: scheme,
    brightness: light ? Brightness.light : Brightness.dark,
    scaffoldBackgroundColor: palette.background,
    canvasColor: palette.modal,
    focusColor: focus,
    hoverColor: palette.surface1,
    splashFactory: InkRipple.splashFactory,
    visualDensity: isTv ? VisualDensity.comfortable : VisualDensity.standard,
    dividerColor: palette.glassBorder,
    // Text fields write in bodyLarge: 15 px, a step above the 13–14 px of the text around them, not two.
    textTheme: textTheme.copyWith(bodyLarge: textTheme.bodyLarge!.copyWith(fontSize: 15)),
    iconTheme: IconThemeData(color: palette.textMain),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: light ? const Color(0xF0181820) : const Color(0xF22A2A34),
        borderRadius: BorderRadius.circular(Radii.small),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
    ),
    // Sliders: a 4 px rail, the played part a glowing accent gradient, and a small white knob that grows while dragged.
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: palette.glassHighlight,
      thumbColor: accent,
      disabledThumbColor: palette.textMuted,
      disabledActiveTrackColor: palette.textMuted,
      disabledInactiveTrackColor: palette.glassHighlight,
      overlayColor: accent.withValues(alpha: 0.12),
      thumbShape: const KnobThumbShape(),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: const GlowTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : palette.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : palette.surface2),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: palette.textMuted, width: 1.5),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 8 : 5),
      radius: const Radius.circular(8),
      thumbColor: WidgetStateProperty.all(palette.glassHighlight),
      crossAxisMargin: 3,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface1,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: TextStyle(color: palette.textMuted),
      border: field(palette.glassBorder),
      enabledBorder: field(palette.glassBorder),
      focusedBorder: field(accent, 1.6),
    ),
    // The "primary" and "secondary" buttons: 40 px pills, bold 13 px text; the primary one glows under the mouse.
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: onAccent,
            disabledBackgroundColor: palette.surface2,
            minimumSize: const Size(0, 40),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.1),
            shape: stadium,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          ).copyWith(
            overlayColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.pressed) ? palette.pressedOf(accent).withValues(alpha: 0.5) : null,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.disabled)
                  ? palette.surface2
                  : s.contains(WidgetState.hovered)
                  ? palette.hoverOf(accent)
                  : accent,
            ),
            elevation: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? 10 : 0,
            ),
            shadowColor: WidgetStateProperty.all(accent.withValues(alpha: 0.6)),
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            foregroundColor: palette.textMain,
            backgroundColor: palette.surface1,
            minimumSize: const Size(0, 40),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.1),
            side: BorderSide(color: palette.glassBorder),
            shape: stadium,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.hovered) ? palette.surface2 : palette.surface1,
            ),
            side: WidgetStateProperty.resolveWith(
              (s) => BorderSide(
                color: s.contains(WidgetState.hovered) ? palette.glassHighlight : palette.glassBorder,
              ),
            ),
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent, shape: stadium),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: palette.surface2),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.modal,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: palette.glassBorder),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: light ? Colors.white : const Color(0xFF000000),
      elevation: 12,
      shadowColor: const Color(0x80000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: palette.glassBorder),
      ),
    ),
    extensions: [WiretuneColors(palette, accent, section)],
  );
}

/// The slider's rail: the played part is a gradient of the active colour, brightest at the knob, over a soft glow of
/// the same colour.
class GlowTrackShape extends RoundedRectSliderTrackShape {
  const GlowTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final radius = Radius.circular(rect.height / 2);
    final inactive = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    ).evaluate(enableAnimation)!;
    final active = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    ).evaluate(enableAnimation)!;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), Paint()..color = inactive);

    final ltr = textDirection == TextDirection.ltr;
    final played = ltr
        ? Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx.clamp(rect.left, rect.right), rect.bottom)
        : Rect.fromLTRB(thumbCenter.dx.clamp(rect.left, rect.right), rect.top, rect.right, rect.bottom);
    if (played.width <= 0) return;
    final shape = RRect.fromRectAndRadius(played, radius);
    if (isEnabled) {
      canvas.drawRRect(
        shape,
        Paint()
          ..color = active.withValues(alpha: active.a * 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    final faded = active.withValues(alpha: active.a * 0.55);
    canvas.drawRRect(
      shape,
      Paint()..shader = LinearGradient(colors: ltr ? [faded, active] : [active, faded]).createShader(played),
    );
  }
}

/// The slider's knob: a white dot with a soft shadow, a little larger while it is held.
class KnobThumbShape extends SliderComponentShape {
  const KnobThumbShape({this.radius = 7});

  final double radius;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius + 2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final r = radius + 2 * activationAnimation.value;
    final color = Color.lerp(sliderTheme.disabledThumbColor, Colors.white, enableAnimation.value)!;
    canvas.drawCircle(
      center.translate(0, 1),
      r,
      Paint()
        ..color = const Color(0x59000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, r, Paint()..color = color);
  }
}
