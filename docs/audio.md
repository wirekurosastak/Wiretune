# Audio

Wiretune plays through libmpv, with FFmpeg decoding, everywhere except Samsung's Tizen TVs, which use their own player.
Server tracks stream as the original files, never transcoded, and local tracks play straight from disk. There's no
crossfade and no equalizer.

## Output modes

| Mode | What it does | Where |
|---|---|---|
| **Shared** | Plays through the system mixer, like any other app. | Everywhere |
| **Exclusive** | Opens the output device directly, around the mixer; the volume slider still works. | Desktop |
| **Bit-perfect** | Exclusive, with the volume pinned at 100 % so no gain is applied. | Desktop |

Turning on bit-perfect also turns on exclusive. If no device supports a mode, the switch stays off and the player says
why. Changing the mode or the device mid-track restarts the track at the same position.

## Bit-perfect

In bit-perfect mode Wiretune asks for lossless decoding with no gain, no filters and no resampling or format change, on
an output device it has to itself. It doesn't measure what reaches the DAC, so the signal-path readout shows what was
requested, not what arrived. If an ALSA device can't take the file's sample rate or format, mpv converts it anyway and
the readout still says bit-perfect; `WIRETUNE_LOG_LEVEL=debug` logs the format mpv chose. Wiretune also leaves the sound
card's hardware mixer alone, so set it to 100 % yourself (with `alsamixer`, for example).

DSD files (`.dsf`) are decoded to PCM, since there's no native DSD or DoP output, and for lossy files bit-perfect
describes only the output stage.

Exclusive and bit-perfect output have been tried on Linux and Windows with an SMSL SU-1 USB DAC, but never measured with
bit-exact test streams, and never tried with a DAC on macOS. Reports from other setups are welcome.

## Choosing a device

The device list is built at start-up and again when you press **Refresh**. *System default output* is always shared. On
Linux, exclusive and bit-perfect need one of the `ALSA: <card> (<device>)` entries, while the PipeWire and PulseAudio
entries are shared only. On Windows and macOS every device is offered for exclusive mode, without Wiretune checking in
advance which formats it accepts.

On Linux, exclusive playback takes the whole sound card from PipeWire, so no other app can play through it until
playback stops; PipeWire gets it back even if Wiretune crashes. This has been tried with WirePlumber, not with
PulseAudio. If the card stays busy, playback fails with mpv's error message.

## Android and iOS

Phones and tablets play to whatever output the system routes sound to, and the system may resample. There's no
exclusive or bit-perfect mode and no device choice, and the volume keys replace the volume slider.

Playback pauses for calls, when headphones are unplugged or Bluetooth drops, and on Android when another app starts
playing; navigation prompts lower its volume. It keeps playing with the screen off and can be controlled from the
notification, the lock screen, Control Center and headset buttons.

## Tizen

On Samsung TVs the TV's own player decodes, so format support depends on the firmware: FLAC, WAV, MP3, AAC and Vorbis
usually play, while ALAC, APE, WavPack, DSD and Opus may fail. The TV's output and volume apply, and there's no
exclusive mode, ReplayGain or gapless playback.

## Gapless playback

Gapless playback is on by default (*Settings → Audio → Gapless playback*). Tracks with the same sample format, rate and
channel count follow each other without a gap; when the format changes, the output is set up again and there's a short
pause. It has been tried on Linux with PipeWire; Windows, macOS and the phones run the same code but haven't been tried.

## Volume normalization

*Settings → Audio → Volume normalization* applies the files' ReplayGain tags, per track or per album, as software gain.
It's off by default, leaves untagged files unchanged, and is ignored in bit-perfect mode.

## Spectrum analyzer

On the desktop the spectrum analyzer shows 64 bands from 20 Hz to 20 kHz. It needs `ffmpeg` on the `PATH` and never
affects playback.
