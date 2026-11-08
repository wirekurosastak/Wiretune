// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;
import 'package:wiretune_core/wiretune_core.dart';

/// The app's colours, dark ones only (as in TIDAL and Spotify): neutral ones, but for the accent, which is the colour
/// of the song that plays ([accentOf]), and the favourites' red.
class Palette {
  const Palette({
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
    required this.favorite,
    required this.neutral,
    required this.onAccent,
    required this.shadow,
  });

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

  /// The favourites' red: a favourite's heart, whatever the accent.
  final Color favorite;

  /// The accent while nothing plays, or what plays has a grey cover or none: a soft white.
  final Color neutral;

  /// Text and icons on an accent-filled surface.
  final Color onAccent;

  /// The drop shadow under floating panels and covers.
  final Color shadow;

  static const dark = Palette(
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
    favorite: Color(0xFFFB7185),
    neutral: Color(0xFFE2E8F0),
    onAccent: Color(0xFF07070B),
    shadow: Color(0x99000000),
  );

  /// The accent for the colour of the cover of what plays (`CoverColor.of`; null for none, or a grey one: the
  /// [neutral]): its hue, about as colourful as the cover is (a muted cover a muted accent, a loud one not a neon one),
  /// at a lightness the eye sees as light whatever the hue, so that text in it and [onAccent] on it read (Material's
  /// tone).
  Color accentOf(Color? cover) {
    if (cover == null) return neutral;
    final hct = Hct.fromInt(cover.toARGB32());
    return Color(Hct.from(hct.hue, hct.chroma.clamp(_leastChroma, _mostChroma), 72).toInt());
  }

  /// How colourful an accent is at least (clearly a colour, not a grey) and at most (not a neon).
  static const double _leastChroma = 24, _mostChroma = 60;

  /// [accent] under the mouse: a little lighter.
  Color hoverOf(Color accent) => _lighter(accent, 0.1);

  /// [accent] pressed: a little deeper.
  Color pressedOf(Color accent) => _lighter(accent, -0.1);

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
