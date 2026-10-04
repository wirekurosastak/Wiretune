import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../localization.dart';
import '../theme/palette.dart';

/// The quality tag: a small pill in the colour of the tier the recording is in, reading for example `FLAC 24bit/96kHz`
/// (gold), `FLAC 16bit/44.1kHz` (silver) or `MP3 320kbps` (bronze); the colour alone names the tier. It has a fill and
/// an outline of its own, so the three medal colours keep their contrast in both themes. Hovering explains the tier.
class QualityTag extends StatelessWidget {
  const QualityTag({super.key, required this.tier, this.spec, this.compact = false, this.fontSize = 10});

  final QualityTier tier;

  /// The text after the tier word, e.g. "FLAC 24bit/96kHz" or "MIXED"; empty shows the tier word alone.
  final String? spec;

  /// For tiles, the queue and a narrow player bar: the resolution without the file format (`24bit/96kHz`).
  final bool compact;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    context.tr('QualityGold'); // rebuild when the language changes
    final text = tier.tagText(spec, compact: compact);
    final hint = compact && spec != null && spec!.trim().isNotEmpty ? '${tier.hint}\n${spec!.trim()}' : tier.hint;
    return Tooltip(
      message: hint,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: MedalColors.bg(tier),
          border: Border.all(color: MedalColors.border(tier)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: MedalColors.fg(tier), fontSize: fontSize, fontWeight: FontWeight.w900, height: 1.4),
        ),
      ),
    );
  }
}
