# Wiretune

Self-hosted music streaming for lossless collections. A small ASP.NET Core server indexes a music folder and
streams it over HTTP; Avalonia clients for Linux, Windows and Android play it. The desktop clients can also play a
local folder without any server, and can switch to an exclusive, bit-perfect output path (see
[docs/audio.md](docs/audio.md) for exactly what that means on each platform).

The interface is available in Hungarian, English and German and switches language at runtime. Built on .NET 10.

## What it does

- **Server**: scans a music folder (incrementally, on start-up, on a timer and on request), serves the library
  as JSON, streams files with HTTP range support, and serves cover art and embedded lyrics. Accounts are
  password-protected (bcrypt) and use JWT access tokens. See [docs/server.md](docs/server.md).
- **Client**: browse by artist, album or song; search; play queue with shuffle and repeat; favourites; playlists;
  lyrics from the file's tag; quality badges (codec, bit depth, sample rate); signal-path description;
  32-band spectrum analyser (desktop). See [docs/user-guide.md](docs/user-guide.md).
- **Library sources**: a server, a local folder (desktop only), or both at once. When both are used, tracks that
  exist in both places appear once and the local copy is preferred.
- **Phone layout**: on Android the same view models drive a layout of its own (bottom navigation, mini player,
  full-screen player with queue and lyrics, search page).

Favourites, play counts and playlists are stored by each client in its own database; they are not kept on the
server and are not shared between devices or accounts.

## Platform support

| | Linux desktop | Windows desktop | Android |
|---|---|---|---|
| Playback | `ffplay` / `ffmpeg` + `aplay` child processes | NAudio WASAPI, decoding through Media Foundation | Android `MediaPlayer` |
| Exclusive / bit-perfect output | Yes (ALSA hardware devices) | Implemented (WASAPI exclusive mode); **not yet verified on hardware** | No |
| Spectrum analyser | Yes | Yes | No |
| Local music folder (no server) | Yes | Yes | No |
| Server connection | Yes | Yes | Yes |
| Run the server | Yes | Yes | – |

The server is a plain ASP.NET Core application and runs wherever .NET 10 does. The desktop head is developed on
Linux. The Windows and Android code paths compile with the solution (Android: with its workload) but are not
exercised by the automated tests; the Windows driver in particular has been reviewed, not run on a DAC. Details
and the open points are in [docs/audio.md](docs/audio.md#known-limitations).

Indexed file types: FLAC, WAV, AIFF/AIF, WavPack, APE, DSF (labelled lossless); M4A (AAC, or ALAC when the stream
says so), AAC, MP3, Ogg Vorbis and Opus. Whether a file actually plays depends on the platform's decoder: ffmpeg
on Linux, Media Foundation on Windows (files Windows cannot decode are indexed but fail with an error message),
the system media framework on Android.

## Requirements

- To build: the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). To run a framework-dependent
  build: the .NET 10 runtime.
- Linux desktop playback needs `ffplay` and `ffmpeg` on `PATH` (for example `sudo apt install ffmpeg`).
  Exclusive/bit-perfect output additionally uses `aplay` (ALSA); `wpctl`, `amixer` and `pw-reserve` are used
  when present (PipeWire sink list, volume, card reservation).
- The server needs no external tools.
- Android head: `dotnet workload install android`.

## Quick start

```bash
dotnet build Wiretune.slnx

# 1. Server (listens on http://0.0.0.0:5200)
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/srv/music

# 2. Desktop client
dotnet run --project Wiretune.Desktop
```

In the client, enter the server address on the sign-in screen and press **Connect**. A fresh server has no
accounts: the screen then offers **Create admin account and sign in**, and that first account is the
administrator. There are no default credentials. To use a local folder instead, choose **Continue without a
server (local music)**, then open **Settings**, enter the folder under *Local music folder* and press **Scan**.

The Android project is not part of the solution build; see [docs/development.md](docs/development.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/user-guide.md](docs/user-guide.md) | Using the client: first start, library, playback, playlists, audio settings, phone layout |
| [docs/server.md](docs/server.md) | Running and configuring the server: settings, data files, scanning, accounts, running as a service |
| [docs/api.md](docs/api.md) | HTTP API reference |
| [docs/audio.md](docs/audio.md) | Audio engine, per-platform signal path, exclusive and bit-perfect modes, known limitations |
| [docs/architecture.md](docs/architecture.md) | Projects, data model, library synchronisation, localisation, UI structure |
| [docs/development.md](docs/development.md) | Building, testing, Android notes, debugging, extending Wiretune |
| [SECURITY.md](SECURITY.md) | Reporting vulnerabilities; deployment and security notes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to get a change merged |

## Repository layout

```
Wiretune.Core      Models, SQLite library, metadata scanner, audio engine and drivers, localisation, server session
Wiretune.Server    ASP.NET Core minimal API: JWT auth, library scan, range streaming, cover art, lyrics
Wiretune.UI        Avalonia MVVM user interface (desktop layout and phone layout)
Wiretune.Desktop   Desktop entry point (Linux, Windows)
Wiretune.Android   Android entry point (needs the Android workload; not built with the solution)
Wiretune.Tests     xUnit tests: unit tests, in-memory server integration tests, ffmpeg/ffplay pipeline tests
```

## Security and privacy in short

The server speaks plain HTTP: put it behind a TLS-terminating reverse proxy or reach it over a VPN; do not expose
it to the internet as is. The client looks up artist pictures through Deezer's public API, which sends artist
names from your library to `api.deezer.com`; set `WIRETUNE_NO_ARTIST_PICTURES=1` to turn that off. Nothing else
leaves your network. Details: [SECURITY.md](SECURITY.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). The license is in the [LICENSE](LICENSE) file.
