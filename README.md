# Wiretune

**Your lossless collection, on your own hardware, played properly.**

You have a folder of FLACs. Maybe a few hundred albums ripped over the years, maybe a pile of 24/96 purchases.
You don't want a subscription, you don't want to upload anything, and you'd like the player to get out of the
way between the file and the DAC.

Wiretune is two programs. A **server** that you run at home, which indexes the folder and streams it over your
network. A **player** that browses, queues and plays it. One Flutter app covers Linux, Windows, macOS, Android
(phones, tablets, Android TV and Android Auto), iOS and Samsung's Tizen TVs. On a desktop the player can skip the
system mixer, open your DAC directly and play bit-perfect: no gain, no resampling requested, volume locked at 100 %.
It also runs without any server at all if you just want to play a folder on your own computer, and it can combine
the two.

No cloud, no account on somebody else's server, no telemetry. Your favourites, play counts and playlists live on
your own server, per account. The only things that ever talk to the internet are an artist-picture lookup and a
lyrics lookup for tracks that have none (both on by default; one environment variable each turns them off, and the
lyrics one is also a switch in Settings).

## What you get

- Browse by artist, album or song, search, queue with shuffle and repeat, favourites, playlists, lyrics from the
  file's tags or, when a track has none, from the internet ([LRCLIB](https://lrclib.net)), shown next to the queue.
  For a server library, favourites, play counts and playlists are stored on the server under your
  account, so they follow you to every device.
- Quality tags on every track in three tiers: **gold** for hi-res (`GOLD · FLAC 24bit/96kHz`), **silver** for
  lossless at CD quality (`SILVER · FLAC 16bit/44.1kHz`) and **bronze** for lossy files (`BRONZE · MP3 320kbps`),
  and a 32-band spectrum analyser.
- A server library and a local folder at the same time. Tracks that exist in both show up once, and the local copy
  wins.
- One decoder everywhere (FFmpeg, inside libmpv): FLAC, ALAC, WAV, AIFF, APE, WavPack, DSD, MP3, AAC, Vorbis and
  Opus play the same on every platform except Tizen.
- The phone's media notification, lock screen and Bluetooth buttons; browsing and playing from the car's screen with
  Android Auto; a TV layout steered with the remote on Android TV and Tizen; MPRIS on Linux.
- A server that is one `dart run` away: incremental scanning, password-protected accounts, per-account
  favourites and playlists, range streaming, cover art.
- Hungarian, English and German, switchable at runtime.

## What works where

| | Linux | Windows | macOS | Android | Android TV | Android Auto | iOS | Tizen TV |
|---|---|---|---|---|---|---|---|---|
| Play a server library | Yes | Yes | Yes | Yes | Yes | Yes (browse and play) | Yes | Yes |
| Play a local folder, no server | Yes | Yes | Yes | No | No | No | No | No |
| Exclusive / bit-perfect output | Yes (ALSA hardware devices) | Written, **not yet tried on a DAC** | Written, **not yet tried on a DAC** | No | No | No | No | No |
| Spectrum analyser | Yes, with `ffmpeg` | Yes, with `ffmpeg` | Yes, with `ffmpeg` | No | No | No | No | No |
| System media controls | MPRIS | No | Media keys, Now Playing | Notification, lock screen | Remote | The car | Lock screen, Control Center | Remote keys in the app |
| Run the server | Yes | Yes | Yes | n/a | n/a | n/a | n/a | n/a |

Bit-perfect is only as good as the path behind it, and the details matter. Read
[docs/audio.md](docs/audio.md) before relying on the word. How far each platform has been tried is in
[docs/development.md](docs/development.md#what-has-been-verified).

## Quick start

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or newer (it brings Dart). On Linux the player
also needs libmpv (`sudo apt install libmpv-dev` or `sudo dnf install mpv-devel`) and, for the spectrum,
`ffmpeg`.

```bash
cd server && dart pub get && dart run bin/wiretune_server.dart --Wiretune:LibraryPath=/srv/music   # the server, port 5200
cd app && flutter run -d linux                                                                    # the player (or -d windows, -d macos, a phone...)
```

In the player, type the server's address (`http://server-ip:5200`) and press **Connect**. A fresh server asks you
to create the first account, and that account is the administrator. There are no default passwords, and creating the
account needs the **setup code** the server prints in its log when it starts. To skip the server and play a local
folder, choose **Continue without a server** and point *Settings* at the folder.

## Building

```bash
cd server && dart build cli -o build                # the server: server/build/bundle/
cd app && flutter build linux --release             # Linux:   app/build/linux/x64/release/bundle/
cd app && flutter build windows --release           # Windows: app\build\windows\x64\runner\Release\
cd app && flutter build macos --release             # macOS:   app/build/macos/Build/Products/Release/Wiretune.app
cd app && flutter build apk --release --split-per-abi   # Android, Android TV, Android Auto: app/build/app/outputs/flutter-apk/
cd app && flutter build ipa --release               # iPhone, iPad: app/build/ios/ipa/
cd app && flutter-tizen build tpk --release         # Samsung TVs: app/build/tizen/tpk/
```

Each desktop player is built on its own operating system. What each platform needs installed first, signing, and how
to install the result on a phone or a TV: [docs/building.md](docs/building.md).

### Coming from the C# version

The server and the player keep the C# version's database (schema 4), HTTP API, token format and track IDs, so they
pick up where it left off: point the new server at the old data directory, and the new player finds the old one's
library, sign-in and settings by itself. Tokens the old server issued stay valid. The Android app keeps the
application ID `com.wiretune.player` and installs over the old one as an update, as long as both are signed with the
same key ([building.md](docs/building.md#android-player-phones-tablets-android-tv-android-auto)).

## Documentation

| | |
|---|---|
| [docs/user-guide.md](docs/user-guide.md) | Using the player: library rules, playback, settings, TV and car, troubleshooting |
| [docs/server.md](docs/server.md) | Running the server: configuration, accounts, scanning, running as a service |
| [docs/audio.md](docs/audio.md) | What each output mode really does, per platform, and what is not verified |
| [docs/api.md](docs/api.md) | HTTP API reference |
| [docs/architecture.md](docs/architecture.md) | How the code is organised |
| [docs/building.md](docs/building.md) | Building the server and the player for every platform, step by step |
| [docs/development.md](docs/development.md) | Testing, debugging, extending |
| [SECURITY.md](SECURITY.md) | Reporting problems, and what to know before putting the server on a network |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Getting a change merged |

The server speaks plain HTTP, so keep it on your LAN or behind a reverse proxy or VPN. [SECURITY.md](SECURITY.md)
has the details.

## Credits

The look of the spectrum visualizer is inspired by the visualizer in [FxSound](https://github.com/fxsound2/fxsound-app).
Playback is [media_kit](https://github.com/media-kit/media-kit) (libmpv); the media session is
[audio_service](https://pub.dev/packages/audio_service).

## License

See the [LICENSE](LICENSE) file.
