// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test('bit-perfect locks the volume at unity gain, and the volume set before comes back after', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    engine.setVolume(0.75);
    expect(engine.volume, closeTo(0.75, 0.001));
    await engine.setBitPerfectMode(true);
    expect(engine.isBitPerfect, isTrue);
    expect(driver.volume, 1.0);

    engine.setVolume(0.5); // must stay at 0 dB: no digital attenuation of the bits
    expect(driver.volume, 1.0);
    expect(engine.volume, 1.0);

    await engine.setBitPerfectMode(false);
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

    await engine.setBitPerfectMode(true);
    engine.setMuted(true);
    expect(driver.volume, 1.0);
  });

  test('bit-perfect switches exclusive on; switching exclusive off switches bit-perfect off', () async {
    final engine = TestSupport.createEngine();
    await engine.setBitPerfectMode(true);
    expect(engine.isBitPerfect, isTrue);
    expect(engine.isExclusiveMode, isTrue);

    await engine.setExclusiveMode(false);
    expect(engine.isExclusiveMode, isFalse);
    expect(engine.isBitPerfect, isFalse);

    await engine.setExclusiveMode(true);
    expect(engine.isExclusiveMode, isTrue);
    expect(engine.isBitPerfect, isFalse);
  });

  test(
    'when the device of exclusive and bit-perfect is gone, the default output takes over without the modes',
    () async {
      const systemDefault = AudioOutputDevice(id: 'auto', name: 'Default', driverType: 'System', isDefault: true);
      final driver = FakeAudioDriver(devices: [systemDefault, TestSupport.capableDevice]);
      final engine = WiretuneAudioEngine(driver);
      await engine.ready;
      engine.setVolume(0.4);
      await engine.setBitPerfectMode(true);
      expect((engine.isExclusiveMode, engine.isBitPerfect, driver.device?.id), (true, true, 'hw:1,0'));

      driver.devices = [systemDefault]; // the DAC was unplugged
      await engine.refreshDevices();
      expect(engine.currentDevice?.id, 'auto');
      expect((engine.isExclusiveMode, engine.isBitPerfect), (false, false));
      expect((driver.isExclusive, driver.isBitPerfect), (false, false));
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
    await engine.setBitPerfectMode(true);

    expect(engine.isExclusiveMode, isFalse);
    expect(engine.isBitPerfect, isFalse);
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
      isBitPerfectSupported: true,
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
    await engine.setBitPerfectMode(true);
    expect(engine.signalPathDescription, contains('Bit-perfect requested'));
    expect(engine.signalPathDescription, contains('no gain'));
    expect(engine.signalPathDescription, contains('Local file'));
  });

  group('the signal path says what the output really is', () {
    Track track({int rate = 96000, int bits = 24, bool lossless = true}) => Track(
      title: 'Test Track',
      artist: 'Test Artist',
      format: AudioFormat(
        sampleRate: rate,
        bitsPerSample: bits,
        isLossless: lossless,
        codec: lossless ? 'FLAC' : 'MP3',
      ),
      filePath: '/path/to/test.flac',
    );

    Future<(WiretuneAudioEngine, FakeAudioDriver)> start(Track playing, AudioOutputInfo? output) async {
      final driver = FakeAudioDriver()
        ..reportsOutput = true
        ..output = output;
      final engine = WiretuneAudioEngine(driver);
      addTearDown(engine.dispose);
      await engine.ready;
      await engine.playTrack(playing);
      return (engine, driver);
    }

    test('only once the player has opened it, and then in the description', () async {
      final (engine, driver) = await start(track(), null);
      expect(engine.measuredOutput, isNull);
      expect(engine.signalPathDescription, isNot(contains('Actual output')));

      driver.output = const AudioOutputInfo(sampleRate: 96000, sampleFormat: 's32', channels: 2, backend: 'alsa');
      await until(() => engine.measuredOutput != null, within: const Duration(seconds: 3));
      expect(engine.signalPathDescription, contains('Actual output: 96 kHz, s32, 2 ch, alsa'));
      expect(engine.signalPathDescription, isNot(contains('resampled')));
      expect(engine.signalPathDescription, isNot(contains('less bit depth')));
    });

    test('and says so when the rate or the bit depth is not the file\'s', () async {
      final (engine, _) = await start(
        track(rate: 96000, bits: 24),
        const AudioOutputInfo(sampleRate: 48000, sampleFormat: 's16', channels: 2),
      );
      await until(() => engine.measuredOutput != null);
      expect(
        engine.signalPathDescription,
        contains('Actual output: 48 kHz, s16, 2 ch – resampled, the source is 96 kHz'),
      );
      expect(engine.signalPathDescription, contains('less bit depth than the file'));
    });

    test('says nothing against a lossy file, which has no bit depth to keep', () async {
      final (engine, _) = await start(
        track(rate: 44100, bits: 16, lossless: false),
        const AudioOutputInfo(sampleRate: 48000, sampleFormat: 'float'),
      );
      await until(() => engine.measuredOutput != null);
      expect(engine.signalPathDescription, contains('Actual output: 48 kHz, float'));
      expect(engine.signalPathDescription, isNot(contains('resampled')));
    });

    test('is read again for the next track, and forgotten when playback stops', () async {
      final (engine, driver) = await start(
        track(rate: 44100, bits: 16),
        const AudioOutputInfo(sampleRate: 44100, sampleFormat: 's16'),
      );
      await until(() => engine.measuredOutput != null);

      driver.output = const AudioOutputInfo(sampleRate: 96000, sampleFormat: 's32');
      var measured = 0;
      engine.outputMeasured.listen((_) => measured++);
      await engine.playTrack(track());
      await until(() => measured == 1);
      expect(engine.measuredOutput?.sampleRate, 96000);

      await engine.stop();
      expect(engine.measuredOutput, isNull);
    });

    test('knows the bits of the formats the player names', () {
      int? bits(String format) => AudioOutputInfo(sampleRate: 44100, sampleFormat: format).bitsPerSample;
      expect(
        [bits('s16'), bits('s24'), bits('s32'), bits('s32p'), bits('u8'), bits('float'), bits('floatp')],
        [16, 24, 32, 32, 8, 32, 32],
      );
      expect([bits('double'), bits('mystery')], [64, null]);
    });
  });

  test('the next track is handed to the driver ahead, again after a new start, and takes over gaplessly', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    await engine.ready;
    final a = TestSupport.makeTrack('a', 'A');
    final b = TestSupport.makeTrack('b', 'B');
    final changes = <Track?>[];
    engine.trackChanged.listen(changes.add);

    await engine.setNextTrack(b);
    await engine.playTrack(a);
    expect(driver.nextSource, b.filePath, reason: 'given again once the new track started');

    driver.simulateGaplessEnd();
    expect(engine.currentTrack, b);
    expect(changes, [a, b]);
    expect(driver.playCalls, 1);

    await engine.setNextTrack(null);
    expect(driver.nextSource, isNull);
  });

  test('volume normalization reaches the driver and the signal path, which leaves it out for bit-perfect', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    await engine.ready;
    await engine.playTrack(TestSupport.makeTrack('a', 'A'));
    expect(engine.signalPathDescription, isNot(contains('normalization')));
    engine.setNormalization(VolumeNormalization.album);
    expect(driver.normalization, VolumeNormalization.album);
    expect(engine.signalPathDescription, contains('volume normalization: Per album'));
    await engine.setBitPerfectMode(true);
    expect(engine.signalPathDescription, isNot(contains('normalization')));
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

  test('switching to a device without bit-perfect support turns bit-perfect mode off', () async {
    const exclusiveOnlyDevice = AudioOutputDevice(
      id: 'excl_only',
      name: 'Exclusive Only DAC',
      driverType: 'ALSA Direct',
      isExclusiveSupported: true,
      isBitPerfectSupported: false,
    );
    final engine = TestSupport.createEngine(null, [
      TestSupport.capableDevice,
      exclusiveOnlyDevice,
      TestSupport.sharedOnlyDevice,
    ]);
    await engine.ready;
    engine.setVolume(0.7);
    await engine.setBitPerfectMode(true);
    expect(engine.isBitPerfect, isTrue);
    expect(engine.volume, 1.0);

    // Switch to device supporting exclusive mode but NOT bit-perfect
    await engine.setOutputDevice(exclusiveOnlyDevice);
    expect(engine.isBitPerfect, isFalse);
    expect(engine.isExclusiveMode, isTrue);
    expect(engine.volume, closeTo(0.7, 0.001));

    // Bit-perfect on the capable device again, then the switch to a shared-only one
    await engine.setOutputDevice(TestSupport.capableDevice);
    await engine.setBitPerfectMode(true);
    expect(engine.isBitPerfect, isTrue);

    await engine.setOutputDevice(TestSupport.sharedOnlyDevice);
    expect(engine.isBitPerfect, isFalse);
    expect(engine.isExclusiveMode, isFalse);
    expect(engine.volume, closeTo(0.7, 0.001));
  });
}
