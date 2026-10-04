import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  test('bit-perfect locks the volume to unity gain', () async {
    final engine = TestSupport.createEngine();
    await engine.setBitperfectMode(true);
    expect(engine.isBitperfect, isTrue);
    expect(engine.isVolumeLocked, isTrue);
    expect(engine.volume, 1.0);

    engine.setVolume(0.5); // must stay at 0 dB: no digital attenuation of the bits
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

  test('seeking updates the position', () async {
    final engine = TestSupport.createEngine();
    await engine.seek(const Duration(seconds: 42));
    expect(engine.currentPosition, const Duration(seconds: 42));
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

  test('a track without a source is reported, not played', () async {
    final driver = FakeAudioDriver();
    final engine = TestSupport.createEngine(driver);
    final failures = <String>[];
    engine.playbackFailed.listen(failures.add);
    await engine.playTrack(Track(title: 'Nowhere', filePath: ''));
    expect(driver.playCalls, 0);
    expect(failures.single, contains('Nowhere'));
  });

  test('hi-res formats are recognised', () {
    const cd = AudioFormat(sampleRate: 44100, bitsPerSample: 16);
    const master = AudioFormat(sampleRate: 96000, bitsPerSample: 24);
    expect(cd.isHiRes, isFalse);
    expect(master.isHiRes, isTrue);
    expect(master.displayBadge, contains('96'));
    expect(master.displayBadge, contains('24bit'));
    expect(cd.displayBadge, 'FLAC / 16bit / 44.1kHz');
  });
}
