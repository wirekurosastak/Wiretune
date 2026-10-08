// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;
import 'dart:typed_data';

/// A 64-band real-time analyser of the audible spectrum (32 Hz to 20 kHz): a 2048-point FFT of the PCM window, the
/// energy of each band with a perceptual weighting, shown on a -54..-6 dBFS scale with an instant attack and a smooth
/// release.
class SpectrumAnalyzer {
  SpectrumAnalyzer() {
    for (var i = 0; i < fftSize; i++) {
      _hannWindow[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (fftSize - 1)));
    }
    reset();
  }

  static const int numBands = 64;
  static const int fftSize = 2048;

  /// FFT bins of each band at 44.1 kHz (21.533 Hz per bin), covering up to 20 kHz.
  static const List<(int, int)> _bandBinRanges = [
    (1, 2),
    (2, 2),
    (2, 2),
    (2, 2),
    (2, 2),
    (2, 3),
    (3, 3),
    (3, 3),
    (3, 4),
    (4, 4),
    (4, 4),
    (4, 5),
    (5, 5),
    (5, 6),
    (6, 7),
    (7, 7),
    (7, 8),
    (8, 9),
    (9, 10),
    (10, 11),
    (11, 12),
    (12, 13),
    (13, 15),
    (15, 16),
    (16, 18),
    (18, 20),
    (20, 22),
    (22, 24),
    (24, 27),
    (27, 30),
    (30, 33),
    (33, 37),
    (37, 41),
    (41, 45),
    (45, 50),
    (50, 55),
    (55, 61),
    (61, 68),
    (68, 75),
    (75, 83),
    (83, 92),
    (92, 102),
    (102, 112),
    (112, 124),
    (124, 138),
    (138, 153),
    (153, 169),
    (169, 187),
    (187, 207),
    (207, 229),
    (229, 254),
    (254, 281),
    (281, 311),
    (311, 344),
    (344, 381),
    (381, 422),
    (422, 467),
    (467, 517),
    (517, 573),
    (573, 634),
    (634, 702),
    (702, 777),
    (777, 861),
    (861, 929),
  ];

  /// Perceptual weighting that compensates the natural roll-off of music towards the treble.
  static const List<double> _isoBandWeights = [
    1.55, 1.50, 1.45, 1.40, 1.35, 1.30, 1.25, 1.23,
    1.20, 1.18, 1.15, 1.13, 1.10, 1.08, 1.06, 1.03,
    1.01, 1.00, 1.00, 1.02, 1.04, 1.07, 1.09, 1.12,
    1.14, 1.17, 1.19, 1.21, 1.24, 1.26, 1.29, 1.31,
    1.34, 1.37, 1.42, 1.47, 1.52, 1.58, 1.65, 1.73,
    1.80, 1.88, 1.98, 2.08, 2.18, 2.29, 2.41, 2.54,
    2.69, 2.83, 2.98, 3.13, 3.31, 3.48, 3.68, 3.88,
    4.07, 4.27, 4.47, 4.66, 4.86, 5.06, 5.25, 5.45,
  ];

  static const double _attackRate = 0.88;
  static const double _decayRate = 0.76;
  static const double _minFloor = 0.04;

  final Float32List _currentLevels = Float32List(numBands);
  final Float32List _hannWindow = Float32List(fftSize);
  final Float32List _fftReal = Float32List(fftSize);
  final Float32List _fftImag = Float32List(fftSize);
  final Float32List _magnitude = Float32List(fftSize ~/ 2);

  void reset() {
    for (var i = 0; i < numBands; i++) {
      _currentLevels[i] = _minFloor;
    }
  }

  /// The 32 band levels (0..1) of [pcmWindow] (at least [fftSize] samples, -1..1). While not playing, the bars fall.
  Float32List processPcm(Float32List pcmWindow, {required bool isPlaying}) {
    final result = Float32List(numBands);
    if (!isPlaying || pcmWindow.length < fftSize) {
      for (var i = 0; i < numBands; i++) {
        _currentLevels[i] = math.max(_minFloor, _currentLevels[i] * 0.70);
        result[i] = _currentLevels[i];
      }
      return result;
    }

    for (var i = 0; i < fftSize; i++) {
      _fftReal[i] = pcmWindow[i] * _hannWindow[i];
      _fftImag[i] = 0;
    }
    _computeFft(_fftReal, _fftImag, fftSize);

    const norm = 2.0 / fftSize;
    for (var i = 0; i < fftSize ~/ 2; i++) {
      _magnitude[i] = math.sqrt(_fftReal[i] * _fftReal[i] + _fftImag[i] * _fftImag[i]) * norm;
    }

    for (var band = 0; band < numBands; band++) {
      final (startBin, endBin) = _bandBinRanges[band];
      var sumSq = 0.0;
      for (var k = startBin; k <= endBin; k++) {
        sumSq += _magnitude[k] * _magnitude[k];
      }
      final rms = math.sqrt(sumSq / (endBin - startBin + 1)) * _isoBandWeights[band];

      // dBFS on a -54..-6 scale.
      final db = 20.0 * math.log(rms + 1e-5) / math.ln10;
      final target = ((db + 54.0) / 48.0).clamp(_minFloor, 1.0);
      _applyBallistics(band, target);
      result[band] = _currentLevels[band];
    }
    return result;
  }

  void _applyBallistics(int band, double target) {
    final current = _currentLevels[band];
    _currentLevels[band] = target > current
        ? current + (target - current) * _attackRate
        : current * _decayRate + target * (1.0 - _decayRate);
  }

  /// In-place iterative radix-2 Cooley-Tukey FFT.
  static void _computeFft(Float32List real, Float32List imag, int n) {
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }

    for (var len = 2; len <= n; len <<= 1) {
      final angle = -2.0 * math.pi / len;
      final wlenR = math.cos(angle);
      final wlenI = math.sin(angle);
      final half = len >> 1;
      for (var i = 0; i < n; i += len) {
        var wR = 1.0;
        var wI = 0.0;
        for (var j = 0; j < half; j++) {
          final uR = real[i + j];
          final uI = imag[i + j];
          final vR = real[i + j + half] * wR - imag[i + j + half] * wI;
          final vI = real[i + j + half] * wI + imag[i + j + half] * wR;
          real[i + j] = uR + vR;
          imag[i + j] = uI + vI;
          real[i + j + half] = uR - vR;
          imag[i + j + half] = uI - vI;
          final nextWR = wR * wlenR - wI * wlenI;
          wI = wR * wlenI + wI * wlenR;
          wR = nextWR;
        }
      }
    }
  }
}
