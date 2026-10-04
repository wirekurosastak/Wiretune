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
  Color get pressed => palette.pressedOf(accent);
  Color get textMain => palette.textMain;
  Color get textMuted => palette.textMuted;
  Color get surface1 => palette.surface1;
  Color get surface2 => palette.surface2;
  Color get glassBorder => palette.glassBorder;
  Color get danger => palette.danger;
  Color get onAccent => palette.onAccent;
  Color get tagBackground => palette.tagBackground;
  Gradient get windowGradient => palette.gradientFor(section);

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

ThemeData buildTheme({
  required bool light,
  required AppSection section,
  required bool isTv,
  bool desktopFonts = false,
}) {
  final palette = light ? Palette.light : Palette.dark;
  final accent = palette.accentFor(section);
  // Text and icons on an accent-filled button: white in the dark theme, black in the light one.
  final onAccent = palette.onAccent;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: light ? Brightness.light : Brightness.dark)
      .copyWith(
        primary: accent,
        onPrimary: onAccent,
        secondary: accent,
        surface: light ? const Color(0xFFFFFFFF) : const Color(0xFF0E0F11),
        onSurface: palette.textMain,
        error: palette.danger,
      );

  final focus = accent.withValues(alpha: isTv ? 0.45 : 0.25);
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
    canvasColor: light ? const Color(0xFFFFFFFF) : const Color(0xFF0E0F11),
    focusColor: focus,
    hoverColor: palette.surface1,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: isTv ? VisualDensity.comfortable : VisualDensity.standard,
    dividerColor: palette.glassBorder,
    textTheme: Typography.material2021(platform: TargetPlatform.android).englishLike
        .merge(light ? Typography.blackMountainView : Typography.whiteMountainView)
        .apply(bodyColor: palette.textMain, displayColor: palette.textMain),
    iconTheme: IconThemeData(color: palette.textMain),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: light ? const Color(0xF0202020) : const Color(0xF0303438),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    // Sliders: a 4 px track and an 18 px thumb in the accent colour (grey when there is nothing to move).
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: palette.glassHighlight,
      thumbColor: accent,
      disabledThumbColor: palette.textMuted,
      disabledActiveTrackColor: palette.textMuted,
      disabledInactiveTrackColor: palette.glassHighlight,
      overlayColor: accent.withValues(alpha: 0.15),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, disabledThumbRadius: 9, elevation: 0),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : palette.textMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : palette.surface2),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface1,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: palette.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: palette.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: palette.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    // The "primary" and "secondary" buttons: 38 px high, 6 px corners, bold 13 px text.
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: onAccent,
            disabledBackgroundColor: palette.surface2,
            minimumSize: const Size(0, 38),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            foregroundColor: palette.textMain,
            backgroundColor: palette.glassBackground,
            minimumSize: const Size(0, 38),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            side: BorderSide(color: palette.glassBorder),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.hovered) ? palette.glassHighlight : palette.glassBackground,
            ),
            side: WidgetStateProperty.resolveWith(
              (s) => BorderSide(color: s.contains(WidgetState.hovered) ? palette.glassHighlight : palette.glassBorder),
            ),
          ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: palette.surface2),
    dialogTheme: DialogThemeData(backgroundColor: palette.modal),
    popupMenuTheme: PopupMenuThemeData(color: light ? Colors.white : const Color(0xFF16181B)),
    extensions: [WiretuneColors(palette, accent, section)],
  );
}
