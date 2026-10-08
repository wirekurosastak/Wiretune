// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

const _song =
    '[ar:Anita Baker]\n[ti:Caught Up in the Rapture]\n'
    '[00:02.56] Pa, pa, pa, pa\n[00:05.46]\n[00:20.85] When we met, I always knew\n[01:12.75]Nothing else can compare\n';

Duration _s(double seconds) => Duration(microseconds: (seconds * 1000000).round());

void main() {
  test('reads times and text and skips headers', () {
    final lines = LrcParser.parse(_song);
    expect(lines, hasLength(4));
    expect(lines[0].time, _s(2.56));
    expect(lines[0].text, 'Pa, pa, pa, pa');
    expect(lines[1].isBlank, isTrue);
    expect(lines[3].time, _s(72.75));
  });

  test('plain text is not synced', () {
    expect(LrcParser.parse('Just words\nwithout any times'), isEmpty);
    expect(LrcParser.parse(null), isEmpty);
    expect(LrcParser.parse('[00:01.00] only one timed line'), isEmpty);
  });

  test('a line with several time tags repeats and sorts', () {
    final lines = LrcParser.parse('[00:30.00][01:10.00]Chorus\n[00:10.00]Verse\n');
    expect(lines.map((l) => l.text), ['Verse', 'Chorus', 'Chorus']);
    expect(lines.map((l) => l.time.inSeconds), [10, 30, 70]);
  });

  test('drops word timestamps and understands fraction lengths', () {
    final lines = LrcParser.parse('[00:01.5]<00:01.50>Hello <00:02.00>world\n[00:03.123]Next\n');
    expect(lines[0].text, 'Hello world');
    expect(lines[0].time, _s(1.5));
    expect(lines[1].time, _s(3.123));
  });

  test('applies the offset header', () {
    final lines = LrcParser.parse('[offset:+500]\n[00:10.00]A\n[00:20.00]B\n');
    expect(lines[0].time, _s(9.5)); // a positive offset makes the lyrics appear sooner
    expect(lines[1].time, _s(19.5));
  });

  test('indexAt finds the current line', () {
    final lines = LrcParser.parse(_song);
    expect(LrcParser.indexAt(lines, _s(1)), -1); // before the first line
    expect(LrcParser.indexAt(lines, _s(2.56)), 0); // exactly on it
    expect(LrcParser.indexAt(lines, _s(10)), 1); // in the gap
    expect(LrcParser.indexAt(lines, _s(60)), 2);
    expect(LrcParser.indexAt(lines, const Duration(minutes: 10)), 3); // after the last
  });
}
