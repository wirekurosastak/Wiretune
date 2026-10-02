# Audio

This document describes what Wiretune does between "play" and the sound card on each platform, what the three
output modes mean, and which parts have not been verified. Read it before relying on the term "bit-perfect".

## Overview

`WiretuneAudioEngine` (in `Wiretune.Core/Audio`) owns the playback state, the output device selection and the
mode switches. The actual playback is done by a driver that implements `IAudioDriver`:

| Platform | Driver | How audio is produced |
|---|---|---|
| Linux | `FfmpegAudioDriver` | Child processes: `ffplay`, or `ffmpeg` piped into `aplay` |
| Windows | `WasapiAudioDriver` | NAudio `WasapiOut`; files and URLs decoded by Media Foundation |
| Android | `AndroidAudioDriver` | Android `MediaPlayer` |

The engine passes the driver a source (a file path, or a stream URL with `?token=…` appended at that moment),
the track's format and a start position. Local tracks play from their file path; server tracks play from the
server's `/api/stream/{id}` URL, so a server track needs no download first.

Any desktop that is not Windows gets `FfmpegAudioDriver`, but only Linux is a target: the pause mechanism and the
ALSA modes below are Linux-specific, and no other platform is documented or tested.

## Output modes

| Mode | Meaning in Wiretune |
|---|---|
| **Shared** | Normal playback through the operating system's mixer. The volume control works. Available everywhere. |
| **Exclusive** | Wiretune opens the output device directly instead of going through the system mixer. The volume control still works. Linux and Windows only. |
| **Bit-perfect** | Exclusive mode plus: Wiretune applies no gain of its own, so the volume is fixed at 100 % (slider and mute are disabled). Linux and Windows only. |

Turning bit-perfect on also turns exclusive mode on; turning exclusive mode off also turns bit-perfect off. If
no detected device supports the requested mode, the engine reports *None of the output devices supports
exclusive mode / bit-perfect playback on this system* and the mode stays off. Changing the mode or the output
device while a track is playing restarts that track at the current position.

