// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// `m:ss`, or `h:mm:ss` from an hour on: how the player shows a position or a length.
String formatClock(Duration value) {
  final total = value.isNegative ? Duration.zero : value;
  String two(int v) => v.toString().padLeft(2, '0');
  final hours = total.inHours;
  final minutes = total.inMinutes % 60;
  final seconds = total.inSeconds % 60;
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '$minutes:${two(seconds)}';
}

/// [value] as the HTTP API writes instants: ISO 8601 in UTC.
String formatIsoUtc(DateTime value) => value.toUtc().toIso8601String();

/// The instant an ISO 8601 timestamp names, in UTC; null when [value] is not one.
DateTime? parseIsoUtc(Object? value) => value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// [value] as the database stores instants: microseconds since the epoch, so that a file's modification time survives
/// the round trip exactly.
int? toDbTime(DateTime? value) => value?.microsecondsSinceEpoch;

/// An instant as [toDbTime] stored it; null for null.
DateTime? fromDbTime(Object? value) => value is int ? DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true) : null;
