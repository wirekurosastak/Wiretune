import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../view_models/app_section.dart';

/// The colours of one theme (dark or light). The section accents and window gradients follow the original palette.
class Palette {
  const Palette({
    required this.isDark,
    required this.background,
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
    required this.tagBackground,
  });

  final bool isDark;
  final Color background;
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

  /// The small labels ("ARTIST", "ALBUM") and the sidebar's counters.
  final Color tagBackground;

  static const dark = Palette(
    isDark: true,
    background: Color(0xFF000000),
    surface1: Color(0x12FFFFFF),
    surface2: Color(0x1AFFFFFF),
    glassBackground: Color(0x0CFFFFFF),
    glassBorder: Color(0x1AFFFFFF),
    glassHighlight: Color(0x2AFFFFFF),
    textMain: Color(0xFFFFFFFF),
    textMuted: Color(0xFF8A8A8A),
    textDisabled: Color(0xFF444444),
    success: Color(0xFF00FF66),
    warning: Color(0xFFFFC800),
    danger: Color(0xFFFF003C),
    modal: Color(0xFF0A0A0A),
    coral: Color(0xFFFF6B6B),
    purple: Color(0xFFD05CE3),
    cyan: Color(0xFF67C8E0),
    lime: Color(0xFFAEEA00),
    hover: {
      0xFF67C8E0: Color(0xFF8BE0F5),
      0xFFD05CE3: Color(0xFFDF7DF0),
      0xFFFF6B6B: Color(0xFFFF8585),
      0xFFAEEA00: Color(0xFFC2FF1A),
    },
    pressed: {
      0xFF67C8E0: Color(0xFF4FB0C8),
      0xFFD05CE3: Color(0xFFB835CD),
      0xFFFF6B6B: Color(0xFFE05555),
      0xFFAEEA00: Color(0xFF95CA00),
    },
    onAccent: Color(0xFFFFFFFF),
    tagBackground: Color(0x1AFFFFFF),
    gradientMid: Color(0xFF000000),
    gradients: {
      AppSection.tracks: Color(0xFF051522),
      AppSection.albums: Color(0xFF1F0833),
      AppSection.artists: Color(0xFF2B0C0C),
      AppSection.playlists: Color(0xFF142400),
      AppSection.favorites: Color(0xFF2B0C0C),
      AppSection.settings: Color(0xFF091824),
    },
  );

  static const light = Palette(
    isDark: false,
    background: Color(0xFFF4F6F8),
    surface1: Color(0x1A000000),
    surface2: Color(0x26000000),
    glassBackground: Color(0x0D000000),
    glassBorder: Color(0x20000000),
    glassHighlight: Color(0x40000000),
    textMain: Color(0xFF111111),
    textMuted: Color(0xFF888888),
    textDisabled: Color(0xFFCCCCCC),
    success: Color(0xFF10893E),
    warning: Color(0xFFD83B01),
    danger: Color(0xFFFF003C),
    modal: Color(0xFFFFFFFF),
    coral: Color(0xFFD94A4A),
    purple: Color(0xFFA03BB5),
    cyan: Color(0xFF3A9FB8),
    lime: Color(0xFF7FB800),
    hover: {
      0xFF3A9FB8: Color(0xFF52B3CC),
      0xFFA03BB5: Color(0xFFB848CF),
      0xFFD94A4A: Color(0xFFE85D5D),
      0xFF7FB800: Color(0xFF91CF05),
    },
    pressed: {
      0xFF3A9FB8: Color(0xFF2A8F98),
      0xFFA03BB5: Color(0xFF88289E),
      0xFFD94A4A: Color(0xFFB83535),
      0xFF7FB800: Color(0xFF6B9900),
    },
    onAccent: Color(0xFF000000),
    tagBackground: Color(0xFF1E232A),
    gradientMid: Color(0xFFEEF1F5),
    gradients: {
      AppSection.tracks: Color(0xFFE8F7FC),
      AppSection.albums: Color(0xFFF3E9FF),
      AppSection.artists: Color(0xFFFFECEC),
      AppSection.playlists: Color(0xFFEEF9E6),
      AppSection.favorites: Color(0xFFFFECEC),
      AppSection.settings: Color(0xFFE8F7FC),
    },
  );

  /// The accent family a section is drawn in.
  Color accentFor(AppSection section) => switch (section) {
    AppSection.tracks || AppSection.settings => cyan,
    AppSection.albums => purple,
    AppSection.artists || AppSection.favorites => coral,
    AppSection.playlists => lime,
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
