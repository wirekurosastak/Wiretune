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
  const QualityTag({super.key, required this.tier, this.spec, this.fontSize = 10, this.padding, this.details});

  final QualityTier tier;

  /// The format, e.g. "FLAC 24bit/96kHz" or "MIXED"; empty shows the tier word alone.
  final String? spec;
  final double fontSize;
  final EdgeInsetsGeometry? padding;

  /// A line over the tier's explanation in the tooltip: the player bar's bitrate and BPM.
  final String? details;

  @override
  Widget build(BuildContext context) {
    context.tr('QualityGold'); // rebuild when the language changes
    final text = tier.tagText(spec);
    final hint = tier.hint;
    return Tooltip(
      message: details == null || details!.isEmpty ? hint : '$details\n$hint',
      child: Container(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: MedalColors.bg(tier),
          border: Border.all(color: MedalColors.border(tier)),
          borderRadius: BorderRadius.circular(Radii.tag),
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

/// The playing track's tags under the phone's full-screen cover: its BPM, its quality, and its bitrate in the quality's
/// colours where the quality's tag doesn't say it already (a lossy file's does: "MP3 320kbps"). Where room is short the
/// quality's tag ends in an ellipsis.
class PlayerTags extends StatelessWidget {
  const PlayerTags({super.key, required this.track, this.fontSize = 10});

  final Track track;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final bpm = track.bpm;
    final format = track.format;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (bpm != null && bpm > 0) PlayerMetaBadge(text: '$bpm BPM', fontSize: fontSize),
        Flexible(
          child: QualityTag(tier: format.tier, spec: format.tagSpec, fontSize: fontSize),
        ),
        if (bitrateShown(format))
          QualityTag(tier: format.tier, spec: context.trf('BitrateKbps', [format.bitrateKbps]), fontSize: fontSize),
      ],
    );
  }

  /// Whether a tag of its own says [format]'s bitrate: a lossy file's quality tag says it already.
  static bool bitrateShown(AudioFormat format) => format.isLossless && format.bitrateKbps > 0;
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
      borderRadius: BorderRadius.circular(Radii.pill),
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
        borderRadius: BorderRadius.circular(Radii.tag),
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
