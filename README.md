# Wiretune

**Your lossless collection, on your own hardware, played properly.**

You have a folder of FLACs. Maybe a few hundred albums ripped over the years, maybe a pile of 24/96 purchases.
You don't want a subscription, you don't want to upload anything, and you'd like the player to get out of the
way between the file and the DAC.

Wiretune is two small programs. A **server** that you run at home, which indexes the folder and streams it over
your network. A **player** for Linux, Windows and Android that browses, queues and plays it. On a Linux desktop
the player can skip the system mixer, open your DAC directly over ALSA and play bit-perfect: no gain, no
resampling requested, volume locked at 100 %. It also runs without any server at all if you just want to play a
folder on your own machine, and it can combine the two.

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
- A server that is one `dotnet run` away: incremental scanning, password-protected accounts, per-account
  favourites and playlists, range streaming, cover art.
- Hungarian, English and German, switchable at runtime.

## What works where

| | Linux | Windows | Android |
|---|---|---|---|
| Play a server library | Yes | Yes | Yes |
| Play a local folder, no server | Yes | Yes | No |
| Exclusive / bit-perfect output | Yes (ALSA hardware devices) | Written, **not yet tried on a DAC** | No |
| Spectrum analyser | Yes | Yes | No |
| Run the server | Yes | Yes | n/a |

Bit-perfect is only as good as the path behind it, and the details matter. Read
[docs/audio.md](docs/audio.md) before relying on the word.

## Quick start

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). On Linux the player also needs
`ffmpeg` (`sudo apt install ffmpeg`), and `aplay` for exclusive mode.

```bash
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/srv/music   # the server, port 5200
dotnet run --project Wiretune.Desktop                                        # the player
```

In the player, type the server's address (`http://server-ip:5200`) and press **Connect**. A fresh server asks you
to create the first account, and that account is the administrator. There are no default passwords, and creating the
account needs the **setup code** the server prints in its log when it starts. To skip the server and play a local
folder, choose **Continue without a server** and point *Settings* at the folder.

The Android app is built separately; see [docs/development.md](docs/development.md#android).

## Documentation

| | |
|---|---|
| [docs/user-guide.md](docs/user-guide.md) | Using the player: library rules, playback, settings, troubleshooting |
| [docs/server.md](docs/server.md) | Running the server: configuration, accounts, scanning, running as a service |
| [docs/audio.md](docs/audio.md) | What each output mode really does, per platform, and what is not verified |
| [docs/api.md](docs/api.md) | HTTP API reference |
| [docs/architecture.md](docs/architecture.md) | How the code is organised |
| [docs/development.md](docs/development.md) | Building, testing, debugging, extending |
| [SECURITY.md](SECURITY.md) | Reporting problems, and what to know before putting the server on a network |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Getting a change merged |

The server speaks plain HTTP, so keep it on your LAN or behind a reverse proxy or VPN. [SECURITY.md](SECURITY.md)
has the details.

## Credits

The look of the spectrum visualizer is inspired by the visualizer in [FxSound](https://github.com/fxsound2/fxsound-app).

## License

See the [LICENSE](LICENSE) file.
