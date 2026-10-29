# Wiretune

**Lossless music player for your own server and local files.**

Wiretune has two parts:

- **Server**: runs at home, indexes your music folder and streams it.
- **Player**: plays from the server, a local folder, or both. Runs on Linux, Windows, macOS, Android (phone, tablet, TV,
  Auto), iOS and Samsung Tizen TVs. On a computer it can play bit-perfect to your DAC.

No cloud, no third-party account, no telemetry. The only internet requests are artist pictures, missing lyrics and the
update check. Each can be turned off ([details](SECURITY.md#what-leaves-your-network)).

![The albums on a computer](docs/images/albums.png)

![The albums, an album and the full-screen player on a phone](docs/images/phone.png)

<sub>The albums, artists and covers in these pictures are made up.</sub>

## Features

- Artists, albums, tracks, search, queue, favorites, playlists, sleep timer.
- Gapless playback: FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD (as PCM), MP3, AAC, Vorbis, Opus.
- Synced lyrics, from the file or [LRCLIB](https://lrclib.net).
- Quality badge on every album and track: hi-res, CD or lossy.
- One account per listener. Favorites, playlists and play counts are the same on every device.
- Offline downloads that stay in sync with the server.
- Remote control: control one device from another.
- English, Hungarian, German.

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

Bit-perfect sets up an untouched path to the DAC. It doesn't measure what arrives
([audio.md](docs/audio.md#bit-perfect)). Samsung TVs use their own decoder, so some formats may not play
([audio.md](docs/audio.md#tizen)).

## Quick start

Install the dependencies ([building.md](docs/building.md)), then on Linux:

```bash
dart tool/build.dart server linux
dist/server/bin/wiretune_server --library ~/Music      # the server
dist/linux/wiretune                                     # the player
```

In the player, connect to the server and create the first account with the setup code from the server log
([first start](docs/user-guide.md#first-start)). For access away from home, use Tailscale or HTTPS
([how](docs/server.md#away-from-home)).

## Documentation

- [User guide](docs/user-guide.md): using the player, the library, file locations, troubleshooting.
- [Server](docs/server.md): Docker, systemd, remote access, accounts, backups, options.
- [Audio](docs/audio.md): output modes and what's untested.
- [Security](SECURITY.md): what's protected, what isn't, how to report a problem.
- For contributors: [building](docs/building.md), [development](docs/development.md),
  [contributing](CONTRIBUTING.md), [HTTP API](docs/api.md).

## Credits

Playback: [media_kit](https://github.com/media-kit/media-kit) (libmpv and FFmpeg). System media controls:
[audio_service](https://pub.dev/packages/audio_service).

## License

Copyright (C) 2026 wirekurosastak. [GNU AGPL v3](LICENSE) with the additional terms in [NOTICE.md](NOTICE.md).
A modified version must keep the same license, publish its source (also to network users), keep Wiretune's copyright
notices, say it's based on Wiretune, and use a different name.
