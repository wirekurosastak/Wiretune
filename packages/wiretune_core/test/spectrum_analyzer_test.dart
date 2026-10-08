// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

Float32List _tone(double frequency) => Float32List.fromList([
  for (var i = 0; i < SpectrumAnalyzer.fftSize; i++) 0.8 * math.sin(2 * math.pi * frequency * i / 44100),
]);

void main() {
  test('when playback stops the bars fall to the floor, whatever the window still holds', () {
    final analyzer = SpectrumAnalyzer();
    expect(analyzer.processPcm(_tone(1000), isPlaying: true)[36], greaterThan(0.40));
    var bands = Float32List(SpectrumAnalyzer.numBands);
    for (var i = 0; i < 20; i++) {
      bands = analyzer.processPcm(_tone(1000), isPlaying: false);
    }
    expect(bands, hasLength(64));
    for (final level in bands) {
      expect(level, lessThanOrEqualTo(0.10));
    }
  });

  test('a 20 Hz sub-bass tone lights band 0 (down to 20 Hz)', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(20), isPlaying: true);
    expect(bands[0], greaterThan(0.40));
    expect(bands[30], lessThan(0.15));
    expect(bands[63], lessThan(0.15));
  });

  test('a 100 Hz tone lights the bass bands only', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(100), isPlaying: true);
    expect(math.max(bands[14], bands[15]), greaterThan(0.40));
    expect(bands[0], lessThan(0.15));
    expect(bands[55], lessThan(0.15));
    expect(bands[63], lessThan(0.15));
  });

  test('a 1 kHz tone lights the 1 kHz band', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(1000), isPlaying: true);
    expect(math.max(bands[35], bands[36]), greaterThan(0.40));
    expect(bands[0], lessThan(0.15));
  });

  test('an 18 kHz tone lights the highest band (up to 20 kHz)', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(18000), isPlaying: true);
    expect(math.max(bands[62], bands[63]), greaterThan(0.40));
    expect(bands[0], lessThan(0.15));
  });

  test('silence stays at the resting floor', () {
    final bands = SpectrumAnalyzer().processPcm(Float32List(SpectrumAnalyzer.fftSize), isPlaying: true);
    for (final level in bands) {
      expect(level, lessThanOrEqualTo(0.08));
    }
  });
}
