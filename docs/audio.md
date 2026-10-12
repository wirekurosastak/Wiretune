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

**What Wiretune tells mpv**, in every mode: no filters, `audio-samplerate=0` (keep the file's rate), `audio-format`
left alone (keep the decoder's sample format), `audio-channels=auto-safe` (`auto`, so no downmix, in bit-perfect mode),
`replaygain` as [volume normalization](#volume-normalization) is set (always `no` in bit-perfect mode), and
`prefetch-playlist=yes` with `gapless-audio=weak` for [gapless playback](#gapless-playback). Exclusive adds `audio-exclusive=yes`: WASAPI exclusive mode on Windows, Core Audio hog mode on macOS.
An ALSA `hw:` device is exclusive by nature: it bypasses the sound server, and nothing else can use the card meanwhile.

**Linux and PipeWire.** PipeWire normally holds the card, so before opening a `hw:` device Wiretune claims it in the
device reservation protocol: it takes the D-Bus name `org.freedesktop.ReserveDevice1.Audio<card>` (priority 10), and
WirePlumber lets go of the card. The name belongs to the player's own bus connection, so PipeWire gets the card back as
soon as Wiretune lets go of it or ends in any way: closed, crashed or killed. Tried with WirePlumber; PulseAudio follows
the same protocol but hasn't been tried. When the bus can't be reached, or the card's holder won't let go, the card may
be busy and playback fails with mpv's message. Three things to know:

- If a `hw:` device can't take the file's sample format or rate, mpv converts it in its own chain. Wiretune doesn't
  notice, so the switch says bit-perfect when it isn't. `WIRETUNE_LOG_LEVEL=debug` shows the format mpv chose.
- DSD (`.dsf`) is decoded to PCM by FFmpeg. No native DSD, no DoP.
- Lossy files decode like any other, so for them "bit-perfect" only describes the output stage.

**When a track won't play.** mpv reports some failures only in its log, and a source it can't open can leave it idle
without an error. So a track that hasn't started after 3 seconds, or fails before you heard anything, counts as
failed: the player says why and stops there instead of skipping ahead. The same goes for the next track that was
waiting for a gapless start: when mpv can't open it, playback stops after the current one with mpv's message.

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

## Gapless playback

On by default; *Settings → Audio → Gapless playback* turns it off, and each track then opens when the previous one
ends. While a track plays, the player gives mpv the entry that comes after it in the queue (the same track again with repeat
one, the first with repeat all, nothing while the sleep timer waits for the end of the track) and gives it again
whenever the queue, shuffle, repeat or the sleep timer change. mpv opens it ahead (`prefetch-playlist`, which for a
server track means the stream is requested early) and goes on to it without reopening the output when the sample
format, rate and channels are the same (`gapless-audio=weak`). When they differ, mpv sets the output up again, which
leaves a short gap, as does exclusive output changing its format. The player counts the next track as playing once mpv
reports its first position. Tried on Linux with mpv's PipeWire output; Windows, macOS and the phones run the same code
untried. On Tizen each track still opens when the previous one ends.

## Volume normalization

*Settings → Audio → Volume normalization* (*Off*, the default, *Per track* or *Per album*) is mpv's ReplayGain: it reads the
files' `REPLAYGAIN_TRACK_GAIN` or `REPLAYGAIN_ALBUM_GAIN` tags and turns the gain into mpv's software volume, lowered
where it would clip (mpv's default `replaygain-clip`). A file without the tags plays as it is. It is a gain, so
bit-perfect mode leaves it out whatever the setting; exclusive mode without bit-perfect, and the phones, apply it. The
signal path says when it's on. Tizen's player reads no ReplayGain tags, so the TV doesn't offer it.

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
  *Bit-perfect requested (PCM, no gain, exclusive device access)* (or *Bit-perfect requested (lossy source decoded to PCM, no gain, exclusive device access)* when playing a lossy file), and means exactly that.
- **No crossfade**, and gapless only between tracks of the same format ([above](#gapless-playback)).
- **No equaliser.**
- **Windows and Tizen have no system media controls.** Windows media keys work while the window has the focus; on a
  Tizen TV the remote's media keys work inside the app.
