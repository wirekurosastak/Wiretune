# Contributing

Thanks for helping out. This file is the short version of how to get a change merged. Building, testing,
debugging and the how-tos for common extensions are in [docs/development.md](docs/development.md).

## Set up

1. Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) (`global.json` pins the minimum).
2. On Linux, install `ffmpeg` (which provides `ffplay`); a few tests run the real audio pipeline against it and
   return early, without testing anything, when it is missing.
3. `dotnet build Wiretune.slnx && dotnet test Wiretune.slnx`

The Android project is not part of the solution build. To work on it, run `dotnet workload install android` and
build `Wiretune.Android` explicitly.

## Layout

`Wiretune.Core` holds everything shared by server and clients (models, SQLite library, scanner, audio engine).
`Wiretune.Server` is the HTTP API, `Wiretune.UI` the Avalonia views and view models, `Wiretune.Desktop` and
`Wiretune.Android` the platform entry points. See [docs/architecture.md](docs/architecture.md) for the design.

## Guidelines

- **Keep it simple.** Concrete classes over interfaces with a single implementation; no new layer or helper
  unless at least two callers need it. Removing code is a fine contribution.
- **Fix root causes** and add a test that fails without the fix. Server behaviour is best covered in
  `ServerIntegrationTests` (in-memory `WebApplicationFactory`), logic in the other test files.
- **Errors must be actionable.** Log with `WiretuneLog` (category, message, exception) and return or surface a
  message the user can act on; do not swallow exceptions silently.
- **Child processes** (`ffmpeg`, `ffplay`, `aplay`, …) are started with `ArgumentList` (never a hand-quoted
  command string), have a timeout or cancellation, and are killed with their process tree on shutdown.
- **Trust boundaries.** Everything from the network, from file tags, and from paths must be validated. Keep
  `?token=` limited to the media endpoints, and never write a token to a log.
- **Do not break the public API** (`Wiretune.Core` public types, HTTP routes and payloads) without a strong
  reason; clients and servers of different versions may meet.
- **User-visible text is never a string literal** in a view or view model: add a `T("Key", "hu", "en", "de")` line to
  `Wiretune.Core/Localization/Strings.cs` and use `{loc:T Key}` in XAML or `Localizer.Get("Key")` in code. Texts that
  are computed once (status lines, badges) must be rebuilt in the view model's `RefreshLocalizedTexts()`. The
  localization tests catch missing translations, mismatched `{0}` placeholders and unused or unknown keys. Adding a
  new *language* is a code change; see [docs/development.md](docs/development.md#add-or-change-texts-and-languages).
- **Phone UI**: state that the back gesture depends on belongs in `MainViewModel.TryNavigateBack()`, where it is
  unit-tested (`PhoneNavigationTests`). Anything that needs Android APIs has to be tried on a device or emulator.
- **Warnings.** A change should build without new warnings. Check with
  `dotnet build Wiretune.slnx -c Release -p:TreatWarningsAsErrors=true` (the repository does not enable that
  setting itself). Match the style in `.editorconfig`.
- **Documentation tells the truth.** If a feature is unverified or has a known gap, say so in the docs (as
  [docs/audio.md](docs/audio.md#known-limitations) does for Windows bit-perfect output) instead of leaving it out
  or overstating it.

## Pull requests

There is no continuous-integration setup: nothing checks a change for you, so run the build and the tests before
sending it.

- One logical change per PR, with a description of the problem and why the fix is the right one.
- `dotnet build Wiretune.slnx -c Release -p:TreatWarningsAsErrors=true` and `dotnet test Wiretune.slnx` pass.
- Mention what you could not test (Windows, Android, real audio hardware).
- Update the README or `docs/` when behaviour, configuration or the API changes.

Security problems: please do not open a public issue, see [SECURITY.md](SECURITY.md).
