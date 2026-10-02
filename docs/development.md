# Development

Building, testing, debugging and extending Wiretune. How the code fits together:
[architecture.md](architecture.md). The rules a change has to follow: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Build and run

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) (`global.json` pins `10.0.100` and
allows newer feature bands). On Linux also `ffmpeg`, and `aplay` for the exclusive modes
([audio.md](audio.md#linux)).

```bash
dotnet build Wiretune.slnx        # everything except Android
dotnet test Wiretune.slnx
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/path/to/music
dotnet run --project Wiretune.Desktop
```

`Wiretune.slnx` lists the Android project but does not build it with the solution, because it needs a workload.
`Directory.Build.props` sets product metadata and deterministic builds and keeps NuGet advisories (`NU1901`–`NU1904`)
from becoming errors. The repository does not enable `TreatWarningsAsErrors`; to check that a change is
warning-free, add `-c Release -p:TreatWarningsAsErrors=true`. Style rules are in `.editorconfig`.

**Continuous integration.** `.github/workflows/ci.yml` builds `Wiretune.Tests` and `Wiretune.Desktop` in Release,
runs the tests with `ffmpeg` installed, and fails when `dotnet list package --vulnerable` reports a vulnerable
package. It does not build `Wiretune.Android` (it needs the workload): build that by hand before merging a UI change.

## Android

```bash
dotnet workload install android       # once
dotnet build Wiretune.Android         # Debug
dotnet build Wiretune.Android -t:Run  # build, install and start on a connected device or emulator
```

Notes from `Wiretune.Android.csproj`: minimum API 21, application ID `com.wiretune.player`. **Release builds** turn on
IL trimming, full AOT (profiled AOT is off on purpose, so layout and drawing code is not JIT-compiled on the phone)
and the R8 shrinker: expect a long build and a bigger APK. `environment.txt` sets
`MONO_GC_PARAMS=nursery-size=32m` for fewer garbage-collection pauses while lists scroll; the csproj comment explains
why. There is no signing configuration in the repository.

Nothing that needs Android APIs (driver, service, activity) is covered by the automated tests; try it on a device.

## Tests

xUnit, run with `dotnet test Wiretune.Tests` (add `--filter "FullyQualifiedName~Name"` for a subset). They cover:

- the real server hosted in memory (`WiretuneServerFixture`, `WebApplicationFactory<Program>` against a generated
  music folder, one server per test): sign-in and the whole client life cycle (`ServerIntegrationTests`), the
  per-account favourites, plays, playlists, import and survival of a server restart (`ServerUserDataTests`), and the
  hardening (setup code, stream tokens, no paths in the listing; `ServerHardeningTests`). `ServerTestHelpers` holds the shared steps;
- the player's side of the per-account data against that server: queue, flush, hand-over, older servers
  (`SessionUserDataTests`);
- the repository against a real SQLite file, including the upgrade from an older schema (`LibraryRepositoryTests`);
- library, scanner, deduplication, hybrid merging, localisation, view models and the phone's back navigation;
- scenario suites with numbered cases (`HP-`, `NEG-`, `BVT-`, `SEC-`) for normal use, invalid input, limits and
  security (`HappyPathTests`, `NegativeTests`, `BoundaryValueTests`, `LogicAndSecurityTests`); `ReviewFollowUpTests`
  pins the small fixes of the production-readiness review and the documented limits (track IDs, covers, driver commands);
- the audio engine with `FakeAudioDriver` (`TestSupport`), the real `ffmpeg`/`ffplay` child-process paths against
  generated WAV files with SDL's `dummy` driver (`FfmpegPipelineTests`), and the Windows driver's wave provider
  (`WasapiWaveProviderTests`).

A test that needs a command-line tool is marked `[ToolFact("ffmpeg")]`: without the tool it is reported as
**skipped**, never as passed, so check the skipped count of a run, especially on a machine without `ffmpeg`. Name a new
test file after the topic it covers, not after the change that made it. Not covered: the Windows WASAPI driver, the
Android driver and service, real audio hardware, and the Avalonia visuals (the section views are only checked by
building and running the app). Fixtures live in temporary directories. `Wiretune.Core` exposes its internals to
`Wiretune.Tests`.

## Debugging

- **Logs.** `WiretuneLog` writes `[time] [LEVEL] [category] message` lines (Info and up by default) to `wiretune.log`
  in the player's data directory or `wiretune-server.log` in the server's ([server.md](server.md#data-directory)); at
  10 MiB the file moves to `.1`. Debug lines carry paths and device names, so set `WIRETUNE_LOG_LEVEL=Debug` (or
  `Trace`; `Info`, `Warn`, `Error`) only while troubleshooting. Every line passes through `WiretuneLog.Redact`, which
  replaces `token=` values with `***`;
  keep it that way when logging URLs. The player's data directory is `~/.config/Wiretune` on Linux,
  `%APPDATA%\Wiretune` on Windows and the app's private files folder on Android. `WIRETUNE_DATA_DIR` moves it, which
  is handy for a throw-away instance: `WIRETUNE_DATA_DIR=/tmp/wt-dev dotnet run --project Wiretune.Desktop`.
- **Audio on Linux.** The log lines *Starting ffplay …* / *Starting direct ALSA (ffmpeg | aplay) …* show the exact
  source and device; the commands in [audio.md](audio.md#linux) can be run by hand (put your own token in the URL).
- **Server.** Run it in the foreground: ASP.NET Core's console logging is on in addition to the log file.

### UI automation (desktop, development only)

```bash
WIRETUNE_UI_AUTOMATION=1 dotnet run --project Wiretune.Desktop
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=home'
```

The server is compiled into **Debug builds only** (`dotnet run` is one); a Release or published player contains no
such endpoint, whatever the variable says. The variable must be exactly `1`. `section` is one of `Tracks`, `Albums`,
`Artists`, `Playlists`, `Favorites`, `Settings`. The endpoint listens on `127.0.0.1:5201` only and handles `GET` requests under
`/api/ui/` to navigate, search, play, seek, sign in and so on; the routes are listed in
`Wiretune.UI/Services/UiAutomationServer.cs`. It rejects requests with an `Origin` or cross-site `Sec-Fetch-Site`
header and any `Host` other than `127.0.0.1:5201` / `localhost:5201`. It is still an unauthenticated remote
control (`login` takes the password as a query parameter), so use it on a development machine only. See
[SECURITY.md](../SECURITY.md#clients).

## Extending Wiretune

### Add an HTTP endpoint

1. Add the route in `Wiretune.Server/Program.cs`. Routes on the `api` group there require a signed-in user; add
   `.RequireAuthorization("admin")` for admin-only ones. Validate every input and answer errors as
   `{ "error": "…" }`. Never accept `?token=` outside the media routes.
2. Put new request or response records next to the existing ones in `Wiretune.Core/Models/UserInfo.cs` (per-account
   data: `UserData.cs`). Anything that lists library content goes through a `Server*Dto` in
   `Wiretune.Server/ServerDtos.cs` so that no server path leaves the machine. Data that belongs to one person takes the
   account ID from the token (`CurrentUserId`), never from the URL or the body.
3. If a player needs it, add a method to `Wiretune.Core/Services/ServerStreamingClient.cs`; failures must become a
   session state, not an exception.
4. Add a test with the other server tests (including the 401/403 cases; `WiretuneServerFixture` hosts a real server
   and `ServerTestHelpers` signs in) and update [api.md](api.md).

### Add a file type

Add the extension to `Wiretune.Core/Models/AudioFileTypes.cs` (codec label, lossless flag, MIME type) and the list in
[server.md](server.md#library-and-scanning). Wiretune cannot make a platform decode it: check ffmpeg, Media
Foundation and Android's framework ([audio.md](audio.md)).

### Add or change texts and languages

All interface text is in `Wiretune.Core/Localization/Strings.cs`, one line per key: `T("Key", "hu", "en", "de");`.
Use `{loc:T Key}` (`{loc:TFormat Key}` with `{0}` placeholders) in XAML and `Localizer.Get("Key")` /
`Localizer.Format("Key", args)` in code. A key with a `_One` suffix is used when the first format argument is exactly
`1`. Texts composed once and kept (status lines, badges) must be rebuilt in the view model's
`RefreshLocalizedTexts()` so they follow a language change.

`LocalizationTests` fail on empty or untidy texts, placeholders that differ between languages, keys used in code or
XAML that do not exist, unused keys, a `_One` key without a base key, and German or Hungarian texts that are mostly
identical to English.

The dictionary is a three-language tuple, so **a fourth language is a code change**: extend the tuple type and `T(...)`
in `Strings.cs` and fill in every key; add the constant, a `Languages` entry and the cases in `Lookup` and
`CultureFor` in `Localizer.cs`; update `LocalizationTests`.

### Add a view or setting

View models are in `Wiretune.UI/ViewModels`, views in `Wiretune.UI/Views`, reusable parts in `Wiretune.UI/Controls`.
A new desktop section is a new `AppSection` value, a `UserControl` in `Views/` that takes the `MainViewModel` as its
`DataContext`, and an entry in `MainView.axaml` and in `MainViewModel.GetNavVisualOrder` (the order of the animated
logo). Its colours are two entries (accent family and window gradient) in the theme dictionaries of
`App.axaml`. A persistent player setting is a key in the `settings` table, read and written through
`LibraryService`/`LibraryRepository`. State that the Android back gesture has to respect belongs in
`MainViewModel.TryNavigateBack()`, which `PhoneNavigationTests` cover.
