# Audio

What Wiretune does between "play" and the sound card, what the output modes mean, and what has not been
verified. Read this before relying on the word "bit-perfect".

`WiretuneAudioEngine` owns the playback state, the output device and the mode switches; a platform driver
implementing `IAudioDriver` does the playing:

| Platform | Driver | How audio is produced |
|---|---|---|
| Linux | `FfmpegAudioDriver` | Child processes: `ffplay`, or `ffmpeg` piped into `aplay` |
| Windows | `WasapiAudioDriver` | NAudio `WasapiOut`, decoding with Media Foundation |
| Android | `AndroidAudioDriver` | Android `MediaPlayer` |

Local tracks play from their file path. Server tracks play straight from the server's `/api/stream/{id}` URL (a
short-lived stream token, not the sign-in token, is appended when playback starts), so nothing is downloaded first. Only Linux is a target for
`FfmpegAudioDriver`; no other non-Windows desktop is documented or tested.

## Output modes

| Mode | Meaning |
|---|---|
| **Shared** | Normal playback through the operating system's mixer. Volume works. Everywhere. |
| **Exclusive** | Wiretune opens the output device directly instead of going through the mixer. Volume still works. Linux and Windows. |
| **Bit-perfect** | Exclusive plus no gain of Wiretune's own: the volume is fixed at 100 % and the slider and mute are disabled. Linux and Windows. |

Bit-perfect switches exclusive on, and switching exclusive off switches bit-perfect off. If no detected device
supports the requested mode, the engine says so and the mode stays off. Changing mode or device mid-track
restarts the track at the current position.

"Bit-perfect" describes the path Wiretune sets up: lossless decode, no gain, exclusive access, no resampling
requested. Whether the bits reaching the DAC equal the file also depends on the driver and the hardware, and
Wiretune does not measure it. On Linux the mode also leaves the card's own mixer alone, so a `PCM` volume below
100 % still attenuates the signal there; set it to 100 % yourself (for example in `alsamixer`).

## Linux

**Devices.** The list comes from `wpctl status` (PipeWire sinks, *shared mode only*) and `aplay -l` (ALSA hardware
devices, shown as `ALSA: <card>`, ID `hw:<card>,<device>`; these support exclusive and bit-perfect). Each tool is
queried with a 3-second timeout. With neither installed, one *Default audio output* entry (shared only) is
offered. The list is built at start-up and on **Refresh**.

