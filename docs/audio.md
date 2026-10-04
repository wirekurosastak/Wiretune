# Audio

What Wiretune does between "play" and the sound card, what the output modes mean, and what has not been
verified. Read this before relying on the word "bit-perfect".

`WiretuneAudioEngine` (core) owns the playback state, the output device and the mode switches; a platform driver
implementing `AudioDriver` does the playing:

| Platform | Driver | How audio is produced |
|---|---|---|
| Linux, Windows, macOS | `MediaKitAudioDriver` | libmpv (through media_kit): FFmpeg decodes; the output is ALSA, PipeWire or PulseAudio, WASAPI, or Core Audio |
| Android, iOS | `MediaKitAudioDriver` | libmpv, to the system's audio output; no device choice |
| Tizen | `TizenAudioDriver` | The TV's own media player (through `audioplayers_tizen`) |

Local tracks play from their file path. Server tracks play straight from the server's `/api/stream/{id}` URL (a
short-lived stream token, not the sign-in token, is appended when playback starts), so nothing is downloaded first;
mpv reads ahead into a 64 MB buffer and seeks with HTTP range requests.

Because libmpv brings FFmpeg, every format the server indexes (FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD, MP3, AAC,
Vorbis, Opus) plays the same on Linux, Windows, macOS, Android and iOS. Tizen is the exception (below).

## Output modes

| Mode | Meaning |
|---|---|
| **Shared** | Normal playback through the operating system's mixer. Volume works. Everywhere. |
| **Exclusive** | Wiretune opens the output device directly instead of going through the mixer. Volume still works. Linux, Windows, macOS. |
| **Bit-perfect** | Exclusive plus no gain of Wiretune's own: the volume is fixed at 100 % and the slider and mute are disabled. Linux, Windows, macOS. |

Bit-perfect switches exclusive on, and switching exclusive off switches bit-perfect off. If no detected device
supports the requested mode, the engine says so and the mode stays off. Changing mode or device mid-track
restarts the track at the current position.

"Bit-perfect" describes the path Wiretune sets up: lossless decode, no gain, exclusive access, no filters, no
resampling and no sample format requested. Whether the bits reaching the DAC equal the file also depends on mpv, the
driver and the hardware, and Wiretune does not measure it. The card's own mixer is left alone, so a hardware volume
below 100 % still attenuates the signal there; set it to 100 % yourself (for example in `alsamixer`).

## Desktop (Linux, Windows, macOS)

**Devices.** *System default output* first (shared only), then

- on Linux, the PipeWire (or, without PipeWire, PulseAudio) sinks from mpv's list, which are shared only, and the ALSA
  hardware devices, shown as `ALSA: <card> (<device>)` and opened as `alsa/hw:<card>,<device>`, which support
  exclusive and bit-perfect. mpv's own list usually leaves the hardware devices out, so Wiretune reads them from
  `aplay -l`, as the C# player did, or from `/proc/asound` when `aplay` is not installed;
- on Windows, the WASAPI endpoints, listed as supporting exclusive and bit-perfect (Wiretune does not probe their
  formats in advance);
- on macOS, the Core Audio devices, likewise.

mpv fills its list a moment after it starts; Wiretune waits up to 3 seconds for it. The list is built at start-up and
on **Refresh**.

**Playback settings.** Whatever the mode, Wiretune sets mpv's `af` (filters) empty, `replaygain=no`,
`audio-samplerate=0` (keep the file's rate), `audio-format=no` (keep the file's sample format) and
`audio-channels=auto-safe` (`auto`, no downmix, in bit-perfect mode). Exclusive mode sets `audio-exclusive=yes`:
WASAPI's exclusive mode on Windows; on macOS mpv switches to its exclusive Core Audio output (hog mode). An ALSA `hw:`
device is exclusive by its nature: it bypasses the sound server and nothing else can use the card meanwhile.

**Linux and PipeWire.** A `hw:` device is normally held by PipeWire. Before opening one, Wiretune runs
`pw-reserve -n Audio<card> -a Wiretune -p 10 -r` (if it is installed), which asks PipeWire to release the card for as
long as Wiretune uses it, and waits 300 ms for that. Without `pw-reserve` the card may be busy, and playback fails with
mpv's message.

- When a `hw:` device cannot take the file's sample format or rate, mpv converts it in its own audio chain (where the
  C# version left that to ALSA's `plughw`). Wiretune does not detect it, so on such a card the output is not
  bit-perfect even though the mode says so; mpv's log (`WIRETUNE_LOG_LEVEL=debug`) shows the format it chose.
