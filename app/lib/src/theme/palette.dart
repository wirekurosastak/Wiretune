// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// The colours of one theme (dark or light): neutral ones, as in TIDAL. The one colour of a screen comes from its
/// cover: the wash colour ([washOf], `WashColor`).
class Palette {
  const Palette({
    required this.isDark,
    required this.background,
    required this.panel,
    required this.surface1,
    required this.surface2,
    required this.glassBackground,
    required this.glassBorder,
    required this.glassHighlight,
    required this.textMain,
    required this.textMuted,
    required this.textDisabled,
    required this.success,
    required this.warning,
    required this.danger,
    required this.modal,
    required this.panelBorder,
    required this.neutral,
    required this.onAccent,
    required this.shadow,
  });

  final bool isDark;
  final Color background;

  /// A translucent surface over the backdrop (the sign-in card, a notice, the empty state's orb), so that the
  /// backdrop's colours glow through.
  final Color panel;
  final Color surface1;
  final Color surface2;
  final Color glassBackground;
  final Color glassBorder;
  final Color glassHighlight;
  final Color textMain;
  final Color textMuted;
  final Color textDisabled;
  final Color success;
  final Color warning;
  final Color danger;

  /// The solid surfaces: the floating panels and bars, the opaque cards, dialogs, menus and sheets.
  final Color modal;

  /// The hairline edge of the floating panels, the bars and the opaque cards.
  final Color panelBorder;

  /// The accent of what lies on the wash itself (a page's Play, a selected tab, the playing row), where the wash
  /// colour would not stand out, and of everything while there is no wash colour: a soft white on the dark theme, a
  /// slate on the light one.
  final Color neutral;

  /// Text and icons on an accent-filled surface (the wash colour's or the neutral's).
  final Color onAccent;

  /// The drop shadow under floating panels and covers.
  final Color shadow;

  static const dark = Palette(
    isDark: true,
    background: Color(0xFF060609),
    panel: Color(0xB80C0C12),
    surface1: Color(0x0FFFFFFF),
    surface2: Color(0x1AFFFFFF),
    glassBackground: Color(0x0AFFFFFF),
    glassBorder: Color(0x14FFFFFF),
    glassHighlight: Color(0x26FFFFFF),
    textMain: Color(0xFFF7F7FA),
    textMuted: Color(0xFFAEB5C2),
    textDisabled: Color(0xFF5E6070),
    success: Color(0xFF34F5A0),
    warning: Color(0xFFFFC53D),
    danger: Color(0xFFFF3B6B),
    modal: Color(0xFF000000),
    panelBorder: Color(0x2EFFFFFF),
    neutral: Color(0xFFE2E8F0),
    onAccent: Color(0xFF07070B),
    shadow: Color(0x99000000),
  );

  static const light = Palette(
    isDark: false,
    background: Color(0xFFF2F3F7),
    panel: Color(0xC7FFFFFF),
    surface1: Color(0x0C000000),
    surface2: Color(0x16000000),
    glassBackground: Color(0x08000000),
    glassBorder: Color(0x14000000),
    glassHighlight: Color(0x2A000000),
    textMain: Color(0xFF0E0E14),
    textMuted: Color(0xFF2B3648),
    textDisabled: Color(0xFF64748B),
    success: Color(0xFF0E9F6E),
    warning: Color(0xFFD97706),
    danger: Color(0xFFE11D48),
    modal: Color(0xFFFFFFFF),
    panelBorder: Color(0x22000000),
    neutral: Color(0xFF1E293B),
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x2E1A1A33),
  );

  /// A cover's colour (`WashColor.sourceOf`) as this theme's wash colour: vivid, as the wash is, light on the dark
  /// theme and deep on the light one, and kept within the luminance at which text in it and [onAccent] on it read,
  /// whatever its hue. Within that a hue keeps its own brightness: a red stays red rather than pink, a yellow yellow.
  Color washOf(Color source) {
    final hsl = HSLColor.fromColor(source);
    final colour = hsl.withSaturation((hsl.saturation * 1.3).clamp(0.5, 0.9)).withLightness(isDark ? 0.6 : 0.42);
    final (least, most) = isDark ? (0.28, 0.6) : (0.07, 0.18);
    final luminance = colour.toColor().computeLuminance();
    if (luminance >= least && luminance <= most) return colour.toColor();
    final target = luminance < least ? least : most;
    var low = 0.0, high = 1.0;
    for (var i = 0; i < 14; i++) {
      final mid = (low + high) / 2;
      if (colour.withLightness(mid).toColor().computeLuminance() < target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return colour.withLightness((low + high) / 2).toColor();
  }

  /// [accent] under the mouse: a little lighter.
  Color hoverOf(Color accent) => _lighter(accent, isDark ? 0.1 : 0.06);

  /// [accent] pressed: a little deeper.
  Color pressedOf(Color accent) => _lighter(accent, isDark ? -0.1 : -0.08);

  static Color _lighter(Color color, double by) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness + by).clamp(0.0, 1.0)).toColor();
  }
}

/// The quality tag's own colours, the same in both themes so the medals keep their contrast.
abstract final class MedalColors {
  static const List<Color> foreground = [Color(0xFFE39A57), Color(0xFFD3DAE3), Color(0xFFF5C842)];
  static const List<Color> fill = [Color(0xFF33200F), Color(0xFF272C33), Color(0xFF2E250E)];
  static const List<Color> outline = [Color(0xFF8A5428), Color(0xFF6C7683), Color(0xFF8A6D1F)];

  static Color fg(QualityTier tier) => foreground[tier.index];
  static Color bg(QualityTier tier) => fill[tier.index];
  static Color border(QualityTier tier) => outline[tier.index];
}