**Shared playback.** `ffplay -nodisp -autoexit -loglevel error [-ss <s>] -volume <0–100> <source>` (100 whenever the
system mixer carries the volume, see [Volume](#volume)); for a PipeWire sink the environment gets
`SDL_AUDIODRIVER=pipewire` and `PIPEWIRE_NODE=<sink id>`. Seeking restarts `ffplay` at the new position; pausing
sends `SIGSTOP` and resuming `SIGCONT`.

**Exclusive and bit-perfect playback.** Used whenever exclusive mode is on or an ALSA hardware device is selected:

```
ffmpeg -nostdin -v error [-ss <s>] -i <source> [-af volume=<gain>] -c:a pcm_s32le -f wav -
   | aplay -q -D plughw:<card>,<device>
```

ffmpeg decodes to 32-bit integer PCM at the file's own sample rate (no `-ar`; no filter in bit-perfect mode) and
the stream goes to the card's ALSA `plughw` device. Beforehand, `pw-reserve -n Audio<card> -a Wiretune -p 10 -r`
(if installed) asks PipeWire to release the card; it ends with playback.

- `plughw` is ALSA's plugin layer: if the card cannot take 32-bit samples or the file's rate, ALSA converts. Whether
  that is transparent depends on the card and driver.
- 16- and 24-bit files are padded to 32 bits (lossless). Lossy files are decoded like any other, so for them
  "bit-perfect" only describes the output stage.
- DSD (`.dsf`) is decoded to PCM by ffmpeg. There is no native DSD or DoP output.
- The `volume` filter is present only when the player itself applies the volume (not in bit-perfect mode, and not
  while the card's mixer carries it, see [Volume](#volume)) and the volume is below 100 %.
- Seeking restarts the pipeline; pausing suspends `aplay`.

**Failures.** `ffplay` exits with status 0 even when it cannot open a source (unreachable server, expired token),
so an exit with an error message in the first 3 seconds counts as a failure; in the ALSA pipeline the decoder's
exit code decides. A failed track is reported, and playback does not skip to the next one.

## Windows

- **Devices**: all active WASAPI render endpoints. Every one is listed as supporting exclusive and bit-perfect;
  Wiretune does not probe formats in advance.
- **Decoding**: Media Foundation, for files and server streams alike, so it depends on the codecs Windows ships.
  Formats it cannot decode (typically APE, WavPack and DSD, possibly Ogg/Opus) are indexed but fail with an error
  when played.
- **Output**: event-driven `WasapiOut`, 100 ms latency in shared and 50 ms in exclusive mode.
- **Exclusive** falls back to shared (with a logged warning) if initialisation fails. **Bit-perfect** has no
  fallback, because that would resample behind your back; the failure is shown instead.
- The spectrum analyser only reads the samples.

**Status: implemented, not verified on hardware.** The driver has been reviewed and its software-volume and
spectrum code is unit-tested, but the driver needs Windows and has not run in the automated tests or against a
DAC. In exclusive mode NAudio negotiates the sample format with the device: when the device does not accept the
decoded stream as it is, `WasapiOut` picks another format and inserts a conversion itself. Wiretune does not detect
or report that, so on such a device the output is not bit-perfect even though the mode says so. Reports from real
Windows setups are welcome.

## Android

`MediaPlayer` plays the file or stream; there is no exclusive or bit-perfect mode and no device selection, and
Android may resample. Other behaviour:

- Audio focus: losing it for good pauses, a transient loss (phone call) pauses and resumes, and a "duck" request
  plays at 20 % volume meanwhile. A partial wake lock keeps the CPU awake with the screen off.
- A foreground service with an ongoing *Playing* notification (no transport buttons) keeps the process alive while
  playing or paused, and stops 10 seconds after playback stops. From Android 12 the system refuses to start it
  while the app is in the background; playback continues without the protection. Android 13+ asks for notification
  permission.
- Cleartext HTTP is allowed to every destination (see [SECURITY.md](../SECURITY.md#clients)).
- No spectrum analyser.

## Volume

| Platform | How it is applied |
|---|---|
| Linux, PipeWire sink | `wpctl set-volume <sink> <0.00–1.00>`; the player runs at 100 % |
| Linux, ALSA card | `amixer -q -c <card> sset PCM <n>%`; no `volume` filter in ffmpeg |
| Linux, other output | `ffplay -volume`; moving the slider restarts playback at the current position (debounced). While paused, the new level is used from the next start or seek |
| Windows | Software gain on the PCM samples before WASAPI |
| Android | `MediaPlayer.setVolume` |

On Linux the volume is applied in one place only: the mixer when there is one, the player otherwise. The mixer is
the sink's or the card's own volume, so other applications see the change too. It is sent 60 ms after the slider stops
moving, off the UI thread. If `wpctl` or `amixer` never accepts the command for a device (many USB DACs have no `PCM`
control), Wiretune logs a warning and applies the volume in the player for that device instead. Bit-perfect mode
sends the volume nowhere.

## Spectrum analyser

32 bands (35 Hz–16 kHz, FFT 2048, about 30 updates per second) on the desktop, never changing the audio.

- **Linux**: a separate `ffmpeg` decodes the current track to 16-bit mono 44.1 kHz in memory (at most 20 minutes,
  about 106 MB, then it stops) and the analyser reads the window at the playback position. Because it is separate,
  a server track is requested from the server a second time.
- **Windows**: samples are taken from the stream being played.
- **Android**: not available.

## Known limitations

- **Windows bit-perfect is unverified** (above). Linux exclusive/bit-perfect depends on `plughw` and the driver; it
  was reviewed and run against a dummy audio device in the tests, never measured.
- **The signal-path readout shows what Wiretune requested, not what it measured.** The player describes the path of
  the current track (codec, transport, processing, access, device). In bit-perfect mode it says *Bit-perfect
  requested (PCM, no gain, exclusive device access)*; it does not check what ALSA, NAudio or the device actually do
  with the stream.
- **On Linux the progress bar runs on the clock, not on the decoder.** `FfmpegAudioDriver` computes the position
  from the time since playback (re)started, plus the seek offset; it does not read it from `ffplay` or `aplay`. While
  a source is slow to open or a stream stalls, the bar can run ahead of the sound for a moment. The Windows driver reads the
  position of its file reader and the Android driver that of `MediaPlayer`.
- **No gapless playback, no crossfade**: each track is opened when the previous one ends, leaving a short gap.
- **Seeking on Linux restarts the player**, so seeking in a server stream opens a new HTTP request.
- **Decoder coverage differs**: only Linux with ffmpeg plays everything that is indexed.
- **No equaliser, ReplayGain, media keys or system transport controls** (MPRIS, Windows media overlay, Android
  media notification). The desktop player has no global shortcuts; Enter and Escape work in text fields and
  dialogs.
- Some Settings texts are worded for Linux (*Direct ALSA / PipeWire access*) and appear on Windows too.
