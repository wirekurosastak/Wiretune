# Development

How to build, test, debug and extend Wiretune. For how the pieces fit together, read
[architecture.md](architecture.md) first; for the rules a change has to follow, see
[../CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

- The [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). `global.json` pins SDK `10.0.100` and
  allows newer feature bands (`rollForward: latestFeature`).
- Linux: `ffmpeg` (which provides `ffplay`) for playback and for a few tests. For exclusive/bit-perfect output
  also `aplay` (ALSA utilities); `wpctl`, `amixer` and `pw-reserve` are used when present. See
  [audio.md](audio.md#linux).
- Android only: the Android workload (see [Android](#android)).

## Build and run

```bash
dotnet build Wiretune.slnx                 # Core, UI, Desktop, Server, Tests (not Android)
dotnet test Wiretune.slnx                  # all tests
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/path/to/music
dotnet run --project Wiretune.Desktop
```

`Wiretune.slnx` lists the Android project but marks it *not built* with the solution, because it needs a workload
that most contributors do not have installed.

`Directory.Build.props` sets product metadata and deterministic builds, and keeps NuGet vulnerability advisories
(`NU1901`–`NU1904`) from becoming errors when warnings are treated as errors. The repository does not enable
`TreatWarningsAsErrors` by itself; to check that a change is warning-free, build with
`dotnet build Wiretune.slnx -c Release -p:TreatWarningsAsErrors=true`. Style rules are in `.editorconfig`.

There is no continuous-integration setup in the repository: nothing builds or tests a change automatically, so run
the build and the tests yourself before sending it.

## Projects

| Project | Target | Role |
|---|---|---|
| `Wiretune.Core` | `net10.0` | Models, SQLite persistence, metadata scanner, library service, audio engine and drivers, localisation, server session and client. Shared by everything else. |
| `Wiretune.Server` | `net10.0` (ASP.NET Core) | The HTTP API, accounts, the library scan service. |
| `Wiretune.UI` | `net10.0` | Avalonia views, view models, controls, styles, converters. Used by both heads. |
| `Wiretune.Desktop` | `net10.0`, `WinExe` | Desktop entry point (Linux and Windows). |
| `Wiretune.Android` | `net10.0-android`, API 21+ | Android entry point, audio driver and foreground service. |
| `Wiretune.Tests` | `net10.0` (xUnit) | Tests for Core, Server and the view models. It references Core, UI and Server. |

`Wiretune.Core` makes its internals visible to `Wiretune.Tests`, which is how tests reach types such as the
localisation dictionary.

## Android

```bash
dotnet workload install android      # once
dotnet build Wiretune.Android        # Debug build
dotnet build Wiretune.Android -t:Run # build, install and start on a connected device or emulator
```

The Android app is a single-activity Avalonia application. Configuration worth knowing, all in
`Wiretune.Android.csproj`:

- `SupportedOSPlatformVersion` is 21 (Android 5.0), `ApplicationId` is `com.wiretune.player`.
- **Release builds** (`-c Release`) turn on IL trimming (`TrimMode=partial`), full ahead-of-time compilation
  (profiled AOT is off on purpose, so layout and drawing code is not JIT-compiled on the phone) and the R8
  shrinker. Expect a long build and a larger APK than a Debug build.
- `environment.txt` is passed to the Mono runtime and sets `MONO_GC_PARAMS=nursery-size=32m`; a bigger garbage
  collector nursery means fewer collection pauses while a list scrolls. The comment in the csproj explains the
  reasoning and the knob for very small devices.

The repository contains no signing configuration. Signing and distribution follow the normal .NET for Android
process.

The Android project is not covered by the automated tests: the driver, the service and the activity need a device
or emulator. The phone layout's navigation state lives in `MainViewModel` and is unit-tested (see
`PhoneNavigationTests`); anything that depends on the Android APIs has to be tried by hand.

## Tests

```bash
dotnet test Wiretune.slnx
dotnet test Wiretune.Tests --filter "FullyQualifiedName~ServerIntegration"   # a subset
```

| File(s) | What it covers |
|---|---|
| `ServerIntegrationTests` | The real server, hosted in memory with `WebApplicationFactory<Program>` against a generated music folder: setup, login, roles, rate limit, streaming, covers, library-path changes. One server instance per test. |
| `ExtendedIntegrationAndEdgeTests` | The scanner ignoring non-audio files and walking subfolders, `WiretuneLog` level filtering and concurrent logging, queue operations of the player view model (shuffle, previous, move, remove, clear). |
| `LibraryServiceTests` | Indexing into albums and artists (including multi-artist folders and the mixed-quality badge), playlists, and some navigation and engine-mode checks. The file also defines the in-memory `MockRepository` that most other test files share. |
| `HappyPathTests`, `NegativeTests`, `BoundaryValueTests`, `LogicAndSecurityTests` | Scenario suites with numbered cases (`HP-`, `NEG-`, `BVT-`, `SEC-`): normal use, invalid input, limits, and logic or security problems in the library, validation and view models. |
| `RefactorRegressionTests` | Regression tests for bugs fixed during a full-stack review. |
| `ClientResilienceTests` | The client against scripted, misbehaving server responses: every failure must end as a session state, not an exception. |
| `HybridLibraryTests`, `DeduplicationTests` | Merging server and local tracks and the duplicate detection rules. |
| `AudioEngineTests` | The engine's mode switches, volume lock and device selection, using `FakeAudioDriver` from `TestSupport`. |
| `FfmpegPipelineTests` | The real `ffmpeg`/`ffplay` child-process paths against generated WAV files, with SDL's `dummy` audio driver so nothing is played. Each test **returns early (and so passes) when `ffmpeg` or `ffplay` is not installed.** |
| `WasapiWaveProviderTests` | The byte arithmetic of the Windows driver's software-volume and spectrum wave provider. The driver itself needs Windows and is not tested. |
| `FxSoundSpectrumEngineTests`, `NavVisualizerTests` | The 32-band spectrum analyser, and the sidebar's navigation visualiser (the direction of its wave when you navigate). |
| `LyricsAndQueueTests` | Reading lyrics (scanner, server, client, player) and what happens when the playing track is removed from the queue. |
| `PhoneNavigationTests` | The back gesture and the search page and full-screen player of the phone layout. |
| `TrackListInteractionTests` | The click-to-play commands of the songs, album and artist views and a few small UI properties. |
| `LocalizationTests` | The localisation dictionary (see [Localisation](#add-or-change-texts-and-languages)). |
| `ArtistPictureServiceTests` | The Deezer lookup and its cache, with a replaceable HTTP handler so no test touches the network. |
| `TestSupport` | Shared helpers: `FakeAudioDriver`, a capable test device, an engine factory. |

Tests build their fixtures in temporary directories and use an in-memory repository or a fake audio driver where
they can. The number of tests is not listed here because it changes; `dotnet test` prints it.

What the tests do **not** cover: the Windows WASAPI driver, the Android driver and service, real audio hardware
(the Linux ALSA path is exercised with a dummy device, not measured), and the Avalonia visuals.

## Debugging

- **Logs.** Everything is logged through `WiretuneLog` (category, level, message, exception) to a file in the
  data directory: `wiretune.log` for clients, `wiretune-server.log` for the server (see
  [server.md](server.md#data-directory) and the table below). At 10 MiB the file is moved to `.1`. The minimum
  level defaults to `Debug`.
- **Where the data lives.** Client: `wiretune.db`, `Covers/`, `artist_pictures.json`, `wiretune.log` in the
  application-data folder (Linux `~/.config/Wiretune`, Windows `%APPDATA%\Wiretune`; Android: the app's private
  files folder). Server: the same files with the server's names, in the `Server` subfolder.
  `WIRETUNE_DATA_DIR` moves the root; use it to run a throw-away instance next to your real one:

  ```bash
  WIRETUNE_DATA_DIR=/tmp/wt-dev dotnet run --project Wiretune.Desktop
  ```

- **Audio problems on Linux.** The log line *Starting ffplay …* or *Starting direct ALSA (ffmpeg | aplay) …* shows
  the exact source and device (token values are replaced by `***`). The same commands can be run by hand; the
  argument lists are in [audio.md](audio.md#linux).
- **Server problems.** Run it in the foreground with `dotnet run --project Wiretune.Server`: ASP.NET Core's own
  console logging is on in addition to `wiretune-server.log`. Use a separate `Wiretune:DataDirectory` (or
  `WIRETUNE_DATA_DIR`) for experiments.

### UI automation endpoint (desktop, development only)

For scripted UI checks the desktop client can open a small HTTP endpoint on loopback. It is off unless the
environment variable is exactly `1`:

```bash
WIRETUNE_UI_AUTOMATION=1 dotnet run --project Wiretune.Desktop
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=home'
```

All routes are `GET`. They are `state`, `navigate?index=` (0 Tracks, 1 Albums, 2 Artists, 3 Playlists,
4 Favorites, 5 Settings), `screenshot?name=`, `resize?width=&height=`, `search?q=`, `play-track?id=` or
`?title=`, `connect?url=`, `login?user=&password=`, `logout`, `continue-offline`, `playlist/new?name=`,
`playlist/create`, `playlist/add-current`, `playlist/add-to?name=`, `play-pause`, `next`, `prev`,
`seek?seconds=`, `volume?level=`, `toggle-favorite?trackid=`, `open-album?title=` and `open-artist?name=`, all
under `/api/ui/`.

Safeguards: it binds to `127.0.0.1:5201` only, sends no CORS headers, rejects requests that carry an `Origin`
or a cross-site `Sec-Fetch-Site` header, and rejects any `Host` other than `127.0.0.1:5201` or `localhost:5201`.
It is still an unauthenticated remote control for the player and `login` takes the password as a query
parameter, so use it on a development machine only and never in a deployment. It does not exist on Android.

## Extending Wiretune

### Add an HTTP endpoint

1. Add the route in `Wiretune.Server/Program.cs`. Routes mapped on the `api` group there require an authenticated
   user; add `.RequireAuthorization("admin")` for administrator-only routes. Validate every input (see
   [CONTRIBUTING.md](../CONTRIBUTING.md#guidelines)) and answer errors as `{ "error": "…" }`.
2. Put new request or response records next to the existing ones in `Wiretune.Core/Models/UserInfo.cs` so the
   client can share them.
3. If a client needs it, add a method to `Wiretune.Core/Services/ServerStreamingClient.cs`, and make sure a
   failure becomes a session state rather than an exception.
4. Add a test to `ServerIntegrationTests` (including the 401/403 cases) and update [api.md](api.md).

Do not accept `?token=` anywhere except the media routes; the check lives in the JWT setup in `Program.cs`.

### Add a file type

`Wiretune.Core/Models/AudioFileTypes.cs` is the single table of indexed extensions: codec label, lossless flag
and the MIME type the server streams with. Add the extension there. Then make sure each platform can decode it,
which Wiretune cannot do for you (ffmpeg on Linux; Media Foundation on Windows; the platform framework on
Android; see [audio.md](audio.md)), and update the list in the [README](../README.md#platform-support).

### Add or change texts and languages

All user-visible text lives in `Wiretune.Core/Localization/Strings.cs`, one line per key:
`T("Key", "hu", "en", "de");`. Use `{loc:T Key}` (or `{loc:TFormat Key}` for texts with `{0}` placeholders) in
XAML and `Localizer.Get("Key")` / `Localizer.Format("Key", args)` in code. A key with a `_One` suffix is used
instead when the first format argument is exactly `1`. Texts that are composed once and kept (status lines,
badges) have to be rebuilt in the view model's `RefreshLocalizedTexts()` so they follow a language change.

`LocalizationTests` fail when a text is empty or untidy, placeholders differ between languages, a key used in
code or XAML does not exist, a key is unused, a `_One` key has no base key, or German or Hungarian texts are
mostly identical to the English ones.

The dictionary is a three-language tuple, so **adding a fourth language is a code change, not just more text**:

1. In `Strings.cs`, extend the tuple type and `T(...)` with a fourth text and fill in every key.
2. In `Localizer.cs`, add the language constant, an entry in `Languages`, the cases in `Lookup` and `CultureFor`.
3. Update `LocalizationTests` (the language list and the checks that compare against English).

The interface starts in English; `Localizer.DetectSystemLanguage()` exists but is not called at start-up, so the
operating system's language is not used.

### Add a view or setting

View models live in `Wiretune.UI/ViewModels` (CommunityToolkit.Mvvm), views in `Wiretune.UI/Views` and reusable
parts in `Wiretune.UI/Controls`. The desktop window (`MainWindow`/`MainView`) and the phone layout
(`AndroidMainView`) are separate views over the same `MainViewModel`. A persistent client setting is a key in the
`settings` table, read and written through `LibraryService`/`LibraryRepository` (see
[architecture.md](architecture.md#persistence)). State that the Android back gesture has to respect belongs in
`MainViewModel.TryNavigateBack()`, which `PhoneNavigationTests` cover.
