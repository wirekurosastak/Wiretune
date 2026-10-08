// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import '../util/sorting.dart';

/// One line of time-synced lyrics: the text and the moment it starts being sung.
class LrcLine {
  const LrcLine(this.time, this.text);

  final Duration time;
  final String text;

  /// An empty line is an instrumental gap: when it is current, no line is highlighted.
  bool get isBlank => text.isEmpty;

  @override
  bool operator ==(Object other) => other is LrcLine && other.time == time && other.text == text;

  @override
  int get hashCode => Object.hash(time, text);

  @override
  String toString() => '[$time] $text';
}

/// Reads time-synced lyrics in the LRC format (`[01:23.45] text`). Handles several time tags on one line, the
/// `[offset:+250]` header, word-level `<01:23.45>` tags and the `[ar:Artist]`-style headers.
abstract final class LrcParser {
  static final RegExp _timeTag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _wordTag = RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>\s?');
  static final RegExp _offsetTag = RegExp(r'^\s*\[offset:\s*([+-]?\d+)\s*\]\s*$', caseSensitive: false);

  /// The timed lines of [text], in playing order; empty when the text is not synced (plain lyrics, or fewer than two
  /// lines carrying a time tag).
  static List<LrcLine> parse(String? text) {
    if (text == null || text.trim().isEmpty) return const [];

    var offset = Duration.zero;
    final lines = <LrcLine>[];

    for (final raw in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final offsetMatch = _offsetTag.firstMatch(raw);
      if (offsetMatch != null) {
        // LRC: a positive offset makes the lyrics appear sooner, so it is subtracted from every time.
        final ms = int.tryParse(offsetMatch.group(1)!.replaceFirst('+', ''));
        if (ms != null) offset = Duration(milliseconds: -ms);
        continue;
      }

      final tags = _timeTag.allMatches(raw).toList();
      if (tags.isEmpty) continue; // headers ([ar:..]) and untimed lines have no place in a synced list

      // Every time tag sits at the start of the line, so the text is what follows the last one.
      final last = tags.last;
      final content = raw.substring(last.end).replaceAll(_wordTag, '').trim();
      for (final tag in tags) {
        lines.add(LrcLine(_timeOf(tag), content));
      }
    }

    if (lines.where((l) => !l.isBlank).length < 2) return const [];

    // Apply the offset after reading, so a header that comes after the lines still counts. The stable sort keeps the
    // order of lines that share one time.
    final shifted = [
      for (final l in lines) LrcLine(l.time + offset < Duration.zero ? Duration.zero : l.time + offset, l.text),
    ];
    sortStable(shifted, (a, b) => a.time.compareTo(b.time));
    return shifted;
  }

  /// The index of the line that is current at [position]: the last one that started at or before it, or -1 before the
  /// first line. [lines] must be sorted by time (as [parse] returns it).
  static int indexAt(List<LrcLine> lines, Duration position) {
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  static Duration _timeOf(RegExpMatch tag) {
    final minutes = int.parse(tag.group(1)!);
    final seconds = int.parse(tag.group(2)!);
    // ".5" is half a second, ".50" and ".500" too: pad to milliseconds (whole numbers, so no rounding drift).
    final digits = tag.group(3);
    final millis = digits == null ? 0 : int.parse(digits.padRight(3, '0'));
    return Duration(milliseconds: (minutes * 60 + seconds) * 1000 + millis);
  }
}
