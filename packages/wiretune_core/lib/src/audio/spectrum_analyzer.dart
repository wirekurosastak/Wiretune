// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;
import 'dart:typed_data';

/// A 64-band real-time analyser of the audible spectrum (20 Hz to 20 kHz): a 2048-point FFT of the PCM window, the
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

  /// FFT bins of each band at 44.1 kHz (21.533 Hz per bin), covering 20 Hz up to 20 kHz.
  static const List<(int, int)> _bandBinRanges = [
    (1, 1),
    (1, 1),
    (1, 1),
    (1, 1),
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
    (4, 5),
    (5, 5),
    (5, 6),
    (6, 6),
    (6, 7),
    (7, 8),
    (8, 9),
    (9, 10),
    (10, 11),
    (11, 12),
    (12, 14),
    (14, 15),
    (15, 17),
    (17, 19),
    (19, 21),
    (21, 24),
    (24, 26),
    (26, 29),
    (29, 33),
    (33, 36),
    (36, 41),
    (41, 45),
    (45, 50),
    (50, 56),
    (56, 63),
    (63, 70),
    (70, 78),
    (78, 86),
    (86, 96),
    (96, 107),
    (107, 119),
    (119, 133),
    (133, 148),
    (148, 165),
    (165, 184),
    (184, 205),
    (205, 228),
    (228, 254),
    (254, 283),
    (283, 316),
    (316, 352),
    (352, 392),
    (392, 436),
    (436, 486),
    (486, 541),
    (541, 603),
    (603, 672),
    (672, 748),
    (748, 834),
    (834, 929),
  ];

  /// Center bin of each band for continuous sub-bass interpolation.
  static const List<double> _bandCenterBins = [
    0.980, 1.092, 1.216, 1.355, 1.510, 1.682, 1.873, 2.087,
    2.325, 2.590, 2.885, 3.214, 3.580, 3.988, 4.442, 4.949,
    5.513, 6.141, 6.841, 7.621, 8.489, 9.457, 10.534, 11.735,
    13.073, 14.562, 16.222, 18.071, 20.131, 22.425, 24.981, 27.828,
    31.000, 34.533, 38.469, 42.853, 47.737, 53.178, 59.239, 65.991,
    73.512, 81.891, 91.224, 101.621, 113.203, 126.105, 140.478, 156.489,
    174.325, 194.193, 216.326, 240.982, 268.447, 299.043, 333.126, 371.094,
    413.389, 460.504, 512.990, 571.457, 636.589, 709.143, 789.967, 880.002,
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

  /// The 64 band levels (0..1) of [pcmWindow] (at least [fftSize] samples, -1..1). While not playing, the bars fall.
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
      double rms;
      if (startBin < 4) {
        final centerBin = _bandCenterBins[band];
        final k0 = centerBin.floor();
        final k1 = k0 + 1;
        final t = centerBin - k0;
        final m0 = _magnitude[k0];
        final m1 = k1 < _magnitude.length ? _magnitude[k1] : m0;
        rms = ((1.0 - t) * m0 + t * m1) * _isoBandWeights[band];
      } else {
        var sumSq = 0.0;
        for (var k = startBin; k <= endBin; k++) {
          sumSq += _magnitude[k] * _magnitude[k];
        }
        rms = math.sqrt(sumSq / (endBin - startBin + 1)) * _isoBandWeights[band];
      }

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
