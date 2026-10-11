// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test('bit-perfect locks the volume to unity gain', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    engine.setVolume(0.5);
    await engine.setBitperfectMode(true);
    expect(engine.isBitperfect, isTrue);
    expect(driver.volume, 1.0);

    engine.setVolume(0.5); // must stay at 0 dB: no digital attenuation of the bits
    expect(driver.volume, 1.0);
    expect(engine.volume, 1.0);
  });

  test('without bit-perfect the volume can be set, and restored after bit-perfect', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    engine.setVolume(0.75);
    expect(engine.volume, closeTo(0.75, 0.001));

    await engine.setBitperfectMode(true);
    expect(driver.volume, 1.0);
    await engine.setBitperfectMode(false);
    expect(engine.volume, closeTo(0.75, 0.001));
    expect(driver.volume, closeTo(0.75, 0.001));
  });

  test('muting sends zero to the driver, but never in bit-perfect mode', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    engine.setVolume(0.6);
    engine.setMuted(true);
    expect(driver.volume, 0.0);
    expect(engine.volume, 0.0);
    engine.setMuted(false);
    expect(driver.volume, closeTo(0.6, 0.001));

    await engine.setBitperfectMode(true);
    engine.setMuted(true);
    expect(driver.volume, 1.0);
  });

  test('bit-perfect switches exclusive on; switching exclusive off switches bit-perfect off', () async {
    final engine = TestSupport.createEngine();
    await engine.setBitperfectMode(true);
    expect(engine.isBitperfect, isTrue);
    expect(engine.isExclusiveMode, isTrue);

    await engine.setExclusiveMode(false);
    expect(engine.isExclusiveMode, isFalse);
    expect(engine.isBitperfect, isFalse);

    await engine.setExclusiveMode(true);
    expect(engine.isExclusiveMode, isTrue);
    expect(engine.isBitperfect, isFalse);
  });

  test(
    'when the device of exclusive and bit-perfect is gone, the default output takes over without the modes',
    () async {
      const systemDefault = AudioOutputDevice(id: 'auto', name: 'Default', driverType: 'System', isDefault: true);
      final driver = FakeAudioDriver();
      var devices = [systemDefault, TestSupport.capableDevice];
      final engine = WiretuneAudioEngine(driver, deviceDetector: () async => devices);
      await engine.ready;
      engine.setVolume(0.4);
      await engine.setBitperfectMode(true);
      expect((engine.isExclusiveMode, engine.isBitperfect, driver.device?.id), (true, true, 'hw:1,0'));

      devices = [systemDefault]; // the DAC was unplugged
      await engine.refreshDevices();
      expect(engine.currentDevice?.id, 'auto');
      expect((engine.isExclusiveMode, engine.isBitperfect), (false, false));
      expect((driver.isExclusive, driver.isBitperfect), (false, false));
      expect(driver.volume, closeTo(0.4, 0.001)); // the volume from before bit-perfect is back
    },
  );

  test('a track that waits for its stream token does not start after the one skipped to', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    final token = Completer<String?>();
    final streamed = TestSupport.makeServerTrack('s1', 'Streamed');
    final downloaded = TestSupport.makeServerTrack('s2', 'Downloaded');
    engine
      ..setStreamTokenProvider(() => token.future)
      ..setOfflineCopyProvider((t) => t.id == 's2' ? '/copies/s2.flac' : null);

    final first = engine.playTrack(streamed);
    await engine.playTrack(downloaded); // skipped to before the token arrived
    token.complete('stream-token');
    await first;

    expect(driver.playCalls, 1);
    expect(driver.lastSource, '/copies/s2.flac');
    expect(engine.currentTrack?.id, 's2');

    // Stopping while a token is on its way: nothing starts either.
    final again = Completer<String?>();
    engine.setStreamTokenProvider(() => again.future);
    final pending = engine.playTrack(streamed);
    await engine.stop();
    again.complete('stream-token');
    await pending;
    expect(driver.playCalls, 1);
  });

  test('a mode no device supports stays off and is reported', () async {
    final engine = TestSupport.createEngine(null, [TestSupport.sharedOnlyDevice]);
    final failures = <String>[];
    engine.playbackFailed.listen(failures.add);

    await engine.setExclusiveMode(true);
    await engine.setBitperfectMode(true);

    expect(engine.isExclusiveMode, isFalse);
    expect(engine.isBitperfect, isFalse);
    expect(failures, hasLength(2));
  });

  test('exclusive mode picks the hardware device of the shared sink\'s card, and back', () async {
    const sink = AudioOutputDevice(
      id: 'pw_81',
      name: 'SMSL USB AUDIO Pro',
      driverType: 'PipeWire',
      hardwareCard: 'SMSL USB DAC',
      isDefault: true,
    );
    const direct = AudioOutputDevice(
      id: 'hw:2,0',
      name: 'Direct ALSA: SMSL USB AUDIO',
      driverType: 'ALSA Direct',
      hardwareCard: 'SMSL USB AUDIO',
      isExclusiveSupported: true,
      isBitperfectSupported: true,
    );
    final engine = TestSupport.createEngine(null, [sink, direct]);
    await engine.ready;
    expect(engine.currentDevice?.id, 'pw_81');

    await engine.setExclusiveMode(true);
    expect(engine.currentDevice?.id, 'hw:2,0');
    await engine.setExclusiveMode(false);
    expect(engine.currentDevice?.id, 'pw_81');
  });

  test('the signal path describes the modes', () async {
    final engine = TestSupport.createEngine();
    await engine.playTrack(
      Track(
        title: 'Test Track',
        artist: 'Test Artist',
        format: const AudioFormat(sampleRate: 44100, bitsPerSample: 16),
        filePath: '/path/to/test.flac',
      ),
    );
    expect(engine.signalPathDescription, contains('Shared mode'));
    await engine.setExclusiveMode(true);
    expect(engine.signalPathDescription, contains('Exclusive mode'));
    await engine.setBitperfectMode(true);
    expect(engine.signalPathDescription, contains('Bit-perfect requested'));
    expect(engine.signalPathDescription, contains('no gain'));
    expect(engine.signalPathDescription, contains('Local file'));
  });

  test('changing the device mid-track restarts the track at the current position', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver, [TestSupport.sharedOnlyDevice, TestSupport.capableDevice]);
    await engine.ready;
    await engine.playTrack(TestSupport.makeTrack('a', 'A'));
    await engine.seek(const Duration(seconds: 30));

    await engine.setOutputDevice(TestSupport.capableDevice);
    expect(driver.playCalls, 2);
    expect(driver.currentPosition, const Duration(seconds: 30));
    expect(driver.device?.id, TestSupport.capableDevice.id);
  });

  test('server tracks get the stream token appended, local tracks play from their path', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    var asked = 0;
    engine.setStreamTokenProvider(() async {
      asked++;
      return 'tok+en';
    });

    await engine.playTrack(TestSupport.makeServerTrack('s', 'Server'));
    expect(driver.lastSource, 'http://server/api/stream/s?token=tok%2Ben');
    await engine.playTrack(TestSupport.makeTrack('l', 'Local'));
    expect(driver.lastSource, '/music/l.flac');
    expect(asked, 1); // only server tracks need a token
  });

  test('a fresh stream token is asked for each time a server track starts, and the old one kept on failure', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    var issued = 0;
    engine.setStreamTokenProvider(() async => 'fresh-${++issued}');
    final remote = TestSupport.makeServerTrack('s1', 'Remote');

    await engine.playTrack(remote);
    expect(driver.lastSource, 'http://server/api/stream/s1?token=fresh-1');
    await engine.playTrack(remote);
    expect(driver.lastSource, 'http://server/api/stream/s1?token=fresh-2');

    engine.setStreamTokenProvider(() async => throw const ServerRequestException('server unreachable'));
    await engine.playTrack(remote);
    expect(driver.lastSource, 'http://server/api/stream/s1?token=fresh-2');
  });

  test('a track without a source is reported, not played', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    final failures = <String>[];
    engine.playbackFailed.listen(failures.add);
    await engine.playTrack(Track(title: 'Nowhere', filePath: ''));
    expect(driver.playCalls, 0);
    expect(failures.single, contains('Nowhere'));
  });

  test('switching to a device without bitperfect support automatically disables bitperfect mode', () async {
    const exclusiveOnlyDevice = AudioOutputDevice(
      id: 'excl_only',
      name: 'Exclusive Only DAC',
      driverType: 'ALSA Direct',
      isExclusiveSupported: true,
      isBitperfectSupported: false,
    );
    final engine = TestSupport.createEngine(null, [
      TestSupport.capableDevice,
      exclusiveOnlyDevice,
      TestSupport.sharedOnlyDevice,
    ]);
    await engine.ready;
    engine.setVolume(0.7);
    await engine.setBitperfectMode(true);
    expect(engine.isBitperfect, isTrue);
    expect(engine.volume, 1.0);

    // Switch to device supporting exclusive mode but NOT bit-perfect
    await engine.setOutputDevice(exclusiveOnlyDevice);
    expect(engine.isBitperfect, isFalse);
    expect(engine.isExclusiveMode, isTrue);
    expect(engine.volume, closeTo(0.7, 0.001));

    // Re-enable bitperfect on capableDevice, then switch to shared-only
    await engine.setOutputDevice(TestSupport.capableDevice);
    await engine.setBitperfectMode(true);
    expect(engine.isBitperfect, isTrue);

    await engine.setOutputDevice(TestSupport.sharedOnlyDevice);
    expect(engine.isBitperfect, isFalse);
    expect(engine.isExclusiveMode, isFalse);
    expect(engine.volume, closeTo(0.7, 0.001));
  });
}
