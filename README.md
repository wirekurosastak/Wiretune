# Wiretune

Cross-platform music player for self-hosted libraries and local files.

- Exclusive and bit-perfect output: plays straight to the DAC, around the system mixer (desktop only).
- Windows, Linux, macOS, Android (phone, tablet, TV, Auto), iOS, Tizen TV.
- A **server** indexes your music folder; the **player** streams from it, plays a local folder, or both.
- No cloud, no third-party account, no telemetry. Only artist pictures and missing lyrics come from the internet, and both can be
  turned off ([SECURITY.md](SECURITY.md#players)).

![The albums on a computer](docs/images/albums.png)

![The albums, an album and the full-screen player on a phone](docs/images/phone.png)

<sub>The albums, artists and covers in these pictures are made up.</sub>

## Features

- Artists, albums, tracks, search, queue, favorites, playlists, sleep timer.
- Synced lyrics, from the file or [LRCLIB](https://lrclib.net).
- Gapless playback. FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD, MP3, AAC, Vorbis, Opus (FFmpeg via libmpv; Tizen uses
  the TV's decoder).
- New files in the music folder show up on their own, about ten seconds after copying stops.
- Quality tag per album and track: gold (hi-res), silver (CD-quality lossless), bronze (lossy).
- Favorites, play counts and playlists live on the server, per account.
- Offline downloads, synced with the server.
- Remote control: steer one device from another.
- 64-band spectrum analyzer on desktop.
- Lock-screen controls, Android Auto, TV layout, MPRIS on Linux.
- English, Hungarian, German.

## Platform support

| | Linux | Windows | macOS | Android | Android TV | Android Auto | iOS | Tizen TV |
|---|---|---|---|---|---|---|---|---|
| Play a server library | Yes | Yes | Yes | Yes | Yes | Browse and play | Yes | Yes |
| Play a local folder | Yes | Yes | Yes | Yes | No | No | No | No |
| Exclusive / bit-perfect | Yes (ALSA `hw:`, tried on SMSL SU-1) | Yes (WASAPI, tried on SMSL SU-1) | Written, **not tried on a DAC** | No | No | No | No | No |
| Spectrum analyzer | With `ffmpeg` | With `ffmpeg` | With `ffmpeg` | No | No | No | No | No |
| System media controls | MPRIS | No | Media keys, Now Playing | Notification, lock screen | Remote | The car | Lock screen, Control Center | Remote, in the app |
| Run the server | Yes | Yes | Yes | — | — | — | — | — |

Supported doesn't mean tried on real hardware: see [what has actually been tried](docs/development.md#what-has-actually-been-tried).
Bit-perfect depends on the whole path to the DAC: see [audio.md](docs/audio.md).

## Quick start

Build the server and a player ([building.md](docs/building.md) lists what to install per system), e.g. on Linux:

```bash
dart tool/build.dart server linux
dist/server/bin/wiretune_server --library ~/Music      # the server
dist/linux/wiretune                                     # the player
```

In the player, enter `http://<server-ip>:5200` and press **Connect**. A new server asks for the first account, which
becomes the administrator, using the **setup code** from the server log. There are no default passwords.

No server? Choose **Continue without a server** and point *Settings* at your music folder.

The server speaks plain HTTP. Keep it on your LAN, or put a TLS proxy or VPN in front of it.

## Documentation

- [User guide](docs/user-guide.md): library rules, playback, file locations, troubleshooting.
- [Server](docs/server.md): options, accounts, backups, Docker, systemd, reverse proxy.
- [Audio](docs/audio.md): output modes and their limits.
- [Building](docs/building.md), [Development](docs/development.md), [Contributing](CONTRIBUTING.md).
- [HTTP API](docs/api.md), [Security](SECURITY.md).

## Credits

Playback: [media_kit](https://github.com/media-kit/media-kit) (libmpv, FFmpeg). System media controls:
[audio_service](https://pub.dev/packages/audio_service).

## License

Copyright (C) 2026 wirekurosastak. [GNU AGPL v3](LICENSE) with the additional terms in [NOTICE.md](NOTICE.md).
A modified version must stay under the same license with source available (also to network users), keep Wiretune's
copyright notices, say it's based on Wiretune, and use a different name.
