# Audio

Playback is libmpv (FFmpeg decoding) on every platform except Tizen, which uses the TV's own player. Server tracks
stream directly from `/api/stream/{id}`; local tracks play from the file.

## Output modes

| Mode | What it does | Where |
|---|---|---|
| **Shared** | Through the system mixer. Volume works. | Everywhere |
| **Exclusive** | Opens the device directly, around the mixer. Volume works. | Desktop |
| **Bit-perfect** | Exclusive, no gain: volume pinned at 100 %. | Desktop |

Bit-perfect implies exclusive. If no device supports a mode, the switch stays off and the player says why. Changing mode
or device mid-track restarts the track at the same position.

**Bit-perfect means:** lossless decoding, no gain, no filters, no resampling or format change requested, exclusive
device access. Wiretune doesn't measure what reaches the DAC, and doesn't touch the card's hardware mixer: set that to
100 % yourself (`alsamixer`).

## Desktop

- **Devices** are listed at start-up and on **Refresh**. *System default output* is shared only. On Linux, ALSA
  hardware devices (`ALSA: <card> (<device>)`, opened as `alsa/hw:…`) support exclusive and bit-perfect; PipeWire and
  PulseAudio sinks are shared only. On Windows (WASAPI) and macOS (Core Audio), endpoints are offered for exclusive
  without probing their formats.
- **Linux + PipeWire:** before opening a `hw:` device, Wiretune asks PipeWire to release the card through D-Bus device
  reservation, and PipeWire gets it back when Wiretune stops or crashes. Tried with WirePlumber; PulseAudio untried. If
  the card stays busy, playback fails with mpv's message.
- **Format conversion goes unnoticed.** If a `hw:` device can't take the file's rate or sample format, mpv converts it
  and Wiretune still says bit-perfect. `WIRETUNE_LOG_LEVEL=debug` shows the format mpv chose.
- **DSD** (`.dsf`) is decoded to PCM. No native DSD, no DoP.
- **Lossy files** decode normally; "bit-perfect" then only describes the output stage.
- **Failed tracks** stop the queue with the reason shown, rather than skipping ahead.

## Android and iOS

Plays to whatever the system routes to. No exclusive or bit-perfect mode, no device choice, no spectrum, no volume
slider (use the volume keys). The system may resample.

- Pauses on calls, other apps' playback (Android) and unplugged headphones or lost Bluetooth. Navigation prompts duck to
  20 %.
- Keeps playing with the screen off; notification, lock screen, Control Center and headset buttons control it.
- Android TV is the same app, driven by the remote. Android Auto browses the library and takes voice search; playback
  runs on the phone.
- iOS asks once for *local network* access (needed for a LAN server).

## Tizen

The TV's player decodes, so support depends on the firmware: usually FLAC, WAV, MP3, AAC, Vorbis; ALAC, APE, WavPack,
DSD and Opus may fail. TV output and volume apply. No exclusive mode, ReplayGain or gapless. Tried briefly on a 2024
Samsung (Tizen 8.0).

## Gapless playback

On by default (*Settings → Audio → Gapless playback*). Tracks with the same sample format, rate and channels play
without a gap; otherwise the output reconfigures and there's a short pause. Tried on Linux (PipeWire). Windows, macOS
and phones run the same code untried.

## Volume normalization

*Settings → Audio → Volume normalization* (*Off* by default, *Per track*, *Per album*) applies the files' ReplayGain
tags as software gain. Untagged files play unchanged. Bit-perfect ignores it.

## Spectrum analyzer

Desktop only: 64 bands, 20 Hz to 20 kHz. Needs `ffmpeg` on the `PATH`. It decodes the track separately, so a server
track is fetched twice, and it never affects playback.

## Known limitations

- **Exclusive and bit-perfect** are tried on Linux and Windows with an SMSL SU-1 USB DAC, but not measured with
  bit-exact test streams. macOS is untested on a DAC. Reports from other setups are welcome.
- **The signal-path readout shows what was requested, not what was measured.**
- No crossfade, no equalizer.
- No system media controls on Windows and Tizen. Media keys work while the app has focus.
