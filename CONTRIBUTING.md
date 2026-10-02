# Contributing

Thanks for helping out. Setup, build, test and debugging are in [docs/development.md](docs/development.md); the
design is in [docs/architecture.md](docs/architecture.md). This file is what a change has to look like.

## Guidelines

- **Keep it simple.** Concrete classes over interfaces with a single implementation; no new layer or helper unless at
  least two callers need it. Removing code is a fine contribution.
- **Fix root causes** and add a test that fails without the fix. Server behaviour is best covered in
  `ServerIntegrationTests`, logic in the other test files.
- **Errors must be actionable.** Log with `WiretuneLog` (category, message, exception) and surface a message the user
  can act on; do not swallow exceptions silently.
- **Child processes** (`ffmpeg`, `ffplay`, `aplay`, …) are started with `ArgumentList` (never a hand-quoted command
  string), have a timeout or cancellation, and are killed with their process tree on shutdown.
- **Trust boundaries.** Validate everything that comes from the network, from file tags and from paths. Keep `?token=`
  limited to the media endpoints and never write a token to a log.
- **Do not break the public API** (`Wiretune.Core` public types, HTTP routes and payloads) without a strong reason;
  players and servers of different versions may meet.
- **User-visible text is never a string literal** in a view or view model; add it to `Strings.cs` (see
  [development.md](docs/development.md#add-or-change-texts-and-languages)).
- **Phone UI**: state the back gesture depends on belongs in `MainViewModel.TryNavigateBack()`, where it is
  unit-tested. Anything that needs Android APIs has to be tried on a device or emulator.
- **Docs tell the truth.** If something is unverified or has a known gap, say so (as
  [audio.md](docs/audio.md#known-limitations) does for Windows bit-perfect) instead of leaving it out or overstating
  it.

## Pull requests

There is no CI, so run the checks yourself:

```bash
dotnet build Wiretune.slnx -c Release -p:TreatWarningsAsErrors=true
dotnet test Wiretune.slnx
```

One logical change per PR, with a description of the problem and why the fix is right. Mention what you could not
test (Windows, Android, real audio hardware). Update the README or `docs/` when behaviour, configuration or the API
changes.

Security problems: please do not open a public issue, see [SECURITY.md](SECURITY.md).
