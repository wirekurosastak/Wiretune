# Audio

Wiretune plays through libmpv (FFmpeg decodes) everywhere except Samsung Tizen TVs, which use their own player. Server
tracks stream as the original files unless you choose a lower [streaming quality](#streaming-quality).

## Equalizer

*Settings → Audio → Equalizer*: ten bands from 31 Hz to 16 kHz, ±12 dB each, with presets. A boost raises its band
without turning the rest down. On Linux a limiter catches the peaks; on Android a boost can clip at full volume on a
loud recording. It applies to every track, but **not in bit-perfect mode**, and Samsung TVs have none.

## Streaming quality

*Settings → Audio → Streaming quality*: **Original** (the default) sends the file; **High**,
**Normal** and **Data saver** have the server convert it to Opus at 160, 96 or 48 kbit/s
([needs `ffmpeg`](server.md#streaming-on-a-slow-connection)). Per device, from the next track. Downloads, local files and
bit-perfect mode always play the file.

Phones have a second row, **On mobile data**, and switch with the network. The first time a phone streams over mobile
data, it asks which quality to use.

## Output modes

| Mode | What it does | Where |
|---|---|---|
| **Shared** | Plays through the system mixer, like any app. | Everywhere |
| **Exclusive** | Opens the output device directly, bypassing the mixer. The volume slider still works. | Desktop |
| **Bit-perfect** | Exclusive, with the volume fixed at 100 %: no gain applied. | Desktop |

Bit-perfect turns on exclusive too. If no device supports a mode, the switch stays off and says why.

## Bit-perfect

Wiretune asks for lossless decoding with no gain, filters, resampling or format change, on a device it has to itself.
*Settings → Audio → Signal path* shows that, and while a track plays, **Actual output**: the rate, sample format,
channels and driver the player opened, marked *resampled* or *less bit depth than the file* when so. A 24-bit file
comes out as `s32`: the extra bits are padding.

- **Actual output** is what the player handed to the output; it can't see what the driver or the DAC does after that.
- Set the sound card's hardware mixer to 100 % yourself (for example with `alsamixer`).
- DSD files (`.dsf`) are decoded to PCM: no native DSD or DoP.

Tried on Linux and Windows with an SMSL SU-1 USB DAC; not measured with bit-exact test streams, not tried on macOS.
Reports from other setups are welcome.

## Choosing a device

The device list is built at startup and when you press **Refresh**. *System default output* is always shared.

- **Linux:** exclusive and bit-perfect need an `ALSA: <card> (<device>)` entry. PipeWire and PulseAudio entries are
  shared only.
- **Windows and macOS:** every device is offered for exclusive mode, without checking which formats it accepts.

On Linux, exclusive playback takes the whole sound card from PipeWire until playback stops, even if Wiretune crashes.
Tried with WirePlumber, not with PulseAudio.

## Android and iOS

Phones and tablets play to whatever output the system routes to, and the system may resample. No exclusive or
bit-perfect mode, no device choice; the volume keys replace the volume slider.

Playback pauses for calls, unplugged headphones, a Bluetooth disconnect, and on Android another app starting to play.
Navigation prompts lower the volume.

## Tizen

Samsung TVs decode with their own player, so format support depends on the firmware. FLAC, WAV, MP3, AAC and Vorbis
usually play; ALAC, APE, WavPack, DSD and Opus may fail. The TV's output and volume apply. No exclusive mode, ReplayGain
or gapless playback.

## Gapless playback

On by default (*Settings → Audio → Gapless playback*). Tracks with the same sample format, rate and channel count play
without a gap; a format change makes a short pause. Tried on Linux with PipeWire only.

## Volume normalization

*Settings → Audio → Volume normalization* applies the files' ReplayGain tags, per track or per album. Off by default,
and ignored in bit-perfect mode.

## Spectrum analyzer

64 bands from 20 Hz to 20 kHz, showing the sound before the equalizer. A server track is downloaded a second time for
it, unless it's cached.

- Desktop: in the player bar. Needs `ffmpeg` on the `PATH`.
- Phone: at the bottom of the full-screen player, only while it's on screen (battery). A format the phone can't decode
  leaves the bars flat.
