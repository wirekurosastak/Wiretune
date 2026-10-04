# Audio

What happens between "play" and your speakers, what the output modes really mean, and what hasn't been proven yet.
Read this before you trust the word "bit-perfect".

## Who plays what

| Platform | Driver | Underneath |
|---|---|---|
| Linux, Windows, macOS | `MediaKitAudioDriver` | libmpv: FFmpeg decodes, then ALSA, PipeWire or PulseAudio, WASAPI, or Core Audio |
| Android, iOS | `MediaKitAudioDriver` | libmpv, to whatever output the system picks |
| Tizen | `TizenAudioDriver` | The TV's own media player |

Local tracks play from the file. Server tracks stream straight from `/api/stream/{id}`, nothing downloaded first: mpv
reads ahead into a 64 MB buffer and seeks with range requests. Because libmpv brings FFmpeg, every format the server
indexes plays the same everywhere except on Tizen ([below](#tizen)).

## Output modes

| Mode | What it does | Where |
|---|---|---|
| **Shared** | Plays through the system mixer like any other app. Volume works. | Everywhere |
| **Exclusive** | Opens the output device directly, around the mixer. Volume still works. | Desktop |
| **Bit-perfect** | Exclusive, plus no gain of Wiretune's own: the volume is pinned at 100 %, slider and mute disabled. | Desktop |

Bit-perfect switches exclusive on, and switching exclusive off switches bit-perfect off. If no device can do a mode,
the player says so and the switch stays off. Changing the mode or the device mid-track restarts the track where it was.

**What "bit-perfect" means here.** Wiretune sets up a path with lossless decoding, no gain, exclusive access, no
filters, and no resampling or sample-format change requested. Whether the bits that reach the DAC still equal the file
also depends on mpv, the driver and the hardware, and Wiretune doesn't measure that. It also leaves the card's own mixer
alone: a hardware volume below 100 % still attenuates the signal, so set it to 100 % yourself (`alsamixer`, for
example).

## Desktop

**Devices.** *System default output* comes first (shared only). After it, on Linux, the PipeWire or PulseAudio sinks
(shared only) and the ALSA hardware devices, shown as `ALSA: <card> (<device>)` and opened as `alsa/hw:…`, which do
exclusive and bit-perfect; mpv tends to leave the hardware out of its list, so Wiretune reads it from `aplay -l` or
`/proc/asound`. On Windows the WASAPI endpoints, and on macOS the Core Audio devices, are offered for exclusive and
bit-perfect without probing their formats first. The list is built at start-up and on **Refresh**.

**What Wiretune tells mpv**, in every mode: no filters, `replaygain=no`, `audio-samplerate=0` (keep the file's rate),
`audio-format` left alone (keep the decoder's sample format), and `audio-channels=auto-safe` (`auto`, so no downmix, in
bit-perfect mode). Exclusive adds `audio-exclusive=yes`: WASAPI exclusive mode on Windows, Core Audio hog mode on macOS.
An ALSA `hw:` device is exclusive by nature: it bypasses the sound server, and nothing else can use the card meanwhile.

**Linux and PipeWire.** PipeWire normally holds the card, so before opening a `hw:` device Wiretune runs
`pw-reserve -n Audio<card> -a Wiretune -p 10 -r` (if it's installed), which asks PipeWire to let go for as long as
Wiretune needs it. Without `pw-reserve` the card may be busy, and playback fails with mpv's message. Three things to
know:

- If a `hw:` device can't take the file's sample format or rate, mpv converts it in its own chain. Wiretune doesn't
  notice, so the switch says bit-perfect when it isn't. `WIRETUNE_LOG_LEVEL=debug` shows the format mpv chose.
- DSD (`.dsf`) is decoded to PCM by FFmpeg. No native DSD, no DoP.
- Lossy files decode like any other, so for them "bit-perfect" only describes the output stage.

**When a track won't play.** mpv reports some failures only in its log, and a source it can't open can leave it idle
without an error. So a track that hasn't started after 3 seconds, or fails before you heard anything, counts as
failed: the player says why and stops there instead of skipping ahead.

## Android and iOS

libmpv plays to wherever the system routes the sound: speaker, headphones, Bluetooth, the car. No exclusive or
bit-perfect mode, no device choice, no spectrum and no volume slider (the volume keys are the volume), and the system
may resample.

- A phone call pauses playback and its end resumes it; on Android another app's playback pauses it too, and a
  navigation prompt ducks it to 20 %. Unplugging headphones or losing Bluetooth pauses.
- It keeps playing in the background, with the screen off, and the notification, lock screen, Control Center,
  Bluetooth and headset buttons control it. On Android the app holds CPU and Wi-Fi locks while it plays, so a stream
  keeps flowing.
- Android TV is the same app, steered by the remote. Android Auto lists albums, artists, playlists and favourites on
  the car's screen and takes voice search ("play … on Wiretune"); the playing happens on the phone.
- iOS asks once for *local network* access, which a server on your LAN needs.

## Tizen

The TV's own media player does the work, so what decodes depends on the firmware: usually FLAC, WAV, MP3, AAC and
Vorbis, while ALAC, APE, WavPack, DSD and Opus may well fail with an error. The TV's own output and volume apply, and
there's no device choice or exclusive mode. Not tried on a real TV yet.

## Volume and the spectrum

The desktop volume slider is mpv's software volume, applied to the decoded samples; the system mixer and the card's
mixer are left alone. Bit-perfect pins it at 100 %, which means no gain at all.

The spectrum analyser (desktop, 32 bands from 35 Hz to 16 kHz, about 30 updates a second) never touches what you hear:
a separate `ffmpeg` decodes the current track in memory (up to 20 minutes of it) and the analyser reads the window at
the playback position. That means a server track is fetched a second time. Without `ffmpeg` on the `PATH` the bars
stay dark, and the log says why.

## Known limitations

- **Exclusive and bit-perfect are unverified everywhere.** The Linux path (mpv's ALSA output on a `hw:` device) has been
  reviewed but never measured; on Windows and macOS the code has never met a DAC. Reports from real setups are very
  welcome.
- **The signal-path readout shows what Wiretune asked for, not what it measured.** In bit-perfect mode it says
  *Bit-perfect requested (PCM, no gain, exclusive device access)*, and means exactly that.
- **No gapless playback, no crossfade**: each track opens when the previous one ends, with a short gap.
- **No equaliser and no ReplayGain** (mpv's is switched off on purpose).
- **Windows and Tizen have no system media controls.** Windows media keys work while the window has the focus; on a
  Tizen TV the remote's media keys work inside the app.
