// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/audio/media_kit_driver.dart';

/// The ALSA hardware devices are read from `aplay -l` (mpv's own list often has only the sound server's outputs).
void main() {
  test('every playback device of aplay -l is found, with its card and device names', () {
    const output = '''
**** List of PLAYBACK Hardware Devices ****
card 0: HDMI [HDA ATI HDMI], device 3: HDMI 0 [KG251Q]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 0: HDMI [HDA ATI HDMI], device 7: HDMI 1 [HDMI 1]
  Subdevices: 1/1
card 2: AUDIO [SMSL USB AUDIO], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
''';
    expect(MediaKitAudioDriver.parseAplayList(output), [
      ('0', '3', 'HDA ATI HDMI', 'KG251Q'),
      ('0', '7', 'HDA ATI HDMI', 'HDMI 1'),
      ('2', '0', 'SMSL USB AUDIO', 'USB Audio'),
    ]);
  });

  test('a machine without playback devices yields none', () {
    expect(MediaKitAudioDriver.parseAplayList('aplay: device_list:274: no soundcards found...'), isEmpty);
  });
}
