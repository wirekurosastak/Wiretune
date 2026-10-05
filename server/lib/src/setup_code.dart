// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:math';

import 'package:wiretune_core/wiretune_core.dart';

/// The secret that lets the first caller create the administrator account. Without it, whoever reaches a server that
/// starts with an empty data directory first (an unpersisted container volume, a wrong data path) would own the server.
/// The operator reads it from the server's log, or chooses one with `--setup-code`.
class SetupCode {
  /// [configured] is the operator's own code; null or blank makes the server create a random one.
  SetupCode(String? configured) : value = _normalize(configured?.trim()).isEmpty ? _generate() : configured!.trim() {
    _normalized = utf8.encode(_normalize(value));
  }

  // No 0/O, 1/I/L: the code is read from a log and typed by hand.
  static const String _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  final String value;
  late final List<int> _normalized;

  /// Case, spaces and dashes do not matter, so "abcd efgh" matches "ABCD-EFGH". Compared in constant time.
  bool matches(String? candidate) {
    final given = utf8.encode(_normalize(candidate));
    if (given.isEmpty) return false;
    var difference = given.length ^ _normalized.length;
    for (var i = 0; i < _normalized.length; i++) {
      difference |= _normalized[i] ^ (i < given.length ? given[i] : 0);
    }
    return difference == 0;
  }

  static String _normalize(String? value) => value == null ? '' : lettersAndDigits(value).toUpperCase();

  static String _generate() {
    final random = Random.secure();
    final chars = List.generate(8, (_) => _alphabet[random.nextInt(_alphabet.length)]).join();
    return '${chars.substring(0, 4)}-${chars.substring(4)}';
  }
}
