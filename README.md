# Wiretune

Self-hosted lossless music streaming: a small ASP.NET Core server that indexes your FLAC/WAV/… collection, and
Avalonia clients (Linux, Windows, Android) that play it — with an optional bit-perfect output mode on Linux.
Built on .NET 10. The interface speaks Hungarian, English and German and switches language at runtime.

*Magyar leírás: [README.hu.md](README.hu.md)*

## Components

```
Wiretune.Core      Models, SQLite library, metadata scanner, audio engine and drivers (shared by server and clients)
Wiretune.Server    ASP.NET Core minimal API: JWT auth, library scan, HTTP range streaming, cover art
Wiretune.UI        Avalonia MVVM user interface (desktop and Android)
Wiretune.Desktop   Desktop entry point (Linux, Windows)
Wiretune.Android   Android entry point (needs the Android workload; not part of the solution build)
Wiretune.Tests     xUnit tests (unit tests, in-memory server integration tests, real ffmpeg/ffplay pipeline tests)
```

More detail: [docs/rendszerTerv.md](docs/rendszerTerv.md) (system design) and
[docs/funkSpec.md](docs/funkSpec.md) (functional specification), both in Hungarian.

## Platform support

| | Linux desktop | Windows desktop | Android |
|---|:---:|:---:|:---:|
| Playback engine | `ffplay` child process, ALSA / PipeWire routing | NAudio WASAPI (shared / exclusive) | `MediaPlayer` |
| Bit-perfect / exclusive output | yes | yes | no |
| Spectrum analyser | yes | yes | no |
| Local library (no server) | yes | yes | no |
| Server | yes | yes | – |

On Android the same view models drive a phone layout of its own (bottom navigation, mini player, full-screen
player with queue and lyrics, search page, playlist sheets) instead of the desktop's sidebar layout.

Continuous integration builds and tests on Linux only. The Windows and Android code paths are compiled there
(Android: separately, with the workload) but are not exercised by automated tests.

## Requirements

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) to build; the .NET 10 runtime to run a
  framework-dependent build.
- Linux desktop playback and the spectrum analyser: `ffmpeg` and `ffplay` on `PATH` (`sudo apt install ffmpeg`).
  Bit-perfect mode additionally uses `aplay` (ALSA) and `wpctl` (PipeWire) when present.
- The server needs no external tools.
- Android head: `dotnet workload install android`.

## Build, run, test

```bash
dotnet build Wiretune.slnx
dotnet test  Wiretune.slnx

dotnet run --project Wiretune.Server     # http://0.0.0.0:5200
dotnet run --project Wiretune.Desktop    # desktop client
dotnet build Wiretune.Android            # after installing the Android workload
```

The tests that use ffmpeg/ffplay return early when those tools are not installed. They use SDL's `dummy` audio
driver, so nothing is played.