- DSD (`.dsf`) is decoded to PCM by FFmpeg. There is no native DSD or DoP output.
- Lossy files are decoded like any other, so for them "bit-perfect" only describes the output stage.

**Failures.** mpv reports some failures only as log lines, and a source it cannot open can leave it idle without an
error. So a track that has not started after 3 seconds, or reports an error before anything was heard, counts as
failed: it is reported in the player, and playback does not skip to the next one.

## Android

libmpv plays the file or stream; there is no exclusive or bit-perfect mode and no device selection (Android routes the
sound to the speaker, headphones, Bluetooth or the car), and Android may resample. Other behaviour:

- **Audio focus** (`audio_session`): a phone call or another app's playback pauses, and a transient loss (the call)
  resumes when it ends; a "duck" request (a navigation prompt) plays at 20 % volume meanwhile. Unplugging headphones or
  disconnecting Bluetooth pauses.
- **Background playback**: a foreground service (audio_service) with a media notification (previous, play/pause, next,
  seek bar) keeps the process alive while playing and while paused; the lock screen, Bluetooth and headset buttons
  control it. While music plays the app holds a CPU lock and a Wi-Fi lock, so a stream keeps flowing with the screen
  off. Android 13 and later show the media notification without asking for the notification permission.
- **Android TV**: the same app; the remote's media keys work, and the system's media controls show the track.
- **Android Auto**: the car's screen lists albums, artists, playlists and favourites and plays from them; voice
  search ("play … on Wiretune") searches the library. Playback is the phone's.
- Cleartext HTTP is allowed to every destination (see [SECURITY.md](../SECURITY.md#clients)).
- No spectrum analyser, no volume slider (the phone's volume keys are the volume).

## iOS

libmpv, as on Android. The app keeps playing in the background, the lock screen and Control Center show and control
it, a phone call pauses it and the end of the call resumes it. iOS asks once for *local network* access, which a
server on the LAN needs. No exclusive mode, no spectrum analyser, no volume slider.

## Tizen

The TV's media player plays the file or stream. What it decodes depends on the TV's firmware: typically FLAC, WAV, MP3,
AAC and Vorbis; ALAC, APE, WavPack, DSD and Opus may well fail with an error. The TV's own output and volume apply (the
remote's volume keys), there is no device choice and no exclusive mode, and the position is polled four times a second.
Not yet tried on a TV ([development.md](development.md#what-has-been-verified)).

## Volume

The slider (desktop only) sets mpv's software volume, applied to the decoded samples before the output; the system
mixer and the card's mixer are not touched (the C# version moved them on Linux). In bit-perfect mode the volume is
fixed at 100 % and mpv applies no gain. Phones, tablets and TVs have no slider: their volume keys set the system's
volume, and Wiretune plays at 100 %.

## Spectrum analyser

32 bands (35 Hz–16 kHz, FFT 2048, about 30 updates per second) on the desktop, never changing the audio. A separate
`ffmpeg` decodes the current track to 16-bit mono 44.1 kHz in memory (at most 20 minutes, about 106 MB, then it stops)
and the analyser reads the window at the playback position. Because it is separate, a server track is requested from
the server a second time. Without `ffmpeg` on the `PATH` the analyser stays dark and the log says why. Phones, TVs and
the car have none.

## Known limitations

- **Exclusive and bit-perfect are unverified on every platform.** On Linux the path is mpv's ALSA output on a `hw:`
  device, reviewed but never measured; on Windows (WASAPI) and macOS (Core Audio) the code is written and has not run
  against a DAC. Reports from real setups are welcome.
- **The signal-path readout shows what Wiretune requested, not what it measured.** The player describes the path of
  the current track (codec, transport, processing, access, device). In bit-perfect mode it says *Bit-perfect
  requested (PCM, no gain, exclusive device access)*; it does not check what mpv, the driver or the device actually do
  with the stream.
- **No gapless playback, no crossfade**: each track is opened when the previous one ends, leaving a short gap.
- **No equaliser and no ReplayGain** (mpv's is switched off on purpose).
- **Windows and Tizen have no system media controls.** Windows media keys work while the window has the focus; the
  Windows media overlay is not fed. On a Tizen TV the remote's media keys work inside the app.
- **Tizen decodes less** than the other platforms (above).
