# Audio

Wiretune plays through libmpv (FFmpeg decodes) everywhere except Samsung Tizen TVs, which use their own player. Server
tracks stream as the original files, never transcoded. Local tracks play straight from disk. No crossfade, no
equalizer.

## Output modes

| Mode | What it does | Where |
|---|---|---|
| **Shared** | Plays through the system mixer, like any app. | Everywhere |
| **Exclusive** | Opens the output device directly, bypassing the mixer. The volume slider still works. | Desktop |
| **Bit-perfect** | Exclusive, with the volume fixed at 100 %: no gain applied. | Desktop |

Turning on bit-perfect also turns on exclusive. If no device supports a mode, the switch stays off and the player
shows why. Changing the mode or device mid-track restarts the track at the same position.

## Bit-perfect

Wiretune requests lossless decoding with no gain, no filters, no resampling and no format change, on a device it has
to itself. It doesn't measure what reaches the DAC: the signal-path readout shows what was requested, not what arrived.

- If an ALSA device can't take the file's sample rate or format, mpv converts it anyway and the readout still says
  bit-perfect. `WIRETUNE_LOG_LEVEL=debug` logs the format mpv chose.
- Wiretune doesn't touch the sound card's hardware mixer. Set it to 100 % yourself (for example with `alsamixer`).
- DSD files (`.dsf`) are decoded to PCM: there's no native DSD or DoP output.
- For lossy files, bit-perfect only describes the output stage.

Tried on Linux and Windows with an SMSL SU-1 USB DAC. Never measured with bit-exact test streams, never tried with a DAC
on macOS. Reports from other setups are welcome.

## Choosing a device

The device list is built at startup and when you press **Refresh**. *System default output* is always shared.

- **Linux:** exclusive and bit-perfect need an `ALSA: <card> (<device>)` entry. PipeWire and PulseAudio entries are
  shared only.
- **Windows and macOS:** every device is offered for exclusive mode, without checking which formats it accepts.

On Linux, exclusive playback takes the whole sound card from PipeWire: no other app can play through it until playback
stops. PipeWire gets it back even if Wiretune crashes. Tried with WirePlumber, not with PulseAudio. If the card is busy,
playback fails with mpv's error message.

## Android and iOS

Phones and tablets play to whatever output the system routes to, and the system may resample. No exclusive or
bit-perfect mode, no device choice; the volume keys replace the volume slider.

Playback pauses for calls, when headphones are unplugged or Bluetooth disconnects, and on Android when another app
starts playing. Navigation prompts lower the volume. Playback continues with the screen off and can be controlled from
the notification, the lock screen, Control Center and headset buttons.

## Tizen

Samsung TVs decode with their own player, so format support depends on the firmware. FLAC, WAV, MP3, AAC and Vorbis
usually play; ALAC, APE, WavPack, DSD and Opus may fail. The TV's output and volume apply. No exclusive mode, ReplayGain
or gapless playback.

## Gapless playback

On by default (*Settings → Audio → Gapless playback*). Tracks with the same sample format, rate and channel count play
without a gap. When the format changes, the output is reopened and there's a short pause. Tried on Linux with PipeWire.
Windows, macOS and the phones run the same code but are untested.

## Volume normalization

*Settings → Audio → Volume normalization* applies the files' ReplayGain tags, per track or per album, as software gain.
Off by default. Untagged files are unchanged. Ignored in bit-perfect mode.

## Spectrum analyzer

Desktop only: 64 bands from 20 Hz to 20 kHz. Needs `ffmpeg` on the `PATH`. Never affects playback.
