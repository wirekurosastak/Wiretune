# Wiretune

**Your lossless collection, on your own hardware, played properly.**

You have a folder of FLACs. A few hundred albums ripped over the years, maybe a pile of 24/96 downloads. You don't
want a subscription, you don't want to upload anything, and you'd like the player to stay out of the way between the
file and the DAC.

Wiretune is two programs. A **server** you run at home indexes the folder and streams it over your network. A
**player** browses, queues and plays it: one Flutter app for Linux, Windows, macOS, Android (phone, tablet, TV and
Auto), iOS and Samsung's Tizen TVs. On a desktop it can skip the system mixer, open your DAC directly and play
bit-perfect. It also plays a plain folder with no server at all, or both at once.

No cloud, no account on somebody else's computer, no telemetry. The only things that touch the internet are artist
pictures and lyrics for tracks that have none, and you can turn both off ([SECURITY.md](SECURITY.md#players)).

## What you get

- Artists, albums, songs, search, a queue with shuffle and repeat, favourites, playlists, and lyrics beside the queue
  (from the file, or from [LRCLIB](https://lrclib.net) when the file has none).
- A quality tag on every track, **gold** for hi-res, **silver** for CD-quality lossless, **bronze** for lossy, and a
  32-band spectrum analyser on the desktop.
- Favourites, play counts and playlists kept on your server, per account, so they follow you from device to device.
- One decoder everywhere but Tizen (FFmpeg, inside libmpv): FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD, MP3, AAC, Vorbis,
  Opus.
- Lock-screen controls on phones, Android Auto in the car, a remote-friendly TV layout, MPRIS on Linux, and the
  interface in English, Hungarian or German.

## What works where

| | Linux | Windows | macOS | Android | Android TV | Android Auto | iOS | Tizen TV |
|---|---|---|---|---|---|---|---|---|
| Play a server library | Yes | Yes | Yes | Yes | Yes | Browse and play | Yes | Yes |
| Play a local folder | Yes | Yes | Yes | No | No | No | No | No |
| Exclusive / bit-perfect | Yes (ALSA `hw:` devices) | Written, **not tried on a DAC** | Written, **not tried on a DAC** | No | No | No | No | No |
| Spectrum analyser | With `ffmpeg` | With `ffmpeg` | With `ffmpeg` | No | No | No | No | No |
| System media controls | MPRIS | No | Media keys, Now Playing | Notification, lock screen | Remote | The car | Lock screen, Control Center | Remote, in the app |
| Run the server | Yes | Yes | Yes | — | — | — | — | — |

"Supported" isn't the same as "tried on the real thing":
[development.md](docs/development.md#what-has-actually-been-tried) says which platforms have actually run. And
bit-perfect is only as good as the path behind it, so read [audio.md](docs/audio.md) before you lean on the word.

## Quick start

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or newer (it brings Dart); `flutter doctor` tells
you what your platform still needs. On Linux the player also wants libmpv (`sudo dnf install mpv-devel`,
`sudo apt install libmpv-dev`), and `ffmpeg` if you'd like the spectrum.

Start the server in one terminal:

```bash
cd server
dart run bin/wiretune_server.dart --library /srv/music
```

and the player in another:

```bash
cd app
flutter run -d linux        # or -d windows, -d macos, or a phone from `flutter devices`
```

In the player, enter `http://<server-ip>:5200` and press **Connect**. A fresh server asks you to create the first
account, which becomes the administrator, and for the **setup code** the server printed in its log. There are no
default passwords.

Only want to play a folder on this computer? Choose **Continue without a server** and point *Settings* at your music.

## Building

The **server** builds on Linux, Windows or macOS, for the system it's built on:

```bash
cd server
dart build cli -o build
```

That gives you `server/build/bundle/`. Copy the whole folder: the executable loads SQLite from the `lib/` next to it.

The **player** builds from `app/`, and each desktop version only on its own system:

| Target | Build on | Run in `app/` | You get, in `app/build/` |
|---|---|---|---|
| Linux | Linux | `flutter build linux --release` | `linux/x64/release/bundle/` |
| Windows | Windows | `flutter build windows --release` | `windows\x64\runner\Release\` |
| macOS | macOS | `flutter build macos --release` | `macos/Build/Products/Release/Wiretune.app` |
| Android, Android TV, Android Auto | anywhere | `flutter build apk --release --split-per-abi` | `app/outputs/flutter-apk/` |
| iPhone, iPad | macOS, with a signing team set in Xcode | `flutter build ipa --release` | `ios/ipa/` |
| Samsung TV (Tizen) | anywhere, with [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen) | `flutter-tizen build tpk --release` | `tizen/tpk/` |

What to install first, signing, and getting the result onto a phone or a TV: [docs/building.md](docs/building.md).

## Documentation

- [User guide](docs/user-guide.md): the things the player doesn't say out loud.
- [Server](docs/server.md): configuration, accounts, backups, systemd, and putting it behind a proxy.
- [Audio](docs/audio.md): what each output mode really does, and what isn't verified.
- [Building](docs/building.md), [Development](docs/development.md) and [Architecture](docs/architecture.md): for
  building it, changing it and understanding it.
- [HTTP API](docs/api.md), [Security](SECURITY.md) and [Contributing](CONTRIBUTING.md).

The server speaks plain HTTP. Keep it on your LAN, or put a TLS proxy or a VPN in front of it.

## Credits

Playback is [media_kit](https://github.com/media-kit/media-kit) (libmpv, with FFmpeg underneath); the system media
controls are [audio_service](https://pub.dev/packages/audio_service).

## License

[GNU Affero General Public License v3](LICENSE).