On first start the client asks whether to connect to a server or use a local music folder. The first account
created on a fresh server (`POST /api/auth/setup`, done by the client's setup screen) becomes the administrator;
there are no default credentials. Further users are added by an administrator.

## Languages and appearance

Hungarian, English and German are built in. On first start the client uses the operating system's language when
it is one of these and English otherwise; the choice can be changed at any time in **Settings** (desktop: also
the language button in the top bar) and applies immediately, without a restart. The language and the light/dark
theme are remembered in the client's database (`Preference.Language`, `Preference.Theme`).

All texts live in `Wiretune.Core/Localization/Strings.cs`. To add a language, add its code to `Localizer.Languages`
and a fourth text to every `T(...)` line; the tests fail while a key lacks a translation, uses different
placeholders in different languages, is unused, or is referenced from code or XAML but missing.

## Server configuration

Settings live in `Wiretune.Server/appsettings.json` under `Wiretune` and can be overridden the usual ASP.NET Core
way, e.g. `--Wiretune:Port=8080` or `Wiretune__Port=8080`.

| Key | Default | Meaning |
|---|---|---|
| `Wiretune:LibraryPath` | `""` | Music folder (absolute, or relative to the application directory). If empty or missing, the user's Music folder is used and a warning is logged. A folder chosen by an administrator through the API is stored in the database and takes precedence after a restart. |
| `Wiretune:DataDirectory` | `""` | Where the database (`wiretune-server.db`), cover cache and log (`wiretune-server.log`) live. Empty: `<user app data>/Wiretune/Server`. |
| `Wiretune:ScanIntervalMinutes` | `30` | Interval of the incremental background rescan; `0` disables it (startup and manual scans still run). |
| `Wiretune:Port` | `5200` | HTTP port. Ignored when `ASPNETCORE_URLS` or `--urls` is set. |

Environment variables:

| Variable | Applies to | Meaning |
|---|---|---|
| `WIRETUNE_DATA_DIR` | server, client | Root of Wiretune's data (the server uses its `Server` subfolder). |
| `WIRETUNE_NO_ARTIST_PICTURES` | client | Set to `1` to disable artist-picture lookups (see Privacy). |
| `WIRETUNE_UI_AUTOMATION` | desktop client | Set to `1` to start a local test-automation HTTP API on `127.0.0.1:5201`. Development only. |

### Running the server as a service

Publish and run it under a dedicated account, for example with systemd:

```bash
dotnet publish Wiretune.Server -c Release -o /opt/wiretune
```

```ini
# /etc/systemd/system/wiretune.service
[Unit]
Description=Wiretune server
After=network-online.target

[Service]
User=wiretune
WorkingDirectory=/opt/wiretune
ExecStart=/usr/bin/dotnet /opt/wiretune/Wiretune.Server.dll
Environment=Wiretune__LibraryPath=/srv/music
Environment=WIRETUNE_DATA_DIR=/var/lib/wiretune
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

For a self-contained build that needs no installed runtime, add
`-r linux-x64 --self-contained -p:PublishSingleFile=true` (use the runtime identifier of the target machine).

### Security notes

- The server speaks plain HTTP. Do not expose it to the internet as is: put it behind a reverse proxy that
  terminates TLS (Caddy, nginx, …) or reach it over a VPN such as WireGuard/Tailscale. Behind a proxy, set
  `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`, otherwise every client shares the proxy's address and the login
  throttling below applies to all of them together.
- Login and setup are limited to 10 attempts per minute per client address. Passwords are hashed with bcrypt
  and limited to 72 bytes (the bcrypt limit).
- Tokens are JWTs valid for up to 90 days; deleting a user invalidates that user's tokens immediately. The
  signing key is generated on first start and stored in the server database, so protect the data directory.
- Players that cannot send headers (`ffplay`, Android `MediaPlayer`) pass the token as `?token=`. The server
  accepts that only on `/api/stream` and `/api/cover`, never on the management endpoints. URLs of those two
  endpoints therefore contain a credential: keep access logs of the reverse proxy private.
- `/api/tracks` returns server-side file paths to every authenticated user.

Please report vulnerabilities as described in [SECURITY.md](SECURITY.md).

### Privacy

The client looks up artist pictures through Deezer's public API, which sends artist names from your library to
`api.deezer.com`. Set `WIRETUNE_NO_ARTIST_PICTURES=1` to turn that off. Nothing else leaves your network.

## HTTP API (summary)

| Route | Auth | Purpose |
|---|---|---|
| `GET /api/auth/setup-required`, `POST /api/auth/setup` | none | First-run administrator creation |
| `POST /api/auth/login` | none | Returns a JWT |
| `POST /api/auth/register`, `GET /api/users`, `DELETE /api/users/{id}`, `GET /api/config`, `POST /api/config/library-path` | admin | User and library-folder management |
| `GET /api/auth/me` | user | Current account |
| `GET /api/tracks?q=`, `/api/albums`, `/api/artists` | user | Library listings and search |
| `GET /api/stream/{trackId}` | user | Audio with HTTP range support |
| `GET /api/cover/{trackId}`, `/api/cover/album/{albumId}` | user | Cover art |
| `GET /api/lyrics/{trackId}` | user | Embedded lyrics tag of a track (plain text, capped; `404` when there is none) |
| `GET /api/library/status`, `POST /api/library/scan` | user | Scan state; request a scan |

## Known limitations

- Android and Windows (WASAPI) code is not covered by automated tests, and real audio hardware cannot be tested
  in CI. The Android head (including the phone layout) is not built by CI at all, because it needs the Android
  workload.
- The bit-perfect path on Linux goes through ALSA's `plughw` device with 32-bit samples; whether the result is
  truly bit-transparent depends on the sound card and driver.
- The `?token=` mechanism and the Android cleartext-HTTP permission mean streaming should only run over a
  network you trust, or behind TLS.
- The desktop client keeps its access token in its local SQLite database, unencrypted. This is deliberate for
  now: a token can be revoked by deleting the user, and a portable secret store that works on Linux, Windows and
  Android is not part of the app yet. The data directory is created private to the user on Unix, but that is all
  the protection there is. Uncheck "Keep me signed in" on the sign-in screen to keep the token out of the database.
- The Windows driver opens the source off the UI thread and the Android player service outlives short pauses
  between tracks, holds audio focus and a partial wake lock. These paths could only be reviewed, not run, in the
  development environment.
- Lyrics come only from the file's own tag (unsynchronised text); there is no lookup service and no synced display.
- Tracks without an artist tag are filed under the artist `Unknown artist`; that name is stored in the library and
  is not translated. No picture lookup is made for it.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). The repository does not contain a license file yet; until the owner adds
one, all rights are reserved.