"Bit-perfect" here describes the path Wiretune sets up (lossless decode, no gain, exclusive device access, no
resampling requested by Wiretune). Whether the bits that reach the DAC are identical to the file also depends
on the driver and the hardware; Wiretune does not measure this. See [Known limitations](#known-limitations).

## Linux

### Devices

The list is built from two sources, each queried with a 3-second timeout:

- `wpctl status`: PipeWire sinks (shown with the driver type *PipeWire*). They are **shared-mode only**.
- `aplay -l`: ALSA hardware devices, shown as `ALSA: <card>` with the driver type *ALSA Direct* and the ID
  `hw:<card>,<device>`. These are the devices that support exclusive and bit-perfect output.

The default is the sink `wpctl` marks as default, otherwise the first entry. If neither tool is installed, a
single *Default audio output* entry (shared mode only) is offered. The list is detected at start-up and again when
you press **Refresh** in Settings.

### Shared playback

`ffplay -nodisp -autoexit -loglevel error [-ss <seconds>] -volume <0–100> <source>`. For a PipeWire sink the
process environment is set to `SDL_AUDIODRIVER=pipewire` and `PIPEWIRE_NODE=<sink id>`; for the generic default
entry ffplay uses its own default output. Seeking restarts `ffplay` at the new position. Pausing sends
`SIGSTOP` to the process and resuming sends `SIGCONT`.

### Exclusive and bit-perfect playback

Used whenever exclusive mode is on or an ALSA hardware device is selected:

```
ffmpeg -nostdin -v error [-ss <seconds>] -i <source> [-af volume=<gain>] -c:a pcm_s32le -f wav -
   | aplay -q -D plughw:<card>,<device>
```

ffmpeg decodes to 32-bit integer PCM at the file's own sample rate (no `-ar`, no filters in bit-perfect mode)
and the stream goes to ALSA's `plughw` device of the selected card. Before starting, Wiretune runs
`pw-reserve -n Audio<card> -a Wiretune -p 10 -r` (if installed) to ask the PipeWire session manager to release the
card, and ends that process when playback stops.

Notes:

- `plughw` is ALSA's plugin layer: if the card cannot take 32-bit samples or the file's sample rate, ALSA converts
  the stream. Whether that conversion is transparent depends on the card and driver.
- A 16- or 24-bit file is padded to 32 bits, which is lossless; lossy files (MP3, AAC, …) are decoded to PCM like
  any other file, so "bit-perfect" only describes the output stage for them.
- DSD files (`.dsf`) are decoded to PCM by ffmpeg. There is no native DSD or DoP output.
- The gain argument is only present in exclusive (not bit-perfect) mode with the volume below 100 %.
- Seeking restarts the pipeline at the new position; pausing suspends `aplay`.

### Failures

If `ffplay` is missing the player shows *ffplay was not found. Install FFmpeg and make sure it is on your PATH.*;
if `ffmpeg` or `aplay` is missing in exclusive mode, *Direct ALSA playback cannot start (ffmpeg or aplay is
missing)*. `ffplay` exits with status 0 even when it cannot open a source (unreachable server, expired token), so
Wiretune treats an exit with an error message within the first 3 seconds as a failure; in the ALSA pipeline the
decoder's exit code decides. A failed track is reported instead of silently skipping to the next one.

## Windows

- **Devices**: all active WASAPI render endpoints (`MMDeviceEnumerator`). Every one is listed as supporting
  exclusive and bit-perfect output; Wiretune does not probe the device's formats in advance.
- **Decoding**: Media Foundation (`MediaFoundationReader`), for local files and server stream URLs alike. What
  can be played therefore depends on the codecs Windows provides. Formats Windows cannot decode (typically APE,
  WavPack and DSD, and possibly Ogg/Opus, depending on the installed codecs) are indexed but fail with an error
  when played.
- **Output**: NAudio `WasapiOut` in event-driven mode, 100 ms latency in shared mode and 50 ms in exclusive mode.
- **Exclusive**: if the exclusive-mode initialisation fails, Wiretune logs a warning and falls back to shared
  mode. In bit-perfect mode there is no fallback, because that would resample the signal behind the user's back:
  the failure is shown as an error message (for example *Playback cannot start: …*).
- **Bit-perfect**: exclusive mode with the software gain switched off. The spectrum analyser only reads the
  samples; it does not modify them.
- **Seeking and pausing** use the reader's position and `WasapiOut.Pause`.

**Status: implemented, not verified on hardware.** The driver has been reviewed and its software-volume and
spectrum code is unit-tested, but the driver itself needs Windows and has not been run in the automated tests or
checked against a DAC. In particular, in exclusive mode NAudio negotiates the sample format with the device: when
the device does not accept the decoded stream as it is, `WasapiOut` chooses another format and inserts a
conversion step by itself. Wiretune does not detect or report that, so on such a device the output is not
bit-perfect even though the mode says so. Feedback from real Windows setups is welcome.

## Android

`AndroidAudioDriver` plays through the platform `MediaPlayer`. There is no exclusive or bit-perfect mode and no
output device selection: Android decides the route and may resample. Behaviour worth knowing:

- Audio focus is requested when playback starts. Losing focus for good (another player) pauses; a transient loss
  (phone call) pauses and resumes when focus returns; a "duck" request (navigation prompt) plays at 20 % volume
  for its duration.
- A partial wake lock keeps the CPU awake while playing with the screen off.
- A foreground service with an ongoing *Playing* notification keeps the process alive while playing or paused.
  It has no transport buttons: the notification only brings the app back to the front. The service is stopped
  10 seconds after playback stops, so the gap between two tracks does not tear it down. From Android 12 the
  system refuses to start a foreground service while the app is in the background; playback then continues but
  without the notification and its protection from being killed. On Android 13 and later the app asks for the
  notification permission.
- The spectrum analyser is not available.
- Cleartext HTTP is permitted for every destination, because servers are usually addressed by LAN IP and
  Android cannot match IP ranges in its network security configuration. Reach a server outside the home network
  through an HTTPS reverse proxy.

## Volume

The volume slider and mute work in shared and exclusive mode and are locked in bit-perfect mode.

| Platform | How the volume is applied |
|---|---|
| Linux, PipeWire sink | `wpctl set-volume <sink> <0.00–1.00>` |
| Linux, ALSA card | `amixer -q -c <card> sset PCM <n>%` |
| Linux, other output | `ffplay -volume`; changing the slider restarts playback at the current position (debounced) |
| Windows | Software gain on the PCM samples before they reach WASAPI |
| Android | `MediaPlayer.setVolume` |

For the PipeWire and ALSA cases the slider is applied to the mixer after a 60 ms pause in slider movement, off
the UI thread.

## Spectrum analyser

A 32-band analyser (35 Hz to 16 kHz, FFT size 2048, roughly 30 updates per second) is shown in the player on the
desktop. How it gets its samples differs:

- **Linux**: a separate `ffmpeg` process decodes the current track in the background to 16-bit mono 44.1 kHz and
  keeps it in memory (at most 20 minutes of audio, about 106 MB; the analyser stops after that). The analyser reads
  the window at the current playback position. This process is independent of playback, so for a server track the
  stream is requested from the server a second time.
- **Windows**: the samples are taken from the stream that is being played (down-averaged for sample rates above
  44.1 kHz).
- **Android**: not available.

The analyser never changes the audio that is played.

## Signal path

The player shows a short description of the path for the current track: source (quality label, codec, bit
depth, sample rate), transport (local file or server stream), processing (bit-perfect or system mixer), access
(exclusive or shared) and target device. It is composed from the selected mode and the track's tags; it
describes the intended path and is not a measurement of what the driver or the hardware did.

## Known limitations

- **Windows bit-perfect is unverified** (see [Windows](#windows)). Linux exclusive/bit-perfect depends on
  `plughw` and the driver as described above; both paths were reviewed and exercised with a dummy audio device
  in the tests, not with measurement equipment.
- **The signal-path text says more than it knows.** In bit-perfect mode it states *resampler OFF* and *unity
  gain*; that is what Wiretune requests, not something it checks.
- **Linux volume may be applied twice.** For PipeWire sinks and ALSA cards the slider is applied to the system
  mixer, and the same value is also passed to `ffplay -volume` (shared playback) or to ffmpeg's `volume` filter
  (exclusive playback) when a track starts. The net attenuation has not been measured and may be stronger than
  the slider position suggests, especially from the second track on. Bit-perfect mode is not affected: it
  passes 100 % and no gain to the player.
- **No gapless playback and no crossfade.** Each track is opened when the previous one ends, which leaves a short
  gap (starting a process on Linux, opening the source on Windows).
- **Seeking on Linux restarts the player process**, so a seek in a server stream opens a new HTTP request.
- **Decoder coverage differs per platform** (see [Windows](#windows) and [Android](#android)); only Linux with
  ffmpeg plays everything that is indexed.
- **No equaliser, ReplayGain, or operating-system media keys / transport controls** (MPRIS, Windows media
  overlay, Android media notification). The desktop app has no global keyboard shortcuts; only Enter and Escape
  work inside text fields and dialogs.
- Some interface texts in Settings are worded for Linux (for example *Direct ALSA / PipeWire access* next to the
  exclusive-mode switch) and are shown on Windows too.
