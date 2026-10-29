// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  group('the equalizer', () {
    test('is flat to begin with, and a flat one filters nothing', () {
      final flat = Equalizer.flat();
      expect(flat.bands, hasLength(10));
      expect(flat.bands.map((b) => b.frequency.toInt()), Equalizer.frequencies);
      expect(flat.isFlat, isTrue);
      expect(flat.filter, '');
      expect(flat.headroomDb, 0);
      expect(Equalizer.fromGains(const [0.01, -0.04]).isFlat, isTrue, reason: 'a hundredth of a decibel is nothing');
    });

    test('filters the bands that are not flat, and takes the loudest boost back off', () {
      final eq = Equalizer.fromGains(const [0, 0, 0, 0, 0, 6, 0, 0, -3.5, 0]);
      expect(eq.filter, 'lavfi=[equalizer=f=1000:t=q:w=1.41:g=6,equalizer=f=8000:t=q:w=1.41:g=-3.5,volume=-6dB]');
      expect(eq.headroomDb, 6);
    });

    test('has no preamp when it only lowers', () {
      final eq = Equalizer.fromGains(const [-4, 0, 0, 0, 0, 0, 0, 0, 0, -2]);
      expect(eq.headroomDb, 0);
      expect(eq.filter, 'lavfi=[equalizer=f=31:t=q:w=1.41:g=-4,equalizer=f=16000:t=q:w=1.41:g=-2]');
    });

    test('keeps a band within what is allowed, and leaves the missing ones flat', () {
      final eq = Equalizer.fromGains(const [99, -99, 3]);
      expect(eq.gains, [12, -12, 3, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('is kept as JSON and read again, flat when what was kept is not ours', () {
      final eq = Equalizer.fromGains(const [1.25, 0, -2, 0, 0, 0, 0, 0, 0, 12]);
      expect(eq.toJson(), '[1.3,0.0,-2.0,0.0,0.0,0.0,0.0,0.0,0.0,12.0]');
      expect(Equalizer.fromJson(eq.toJson()).gains, [1.3, 0, -2, 0, 0, 0, 0, 0, 0, 12]);
      for (final damaged in [null, '', 'nonsense', '{"a":1}', '["x",null]']) {
        expect(Equalizer.fromJson(damaged).isFlat, isTrue, reason: '$damaged');
      }
    });

    test('is equal to another with the same gains', () {
      expect(Equalizer.fromGains(const [1, 2]), Equalizer.fromGains(const [1, 2, 0, 0, 0, 0, 0, 0, 0, 0]));
      expect(Equalizer.fromGains(const [1, 2]), isNot(Equalizer.fromGains(const [1, 3])));
      expect(Equalizer.fromGains(const [1, 2]).hashCode, Equalizer.fromGains(const [1, 2]).hashCode);
    });

    test('has presets with a gain for every band, within the limit', () {
      expect(Equalizer.presets.keys, ['flat', 'bass', 'treble', 'vocal']);
      for (final MapEntry(:key, :value) in Equalizer.presets.entries) {
        expect(value, hasLength(Equalizer.frequencies.length), reason: key);
        expect(value.every((g) => g.abs() <= Equalizer.maxGainDb), isTrue, reason: key);
      }
      expect(Equalizer.fromGains(Equalizer.presets['flat']!).isFlat, isTrue);
      expect(Equalizer.fromGains(Equalizer.presets['bass']!).isFlat, isFalse);
    });
  });

  group('in the engine', () {
    test('is given to the driver, and said in the signal path while it filters', () async {
      final driver = FakeAudioDriver();
      final engine = TestSupport.createEngine(driver);
      await engine.playTrack(TestSupport.makeTrack('t', 'Track'));
      expect(engine.signalPathDescription, isNot(contains('equalizer')));

      final eq = Equalizer.fromGains(const [0, 0, 0, 0, 0, 3, 0, 0, 0, 0]);
      engine.setEqualizer(eq);
      expect(driver.equalizer, eq);
      expect(engine.equalizer, eq);
      expect(engine.signalPathDescription, contains('equalizer'));

      engine.setEqualizer(Equalizer.flat());
      expect(engine.signalPathDescription, isNot(contains('equalizer')));
    });

    test('is left out of the signal path in bit-perfect mode', () async {
      final driver = FakeAudioDriver();
      final engine = TestSupport.createEngine(driver);
      await engine.playTrack(TestSupport.makeTrack('t', 'Track'));
      engine.setEqualizer(Equalizer.fromGains(const [3]));
      await engine.setBitPerfectMode(true);
      expect(engine.signalPathDescription, isNot(contains('equalizer')));
      expect(engine.equalizer.isFlat, isFalse, reason: 'it is kept for when bit-perfect is off again');
      await engine.setBitPerfectMode(false);
      expect(engine.signalPathDescription, contains('equalizer'));
    });
  });
}
