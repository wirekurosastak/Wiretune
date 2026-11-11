// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

/// One band of the equalizer: a gain at a frequency, with the width ([q]) of its bump.
class EqualizerBand {
  const EqualizerBand(this.frequency, this.gainDb, [this.q = 1.41]);

  final double frequency;
  final double gainDb;
  final double q;
}

/// A graphic equalizer: a gain at each of ten frequencies, an octave apart. The player turns it into a filter chain for
/// the player (`ffmpeg`'s `equalizer`): a boost raises its band and leaves the rest as it was. Where the player has a
/// limiter, it holds the peaks a boost would take past full scale ([filter]). Bit-perfect output never uses it.
class Equalizer {
  const Equalizer(this.bands);

  /// Flat: every band at 0 dB.
  factory Equalizer.flat() => Equalizer([for (final f in frequencies) EqualizerBand(f.toDouble(), 0)]);

  /// The bands set to [gains], one per [frequencies] entry (a shorter list leaves the rest flat).
  factory Equalizer.fromGains(List<double> gains) => Equalizer([
    for (var i = 0; i < frequencies.length; i++)
      EqualizerBand(frequencies[i].toDouble(), i < gains.length ? gains[i].clamp(-maxGainDb, maxGainDb) : 0),
  ]);

  /// The centre frequencies in Hz, an octave apart.
  static const List<int> frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  /// How far a band may be lowered or raised.
  static const double maxGainDb = 12;

  /// Ready-made curves, by name (the interface has the words).
  static const Map<String, List<double>> presets = {
    'flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'bass': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
    'treble': [0, 0, 0, 0, 0, 0, 2, 4, 5, 6],
    'vocal': [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1],
  };

  final List<EqualizerBand> bands;

  List<double> get gains => [for (final band in bands) band.gainDb];

  bool get isFlat => bands.every((band) => band.gainDb.abs() < 0.05);

  /// Whether a band is raised, which can take the loudest parts past full scale.
  bool get boosts => bands.any((band) => band.gainDb >= 0.05);

  /// The filter chain for the player (mpv's `af` property), or an empty text when the equalizer is flat. With a
  /// [limiter] (`ffmpeg`'s `alimiter`, which the player must have: mpv leaves out a whole chain naming a filter it
  /// lacks), the peaks a boost would take past full scale are held just below it, and nothing else changes: no
  /// preamp turning the whole sound down, as that would leave the boosted band where it was and lower the rest.
  String filter({bool limiter = false}) {
    if (isFlat) return '';
    final parts = [
      for (final band in bands)
        if (band.gainDb.abs() >= 0.05)
          'equalizer=f=${_number(band.frequency)}:t=q:w=${_number(band.q)}:g=${_number(band.gainDb)}',
      // Its own levelling off, which would raise the whole sound to the limit.
      if (limiter && boosts) 'alimiter=limit=0.98:level=disabled',
    ];
    return 'lavfi=[${parts.join(',')}]';
  }

  static String _number(double value) => value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  /// The gains as JSON, to keep: `[0,0,3.5,…]`.
  String toJson() => jsonEncode([for (final gain in gains) double.parse(gain.toStringAsFixed(1))]);

  /// The equalizer [json] holds; flat when it is not a list of numbers.
  static Equalizer fromJson(String? json) {
    try {
      final decoded = jsonDecode(json ?? '');
      if (decoded is List) {
        return Equalizer.fromGains([for (final gain in decoded) gain is num ? gain.toDouble() : 0.0]);
      }
    } on FormatException {
      // Not ours: flat.
    }
    return Equalizer.flat();
  }

  @override
  bool operator ==(Object other) => other is Equalizer && _sameGains(other.gains, gains);

  @override
  int get hashCode => Object.hashAll(gains);

  static bool _sameGains(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() >= 0.05) return false;
    }
    return true;
  }
}
