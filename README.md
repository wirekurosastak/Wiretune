# Wiretune

**Cross-platform lossless music player for self-hosted libraries and local files.**

Wiretune has two parts. A server you run at home indexes your music folder and streams it over your network, and the
player plays from that server, from a folder on the device, or both. The player runs on Linux, Windows, macOS, Android
(phone, tablet, TV and Auto), iOS and Samsung's Tizen TVs, and on a computer it can bypass the system mixer to play
bit-perfect, straight to your DAC.

There's no cloud service, no third-party account and no telemetry. Only artist pictures and lyrics for tracks without
any come from the internet, and both can be turned off ([what's sent](SECURITY.md#what-leaves-your-network)).

![The albums on a computer](docs/images/albums.png)

![The albums, an album and the full-screen player on a phone](docs/images/phone.png)

<sub>The albums, artists and covers in these pictures are made up.</sub>

## Features

- Browse by artist, album and track, with search, a queue, favorites, playlists and a sleep timer.
- Gapless playback of FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD (decoded to PCM), MP3, AAC, Vorbis and Opus.
- Synced lyrics, from the file or from [LRCLIB](https://lrclib.net).
- A quality badge on every album and track: hi-res, CD-quality or lossy.
- An account for each listener, with favorites, playlists and play counts that follow them to every device.
- Downloads for offline listening, kept in sync with the server.
- Remote control: steer what one device plays from another.
- English, Hungarian and German.

## Platform support

| | Linux | Windows | macOS | Android | Android TV | Android Auto | iOS | Tizen TV |
|---|---|---|---|---|---|---|---|---|
| Play a server library | Yes | Yes | Yes | Yes | Yes | Browse and play | Yes | Yes |
| Play a local folder | Yes | Yes | Yes | Yes | No | No | No | No |
| Exclusive / bit-perfect | Yes | Yes | Untested | No | No | No | No | No |
| Spectrum analyzer | With `ffmpeg` | With `ffmpeg` | With `ffmpeg` | No | No | No | No | No |
| System media controls | MPRIS | Media keys, while focused | Media keys, Now Playing | Notification, lock screen | Remote | The car | Lock screen, Control Center | Remote, in the app |
| Run the server | Yes | Yes | Yes | — | — | — | — | — |
| [Tried on real hardware](docs/development.md#what-has-actually-been-tried) | Yes | Yes | No | Phone | No | No | No | Briefly |

Bit-perfect means Wiretune sets up an untouched path to the DAC; it doesn't measure what arrives
([audio.md](docs/audio.md#bit-perfect)). Samsung TVs decode with their own player, so some formats may not play there
([audio.md](docs/audio.md#tizen)).

## Quick start

Install what your system needs ([building.md](docs/building.md)), then build and start the server and a player. On
Linux:

```bash
dart tool/build.dart server linux
dist/server/bin/wiretune_server --library ~/Music      # the server
dist/linux/wiretune                                     # the player
```

In the player, enter `http://<server-ip>:5200` and press **Connect**. A new server has no accounts and no default
password, so it asks you to create the first account, which becomes the administrator, with the **setup code** printed
in its log. To play a folder on this device without a server, choose **Continue without a server** and pick your music
folder in *Settings*.

The server speaks plain HTTP, so keep it on your LAN or put a TLS proxy or VPN in front of it
([server.md](docs/server.md#reverse-proxy-and-tls)).

## Documentation

- [User guide](docs/user-guide.md): using the player, how it builds the library, where it keeps its files, troubleshooting.
- [Running the server](docs/server.md): Docker, systemd, reverse proxies, accounts, backups and options.
- [Audio](docs/audio.md): what the output modes do, and what hasn't been verified.
- [Security](SECURITY.md): what Wiretune does and doesn't protect against, and how to report a problem.
- For contributors: [building](docs/building.md), [development](docs/development.md),
  [contributing](CONTRIBUTING.md) and the [HTTP API](docs/api.md).

## Credits

Playback uses [media_kit](https://github.com/media-kit/media-kit), which brings libmpv and FFmpeg, and the system media
controls use [audio_service](https://pub.dev/packages/audio_service).

## License

Copyright (C) 2026 wirekurosastak. [GNU AGPL v3](LICENSE) with the additional terms in [NOTICE.md](NOTICE.md).
A modified version must stay under the same license with source available (also to network users), keep Wiretune's
copyright notices, say it's based on Wiretune, and use a different name.
