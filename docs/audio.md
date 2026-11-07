# Audio

Wiretune plays through libmpv (FFmpeg decodes) everywhere except Samsung Tizen TVs, which use their own player. Server
tracks stream as the original files, unless you choose a lower [streaming quality](#streaming-quality). Local tracks
play straight from disk. No crossfade.

## Equalizer

*Settings → Audio → Equalizer*: ten bands from 31 Hz to 16 kHz, ±12 dB each, with presets (Flat, Bass, Treble, Vocal).
Off by default; the bands you set stay when you switch it off. A boost raises its band and leaves the rest as it was:
there is no preamp turning the whole sound down. On Linux a limiter (`ffmpeg`'s `alimiter`) holds the peaks a boost
would take past full scale. The Android player's mpv has no limiter: its float output hands those peaks to the
phone, whose volume turns them down, so a boost can only clip at full volume on a loud recording. It filters through mpv, so it also applies to local
files and downloads. **It never applies in bit-perfect mode** (the switch is greyed out), and
Samsung TVs have none. The spectrum analyzer decodes the file on its own and shows the sound before the equalizer.

## Streaming quality

*Settings → Audio → Streaming quality* is for a slow connection, away from home. **Original** (the default) sends the
file. The other choices (**High**, **Normal**, **Data saver**: Opus at 160, 96 and 48 kbit/s) have the server convert
the track first ([how the server does it](server.md#streaming-on-a-slow-connection)). The setting belongs to this
device, and counts from the next track. Downloads, local files and bit-perfect output always play the file; the choices
are greyed out in bit-perfect mode. A server without `ffmpeg` sends the file whatever you chose. The signal path says
when a track is converted.

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
to itself. *Settings → Audio → Signal path* shows that request, and once a track plays, a line **Actual output** with
what the player opened: the rate, the sample format, the channels and the output driver. It adds *resampled* when that
rate isn't the file's, and *less bit depth than the file* when the format holds fewer bits. A 24-bit file comes out as
`s32`, which is fine: the extra bits are padding.

- That line is the player's own report of the format it handed to the output. It can't see what the driver or the DAC
  does after that, so Wiretune still hasn't been measured with bit-exact test streams.
- Wiretune doesn't touch the sound card's hardware mixer. Set it to 100 % yourself (for example with `alsamixer`).
- DSD files (`.dsf`) are decoded to PCM: there's no native DSD or DoP output.
- For lossy files, bit-perfect only describes the output stage.

Tried on Linux and Windows with an SMSL SU-1 USB DAC. Never measured with bit-exact test streams, never tried with a DAC
on macOS. The actual-output line was checked against libmpv with the `null` output, not on a DAC. Reports from other
setups are welcome.

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

64 bands from 20 Hz to 20 kHz. Never affects playback. A server track is downloaded a second time for it.

- Desktop: in the player bar. Needs `ffmpeg` on the `PATH`.
- Android phone: in the full-screen player, between Lyrics and Queue. Android's own decoder reads the track
  (`PcmDecoder.kt` in `packages/wiretune_platform`), and only while the spectrum is on screen: it stops with the
  player down or the screen off, to spare the battery. A format the phone can't decode leaves the bars flat.
