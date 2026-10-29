# Contributing

Building: [docs/building.md](docs/building.md). Code layout and tests: [docs/development.md](docs/development.md).

## Pull requests

One logical change per pull request. Say what was wrong, why the fix is right, and what you couldn't test (a platform,
a DAC, a TV, a car). CI analyzes, tests and builds everything except Tizen, but runs nothing on a device
([CI](docs/development.md#ci)). Update the docs when behavior, configuration or the API changes, and mark what's
unverified, as [audio.md](docs/audio.md#bit-perfect) does.

Run the checks before pushing (on Windows, in Git Bash):

```bash
(cd packages/wiretune_core && dart pub get); (cd packages/wiretune_platform && flutter pub get)
(cd server && dart pub get); (cd app && flutter pub get)
dart format packages server app/lib app/test tool       # CI fails on anything this would change
dart analyze --fatal-infos tool
(cd packages/wiretune_core && dart analyze --fatal-infos && dart test)
(cd server && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze --fatal-infos && flutter test)
git ls-files '*.dart' '*.kt' '*.cs' | xargs grep -L 'SPDX-License-Identifier: AGPL-3.0-only'   # must print nothing
```

Report security problems as described in [SECURITY.md](SECURITY.md), never in a public issue.

## Code

- **Keep it simple.** Concrete classes over one-implementation interfaces. No new layer, helper or package until two
  callers need it. Deleting code is a good contribution.
- **Make errors actionable.** Log with `WiretuneLog`, show the user a message they can act on, and never swallow an
  exception silently. Where ignoring one is right (such as a best-effort cleanup), add a comment saying why.
- **Start child processes safely.** Pass an argument list, never a shell string. Give each process a timeout or a way
  to stop it, and kill it when done. Give `Isolate.run` plain data and a top-level or static function, never a closure.
- **Guard the trust boundaries.** Validate everything from the network, tags and paths. `?token=` is only for media
  routes and only carries a stream token. No token in a log, no server path to a client. A person's data lives on the
  server under their account, and its routes take the account from the token.

## Tests and screens

- **Fix the root cause, and add a test that fails without the fix.** Server behavior: against the real server
  (`ServerFixture` in `server/test/support.dart`). Logic: unit tests. What people see: widget tests
  (`app/test/app_shell_test.dart`). A test that needs `ffmpeg` or another tool skips itself when it's missing
  (`hasTool`).
- **Every screen must work** in the wide and phone layouts, with large fonts, and with a TV remote: focus must reach
  everything, and nothing may be hover-only or drag-only. `app_shell_test.dart` renders every section at several
  sizes; extend it for a new page. Back-navigation state goes in `MainViewModel.tryNavigateBack()`, which is
  unit-tested.
- **Try platform code on a device.** The media session, Android Auto and the native shells have no automated tests.

## Changes across the codebase

- **Change player and server together.** The [HTTP API](docs/api.md) is their contract: change both in one pull
  request.
- **Keep existing databases working.** A table change raises `DatabaseManager.schemaVersion`, adds an upgrade step from
  the previous version to `DatabaseManager._upgrades`, and comes with a test that opens a database of that version.
- **Put every interface string in `strings.dart`**, in all three languages
  ([how](docs/development.md#texts-and-languages)).

## License

Every Dart, Kotlin and C# file starts with these two lines (CI checks it):

```dart
// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only
```

Contributions are licensed the same way ([NOTICE.md](NOTICE.md)). By opening a pull request you confirm you have the
right to contribute it on those terms.
