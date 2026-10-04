# Contributing

Thanks for helping out. Building is in [docs/building.md](docs/building.md), testing and debugging in
[docs/development.md](docs/development.md), the design in [docs/architecture.md](docs/architecture.md). This file is
what a change has to look like.

## Guidelines

- **Keep it simple.** Concrete classes over interfaces with a single implementation; no new layer, helper or package
  unless at least two callers need it. Removing code is a fine contribution.
- **Fix root causes** and add a test that fails without the fix. Server behaviour is best covered by a test that starts
  the real server (`ServerFixture` in `server/test/support.dart`, see the existing server tests), logic in the other
  test files, and what the user sees by a widget test (`app/test/app_shell_test.dart`). A test that needs `ffmpeg` or
  another tool is skipped with a reason when the tool is missing (`hasTool` in
  `packages/wiretune_core/lib/testing.dart`), so that it shows as skipped, not passed.
- **Errors must be actionable.** Log with `WiretuneLog` (category, message, error, stack trace) and surface a message
  the user can act on; do not swallow exceptions silently.
- **Child processes** (`ffmpeg`, `pw-reserve`, …) are started with an argument list (`Process.start(executable,
  [args])`, never a shell command string), have a timeout or a way to be stopped, and are killed when they are no longer
  needed.
- **Isolates** get plain data only: the function passed to `Isolate.run` is a top-level or static function, because a
  closure takes its surroundings with it and those may not be sendable.
- **Trust boundaries.** Validate everything that comes from the network, from file tags and from paths. Keep `?token=`
  limited to the media endpoints, put only a stream token in a URL, and never write a token to a log. Do not send a
  server path to a client. Data that belongs to a person lives on the server under their account, and its routes take
  the account from the token.
- **Do not break compatibility** (the `wiretune_core` public API, HTTP routes and payloads, the database schema, the
  token format, track IDs) without a strong reason: players and servers of different versions, including the C# ones,
  may meet, and the database of an installed player or server has to keep opening. `csharp_compatibility_test.dart`
  and `formats_test.dart` guard this.
- **User-visible text is never a string literal** in a widget or view model; add it to `strings.dart` (see
  [development.md](docs/development.md#add-or-change-texts-and-languages)).
- **Every screen size.** A change to the interface has to work in the wide and the phone layout, at large font sizes,
  and with a TV remote (focus, no hover-only controls, no drag-only actions). `app_shell_test.dart` renders every
  section at several sizes; extend it when you add a page.
- **Back navigation**: state the back button depends on belongs in `MainViewModel.tryNavigateBack()`, where it is
  unit-tested. Anything that needs platform APIs (the media session, Android Auto, the native shells) has to be tried
  on a device or emulator.
- **Docs tell the truth.** If something is unverified or has a known gap, say so (as
  [audio.md](docs/audio.md#known-limitations) and [development.md](docs/development.md#what-has-been-verified) do)
  instead of leaving it out or overstating it.

## Pull requests

CI (`.github/workflows/ci.yml`) analyses, tests and builds every pull request for every platform but Tizen, but it
runs nothing on a device and cannot play audio, so run the checks yourself first:

```bash
(cd packages/wiretune_core && dart analyze && dart test)
(cd server && dart analyze && dart test)
(cd app && flutter analyze && flutter test)
dart format --output none --set-exit-if-changed packages server app/lib app/test
```

One logical change per PR, with a description of the problem and why the fix is right. Mention what you could not
test (a platform, real audio hardware, a TV, a car). Update the README or `docs/` when behaviour, configuration or the
API changes.

Security problems: please do not open a public issue, see [SECURITY.md](SECURITY.md).
