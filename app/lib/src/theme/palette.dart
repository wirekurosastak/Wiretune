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
    success: Color(0xFF30D158),
    warning: Color(0xFFFFC53D),
    danger: Color(0xFFFF453A),
    modal: Color(0xFF000000),
    panelBorder: Color(0x2EFFFFFF),
    favorite: Color(0xFFFF453A),
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

/// The quality tiers' colours, the same in both themes: bronze, silver and gold. A quality tag is the metal itself
/// ([metal], [ink]); a switch or a mode's badge takes the tier's colour on a dark fill ([fg], [bg], [border]).
abstract final class MedalColors {
  static const List<Color> foreground = [Color(0xFFE39A57), Color(0xFFD3DAE3), Color(0xFFF5C842)];
  static const List<Color> fill = [Color(0xFF33200F), Color(0xFF272C33), Color(0xFF2E250E)];
  static const List<Color> outline = [Color(0xFF8A5428), Color(0xFF6C7683), Color(0xFF8A6D1F)];

  static Color fg(QualityTier tier) => foreground[tier.index];
  static Color bg(QualityTier tier) => fill[tier.index];
  static Color border(QualityTier tier) => outline[tier.index];

  /// Each metal lit from above: a bright top, the metal, its shade below the middle, and light caught again at the
  /// bottom edge.
  static const List<List<Color>> _metal = [
    [Color(0xFFFFE2C4), Color(0xFFEBAA6E), Color(0xFFB4693A), Color(0xFFDE9C66)],
    [Color(0xFFFFFFFF), Color(0xFFE3E7EC), Color(0xFFA6AFBB), Color(0xFFD6DCE3)],
    [Color(0xFFFFF6CC), Color(0xFFF8D55C), Color(0xFFC89220), Color(0xFFF1CB60)],
  ];
  static const List<Color> _ink = [Color(0xFF3A1D0A), Color(0xFF232931), Color(0xFF3B2701)];
  static const List<Color> _rim = [Color(0xFF8F5127), Color(0xFF7E8894), Color(0xFF9C7012)];

  /// The text on [tier]'s metal: as if engraved in it.
  static Color ink(QualityTier tier) => _ink[tier.index];

  /// A quality tag's face: [tier]'s metal with its rim, a shadow under it and a faint glow of its colour.
  static BoxDecoration metal(QualityTier tier, {required double radius}) => BoxDecoration(
    gradient: LinearGradient(
      begin: const Alignment(-0.3, -1),
      end: const Alignment(0.3, 1),
      colors: _metal[tier.index],
      stops: const [0, 0.4, 0.68, 1],
    ),
    border: Border.all(color: _rim[tier.index], width: 0.8),
    borderRadius: BorderRadius.circular(radius),
    boxShadow: [
      const BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(color: _metal[tier.index][1].withValues(alpha: 0.35), blurRadius: 8, spreadRadius: -2),
    ],
  );
}
