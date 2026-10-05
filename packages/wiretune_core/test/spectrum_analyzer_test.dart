// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
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
    expect(analyzer.processPcm(_tone(1000), isPlaying: true)[17], greaterThan(0.40));
    var bands = Float32List(SpectrumAnalyzer.numBands);
    for (var i = 0; i < 20; i++) {
      bands = analyzer.processPcm(_tone(1000), isPlaying: false);
    }
    expect(bands, hasLength(32));
    for (final level in bands) {
      expect(level, lessThanOrEqualTo(0.10));
    }
  });

  test('a 100 Hz tone lights the bass bands only', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(100), isPlaying: true);
    expect(math.max(bands[5], bands[6]), greaterThan(0.40));
    expect(bands[29], lessThan(0.15));
    expect(bands[31], lessThan(0.15));
  });

  test('a 1 kHz tone lights the 1 kHz band', () {
    final bands = SpectrumAnalyzer().processPcm(_tone(1000), isPlaying: true);
    expect(bands[17], greaterThan(0.40));
    expect(bands[0], lessThan(0.15));
  });

  test('silence stays at the resting floor', () {
    final bands = SpectrumAnalyzer().processPcm(Float32List(SpectrumAnalyzer.fftSize), isPlaying: true);
    for (final level in bands) {
      expect(level, lessThanOrEqualTo(0.08));
    }
  });
}
