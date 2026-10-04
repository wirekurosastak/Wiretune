// The wire and database formats the C# Wiretune used, kept so that a Dart server, a Dart player and an existing
// database or server written by the C# version understand each other.

/// Formats a duration the way .NET's `TimeSpan` constant format ("c") does: `[-][d.]hh:mm:ss[.fffffff]`. This is what
/// the server's JSON carries for track lengths, e.g. `00:03:45.1230000`.
String formatTimeSpan(Duration value) {
  final negative = value.isNegative;
  var micros = value.inMicroseconds.abs();
  final days = micros ~/ Duration.microsecondsPerDay;
  micros -= days * Duration.microsecondsPerDay;
  final hours = micros ~/ Duration.microsecondsPerHour;
  micros -= hours * Duration.microsecondsPerHour;
  final minutes = micros ~/ Duration.microsecondsPerMinute;
  micros -= minutes * Duration.microsecondsPerMinute;
  final seconds = micros ~/ Duration.microsecondsPerSecond;
  micros -= seconds * Duration.microsecondsPerSecond;

  final buffer = StringBuffer();
  if (negative) buffer.write('-');
  if (days > 0) buffer.write('$days.');
  buffer
    ..write(_two(hours))
    ..write(':')
    ..write(_two(minutes))
    ..write(':')
    ..write(_two(seconds));
  if (micros > 0) buffer.write('.${(micros * 10).toString().padLeft(7, '0')}');
  return buffer.toString();
}

final RegExp _timeSpanPattern = RegExp(r'^\s*(-)?(?:(\d+)\.)?(\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:\.(\d{1,7}))?)?\s*$');

/// Reads a .NET `TimeSpan` string (`00:03:45.1230000`, `1.02:03:04`); also accepts a plain number of seconds. Null when
/// [text] is neither.
Duration? parseTimeSpan(Object? text) {
  if (text == null) return null;
  if (text is num) return Duration(microseconds: (text * Duration.microsecondsPerSecond).round());
  if (text is! String) return null;

  final match = _timeSpanPattern.firstMatch(text);
  if (match == null) {
    final seconds = double.tryParse(text.trim());
    return seconds == null ? null : Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
  }

  final days = int.parse(match.group(2) ?? '0');
  final hours = int.parse(match.group(3)!);
  final minutes = int.parse(match.group(4)!);
  final seconds = int.parse(match.group(5) ?? '0');
  final fraction = match.group(6);
  final micros = fraction == null ? 0 : int.parse(fraction.padRight(7, '0')) ~/ 10;
  final duration = Duration(days: days, hours: hours, minutes: minutes, seconds: seconds, microseconds: micros);
  return match.group(1) == null ? duration : -duration;
}

/// The round-trip text of a UTC instant, as .NET's "O" format writes it: `2024-01-02T03:04:05.1234560Z` (always seven
/// fractional digits). Same-length strings sort in time order, which the server's SQL relies on.
String formatIsoUtc(DateTime value) {
  final utc = value.toUtc();
  final fraction = (utc.millisecond * 1000 + utc.microsecond) * 10;
  return '${utc.year.toString().padLeft(4, '0')}-${_two(utc.month)}-${_two(utc.day)}'
      'T${_two(utc.hour)}:${_two(utc.minute)}:${_two(utc.second)}.${fraction.toString().padLeft(7, '0')}Z';
}

/// Reads an ISO 8601 timestamp written by either version; one without an offset counts as UTC. Null when unreadable.
DateTime? parseIsoUtc(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  var text = value.trim();
  // DateTime.parse reads at most microseconds; .NET writes seven fractional digits.
  text = text.replaceFirstMapped(RegExp(r'\.(\d{7,})'), (m) => '.${m.group(1)!.substring(0, 6)}');
  final hasOffset = RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text);
  try {
    return DateTime.parse(hasOffset ? text : '${text}Z').toUtc();
  } on FormatException {
    return null;
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// `m:ss`, or `h:mm:ss` from an hour on: how the player shows a position or a length.
String formatClock(Duration value) {
  final total = value.isNegative ? Duration.zero : value;
  final hours = total.inHours;
  final minutes = total.inMinutes % 60;
  final seconds = total.inSeconds % 60;
  return hours > 0 ? '$hours:${_two(minutes)}:${_two(seconds)}' : '$minutes:${_two(seconds)}';
}

/// Upper-case hexadecimal, as .NET's `Convert.ToHexString` writes it; track and album IDs are made of it.
String toUpperHex(List<int> bytes) {
  const digits = '0123456789ABCDEF';
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer
      ..write(digits[(b >> 4) & 0xF])
      ..write(digits[b & 0xF]);
  }
  return buffer.toString();
}

/// Upper case as .NET's `ToUpperInvariant` writes it. Track and album IDs are hashes of such text, so they must match
/// the IDs an existing database and server hold. Character by character, with the simple case mapping (`ß` stays `ß`);
/// .NET's invariant casing leaves out the Turkish pair, so `ı` stays `ı` (Dart would write `I`).
String toUpperInvariant(String text) => _mapSimple(text, upper: true);

/// Lower case as .NET's `ToLowerInvariant` writes it: like [toUpperInvariant], and `İ` stays `İ` (Dart would write `i`).
String toLowerInvariant(String text) => _mapSimple(text, upper: false);

String _mapSimple(String text, {required bool upper}) {
  var ascii = true;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) > 0x7F) {
      ascii = false;
      break;
    }
  }
  if (ascii) return upper ? text.toUpperCase() : text.toLowerCase();

  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune == (upper ? 0x0131 : 0x0130)) {
      buffer.writeCharCode(rune);
      continue;
    }
    final char = String.fromCharCode(rune);
    final mapped = upper ? char.toUpperCase() : char.toLowerCase();
    buffer.write(mapped.runes.length == 1 ? mapped : char);
  }
  return buffer.toString();
}
