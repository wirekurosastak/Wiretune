// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../localization.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';

/// The quality tag: a small pill in the colour of the tier the recording is in, reading for example `FLAC 24bit/96kHz`
/// (gold), `FLAC 16bit/44.1kHz` (silver) or `MP3 320kbps` (bronze); the colour alone names the tier. It has a fill and
/// an outline of its own, so the three medal colours keep their contrast in both themes. Hovering explains the tier.
class QualityTag extends StatelessWidget {
  const QualityTag({super.key, required this.tier, this.spec, this.fontSize = 10, this.padding});

  final QualityTier tier;

  /// The format, e.g. "FLAC 24bit/96kHz" or "MIXED"; empty shows the tier word alone.
  final String? spec;
  final double fontSize;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    context.tr('QualityGold'); // rebuild when the language changes
    final text = tier.tagText(spec);
    final hint = tier.hint;
    return Tooltip(
      message: hint,
      child: Container(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: MedalColors.bg(tier),
          border: Border.all(color: MedalColors.border(tier)),
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: MedalColors.fg(tier),
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

/// A small pill tinted with its colour: "ARTIST", "ALBUM", "TRACK", a counter.
class TagBadge extends StatelessWidget {
  const TagBadge(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      text,
      maxLines: 1,
      style: TextStyle(fontSize: 10, letterSpacing: 0.8, height: 1.4, fontWeight: FontWeight.w800, color: color),
    ),
  );
}

/// A compact badge for track metadata (BPM, bitrate) displayed in the players.
class PlayerMetaBadge extends StatelessWidget {
  const PlayerMetaBadge({super.key, required this.text, this.fontSize = 10});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.glassBorder),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: colors.textMuted,
          height: 1.3,
        ),
      ),
    );
  }
}
