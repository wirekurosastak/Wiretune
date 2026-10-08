// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../view_models/app_section.dart';

/// The colours of one theme (dark or light). Each section has an accent family and a tint for the window's backdrop.
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
    required this.coral,
    required this.purple,
    required this.cyan,
    required this.lime,
    required this.hover,
    required this.pressed,
    required this.gradientMid,
    required this.gradients,
    required this.onAccent,
    required this.shadow,
  });

  final bool isDark;
  final Color background;

  /// The floating panels (sidebar, page, player bar): translucent, so the backdrop's colours glow through.
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
  final Color modal;
  final Color coral;
  final Color purple;
  final Color cyan;
  final Color lime;

  /// Hover and pressed shades of each accent family, by the accent's ARGB value.
  final Map<int, Color> hover;
  final Map<int, Color> pressed;
  final Color gradientMid;
  final Map<AppSection, Color> gradients;

  /// Text and icons on an accent-filled surface.
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
    coral: Color(0xFFFB7185),
    purple: Color(0xFFC084FC),
    cyan: Color(0xFF22D3EE),
    lime: Color(0xFFA3E635),
    hover: {
      0xFF22D3EE: Color(0xFF67E8F9),
      0xFFC084FC: Color(0xFFD8B4FE),
      0xFFFB7185: Color(0xFFFDA4AF),
      0xFFA3E635: Color(0xFFBEF264),
    },
    pressed: {
      0xFF22D3EE: Color(0xFF06B6D4),
      0xFFC084FC: Color(0xFFA855F7),
      0xFFFB7185: Color(0xFFF43F5E),
      0xFFA3E635: Color(0xFF84CC16),
    },
    onAccent: Color(0xFF07070B),
    shadow: Color(0x99000000),
    gradientMid: Color(0xFF060609),
    gradients: {
      AppSection.tracks: Color(0xFF060609),
      AppSection.albums: Color(0xFF060609),
      AppSection.artists: Color(0xFF060609),
      AppSection.playlists: Color(0xFF060609),
      AppSection.favorites: Color(0xFF060609),
      AppSection.settings: Color(0xFF060609),
    },
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
    coral: Color(0xFFE11D48),
    purple: Color(0xFF9333EA),
    cyan: Color(0xFF0891B2),
    lime: Color(0xFF16A34A),
    hover: {
      0xFF0891B2: Color(0xFF06A3C8),
      0xFF9333EA: Color(0xFFA855F7),
      0xFFE11D48: Color(0xFFF43F5E),
      0xFF16A34A: Color(0xFF22C55E),
    },
    pressed: {
      0xFF0891B2: Color(0xFF0E7490),
      0xFF9333EA: Color(0xFF7E22CE),
      0xFFE11D48: Color(0xFFBE123C),
      0xFF16A34A: Color(0xFF15803D),
    },
    onAccent: Color(0xFFFFFFFF),
    shadow: Color(0x2E1A1A33),
    gradientMid: Color(0xFFF2F3F7),
    gradients: {
      AppSection.tracks: Color(0xFFF2F3F7),
      AppSection.albums: Color(0xFFF2F3F7),
      AppSection.artists: Color(0xFFF2F3F7),
      AppSection.playlists: Color(0xFFF2F3F7),
      AppSection.favorites: Color(0xFFF2F3F7),
      AppSection.settings: Color(0xFFF2F3F7),
    },
  );

  /// The accent family a section is drawn in.
  Color accentFor(AppSection section) => switch (section) {
    AppSection.tracks => cyan,
    AppSection.albums => purple,
    AppSection.artists || AppSection.favorites => coral,
    AppSection.playlists => lime,
    AppSection.settings => isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
  };

  Color hoverOf(Color accent) => hover[accent.toARGB32()] ?? accent;
  Color pressedOf(Color accent) => pressed[accent.toARGB32()] ?? accent;

  /// The window gradient of a section: its tint in two corners, the neutral middle between them.
  Gradient gradientFor(AppSection section) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradients[section]!, gradientMid, gradients[section]!],
    stops: const [0, 0.5, 1],
  );
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
