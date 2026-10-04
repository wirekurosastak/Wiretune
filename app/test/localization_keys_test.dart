import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Every string key the interface asks for exists in the table (a missing key would show its name on screen), and every
/// key in the table is used somewhere (by the app, the core or the server).
void main() {
  test('every key used in the app is in the string table', () {
    final call = RegExp(r"""(?:\btr|\btrf|Localizer\.get|Localizer\.format)\(\s*'([A-Za-z_]+)'""");
    // Keys chosen by a condition: context.tr(playing ? 'TipPause' : 'TipPlay').
    final conditional = RegExp(
      r"""(?:\btr|\btrf|Localizer\.get|Localizer\.format)\([^;)]*\?\s*'([A-Za-z_]+)'\s*:\s*'([A-Za-z_]+)'""",
    );
    final missing = <String>{};
    final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      final keys = [
        for (final m in call.allMatches(source)) m[1]!,
        for (final m in conditional.allMatches(source)) ...[m[1]!, m[2]!],
      ];
      missing.addAll(keys.where((k) => !allStrings.containsKey(k)).map((k) => '$k (${file.path})'));
    }
    expect(missing, isEmpty);
  });

  test('every key in the string table is used', () {
    // A key counts as used when any source file names it as a string literal: some are picked by a condition or a
    // table (a quality tier's word, a device's name key) rather than passed to tr() directly.
    final literal = RegExp(r"'([A-Za-z_]+)'");
    final used = <String>{};
    for (final root in ['lib', '../packages/wiretune_core/lib', '../server/lib']) {
      final files = Directory(root).listSync(recursive: true).whereType<File>();
      for (final file in files.where((f) => f.path.endsWith('.dart') && !f.path.endsWith('strings.dart'))) {
        used.addAll(literal.allMatches(file.readAsStringSync()).map((m) => m[1]!));
      }
    }
    final unused = allStrings.keys.where((k) => !used.contains(k.endsWith('_One') ? k.substring(0, k.length - 4) : k));
    expect(unused, isEmpty);
  });
}
