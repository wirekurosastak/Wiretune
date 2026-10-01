# Contributing to Wiretune

Thanks for helping out. This file is the short version of how to get a change merged.

## Set up

1. Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) (`global.json` pins the minimum).
2. On Linux, install `ffmpeg` (which provides `ffplay`); a few tests run the real audio pipeline against it and
   skip themselves when it is missing.
3. `dotnet build Wiretune.slnx && dotnet test Wiretune.slnx`

The Android project is not part of the solution build. To work on it, run `dotnet workload install android` and
build `Wiretune.Android` explicitly.

## Layout

`Wiretune.Core` holds everything shared by server and clients (models, SQLite library, scanner, audio engine).
`Wiretune.Server` is the HTTP API, `Wiretune.UI` the Avalonia views and view models, `Wiretune.Desktop` and
`Wiretune.Android` the platform entry points. See [docs/rendszerTerv.md](docs/rendszerTerv.md) for the design.

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
  `?token=` limited to the media endpoints.
- **Do not break the public API** (`Wiretune.Core` public types, HTTP routes and payloads) without a strong
  reason; clients and servers of different versions may meet.
- **User-visible text is never a string literal** in a view or view model: add a `T("Key", "hu", "en", "de")` line to
  `Wiretune.Core/Localization/Strings.cs` and use `{loc:T Key}` in XAML or `Localizer.Get("Key")` in code. Texts that
  are computed once (status lines, badges) must be rebuilt in the view model's `RefreshLocalizedTexts()`. The
  localization tests catch missing translations, mismatched `{0}` placeholders and unused or unknown keys.
- **Phone UI**: `AndroidMainView` is checked most easily by rendering it with the desktop Avalonia head (it needs no
  Android APIs); state that the back gesture depends on belongs in `MainViewModel.TryNavigateBack()`, where it is
  unit-tested.
- Warnings are treated as errors in CI (`-p:TreatWarningsAsErrors=true`). Match the style in `.editorconfig`.

## Pull requests

- One logical change per PR, with a description of the problem and why the fix is the right one.
- `dotnet build Wiretune.slnx -c Release -p:TreatWarningsAsErrors=true` and `dotnet test Wiretune.slnx` pass.
- Mention what you could not test (Windows, Android, real audio hardware).
- Update the README or `docs/` when behaviour, configuration or the API changes.

Security problems: please do not open a public issue, see [SECURITY.md](SECURITY.md).
