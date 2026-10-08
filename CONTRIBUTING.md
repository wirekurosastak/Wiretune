# Contributing

Thanks for helping out. Building is in [docs/building.md](docs/building.md), testing in
[docs/development.md](docs/development.md), the design in [docs/architecture.md](docs/architecture.md). This page is
what a change has to look like.

## The rules

- **Keep it simple.** Concrete classes over one-implementation interfaces; no new layer, helper or package until two
  callers need it. Deleting code is a perfectly good contribution.
- **Fix the root cause, with a test that fails without the fix**: server behaviour against the real server
  (`ServerFixture` in `server/test/support.dart`), logic in unit tests, what people see in a widget test
  (`app/test/app_shell_test.dart`). A test that needs `ffmpeg` or another tool skips itself without it (`hasTool`).
- **Errors someone can act on.** Log with `WiretuneLog`, show a message the user can do something with, and never
  swallow an exception.
- **Child processes** get an argument list, never a shell string, have a timeout or a way to stop, and are killed when
  they're done.
- **Isolates** get plain data: give `Isolate.run` a top-level or static function, never a closure.
- **Trust boundaries.** Validate whatever comes from the network, from tags and from paths. `?token=` stays on the
  media routes and only carries a stream token; no token goes into a log, and no server path goes to a client. A
  person's data lives on the server under their account, and its routes take the account from the token.
- **Player and server change together.** The HTTP API ([api.md](docs/api.md)) is their contract: change both sides in
  one pull request. A change to the tables raises `DatabaseManager.schemaVersion` and adds the step that upgrades the
  previous version in place, with a test that opens a database of that version.
- **No text literals in the interface**: every string goes into `strings.dart`, in all three languages
  ([how](docs/development.md#texts-and-languages)).
- **Every screen**: the wide and the phone layout, large fonts, and a TV remote (focus works, nothing is hover-only or
  drag-only). `app_shell_test.dart` renders every section at several sizes; extend it when you add a page.
- **Back navigation** state goes in `MainViewModel.tryNavigateBack()`, where it's unit-tested. Anything that needs a
  platform API (the media session, Android Auto, the native shells) has to be tried on a device or an emulator.
- **License.** Every Dart, Kotlin and C# file starts with these two lines (CI checks it):

  ```dart
  // Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
  // SPDX-License-Identifier: AGPL-3.0-only
  ```

  What you contribute is licensed the same way ([NOTICE.md](NOTICE.md)); opening a pull request says you have the
  right to contribute it on those terms.
- **Docs tell the truth.** Unverified or known to be missing? Say so, the way
  [audio.md](docs/audio.md#known-limitations) does.

## Pull requests

CI analyses, tests and builds everything but Tizen, but it runs nothing on a device and can't hear a thing. Run the
checks yourself first:

```bash
dart format packages server app/lib app/test tool       # CI fails on anything this would change
dart analyze --fatal-infos tool
(cd packages/wiretune_core && dart analyze --fatal-infos && dart test)
(cd server && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze --fatal-infos && flutter test)
git ls-files '*.dart' '*.kt' '*.cs' | xargs grep -L 'SPDX-License-Identifier: AGPL-3.0-only'   # must print nothing
```

One logical change per pull request. Say what was wrong, why the fix is right, and what you couldn't test (a platform,
a DAC, a TV, a car). Update the docs when behaviour, configuration or the API changes.

Security problems go through [SECURITY.md](SECURITY.md), never a public issue.
