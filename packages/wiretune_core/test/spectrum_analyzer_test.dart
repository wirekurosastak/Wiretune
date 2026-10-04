import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

Float32List _tone(double frequency) => Float32List.fromList([
  for (var i = 0; i < SpectrumAnalyzer.fftSize; i++) 0.8 * math.sin(2 * math.pi * frequency * i / 44100),
]);

void main() {
  test('processFrame returns 32 normalised bands', () {
    final bands = SpectrumAnalyzer().processFrame(const Duration(seconds: 1), isPlaying: true);
    expect(bands, hasLength(32));
    for (final level in bands) {
      expect(level, inInclusiveRange(0.04, 1.0));
    }
  });

  test('processFrame moves the bass, the mids and the treble', () {
    final analyzer = SpectrumAnalyzer();
    var bass = 0.0, mid = 0.0, treble = 0.0;
    for (var frame = 0; frame < 30; frame++) {
      final bands = analyzer.processFrame(Duration(milliseconds: frame * 33), isPlaying: true);
      bass = math.max(bass, bands[2]);
      mid = math.max(mid, bands[17]);
      treble = math.max(treble, bands[29]);
    }
    expect(bass, greaterThan(0.35));
    expect(mid, greaterThan(0.35));
    expect(treble, greaterThan(0.35));
  });

  test('when stopped the bars fall to the floor', () {
    final analyzer = SpectrumAnalyzer();
    analyzer.processFrame(const Duration(milliseconds: 500), isPlaying: true);
    var bands = analyzer.processFrame(const Duration(seconds: 1), isPlaying: true);
    for (var i = 0; i < 20; i++) {
      bands = analyzer.processFrame(const Duration(seconds: 1), isPlaying: false);
    }
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
