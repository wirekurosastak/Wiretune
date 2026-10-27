# Contributing

To build Wiretune, see [docs/building.md](docs/building.md); for the code layout and how to run the tests, see
[docs/development.md](docs/development.md).

## Pull requests

Keep each pull request to one logical change, and say what was wrong, why the fix is right, and what you couldn't test,
such as a platform, a DAC, a TV or a car. CI analyzes, tests and builds everything except Tizen, but runs nothing on a
device ([what CI covers](docs/development.md#ci)). Update the docs when behavior, configuration or the API changes, and
say plainly what's unverified, the way [audio.md](docs/audio.md#bit-perfect) does.

Run the checks before you push:

```bash
dart format packages server app/lib app/test tool       # CI fails on anything this would change
dart analyze --fatal-infos tool
(cd packages/wiretune_core && dart analyze --fatal-infos && dart test)
(cd server && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze --fatal-infos && flutter test)
git ls-files '*.dart' '*.kt' '*.cs' | xargs grep -L 'SPDX-License-Identifier: AGPL-3.0-only'   # must print nothing
```

Report security problems through [SECURITY.md](SECURITY.md), never in a public issue.

## Code

- **Keep it simple.** Prefer concrete classes to one-implementation interfaces, and add no new layer, helper or package
  until two callers need it. Deleting code is a perfectly good contribution.
- **Make errors actionable.** Log with `WiretuneLog`, show the user a message they can act on, and never swallow an
  exception silently; where letting one go is right, such as a best-effort cleanup, a comment says why.
- **Start child processes safely.** Pass an argument list, never a shell string, give each process a timeout or a way to
  stop it, and kill it when it's done. Give `Isolate.run` plain data and a top-level or static function, never a
  closure.
- **Guard the trust boundaries.** Validate whatever comes from the network, from tags and from paths. `?token=` stays on
  the media routes and only carries a stream token; no token goes into a log, and no server path goes to a client. A
  person's data lives on the server under their account, and its routes take the account from the token.

## Tests and screens

- **Fix the root cause, and add a test that fails without the fix.** Test server behavior against the real server
  (`ServerFixture` in `server/test/support.dart`), logic in unit tests, and what people see in a widget test
  (`app/test/app_shell_test.dart`). A test that needs `ffmpeg` or another tool skips itself when it's missing
  (`hasTool`).
- **Make every screen work** in the wide and the phone layout, with large fonts, and with a TV remote: focus has to reach
  everything, and nothing may be hover-only or drag-only. `app_shell_test.dart` renders every section at several sizes;
  extend it when you add a page. Back-navigation state goes in `MainViewModel.tryNavigateBack()`, where it's
  unit-tested.
- **Try platform code on a device.** The media session, Android Auto and the native shells have no automated tests, so
  run changes to them on a device or an emulator.

## Changes that span the codebase

- **Change the player and the server together.** The [HTTP API](docs/api.md) is their contract, so change both sides in
  one pull request.
- **Keep existing databases working.** A change to the tables raises `DatabaseManager.schemaVersion`, adds the step that
  upgrades the previous version in place to `DatabaseManager._upgrades`, and comes with a test that opens a database of
  that version.
- **Put every interface string in `strings.dart`**, in all three languages
  ([how](docs/development.md#texts-and-languages)).

## License

Every Dart, Kotlin and C# file starts with these two lines, and CI checks it:

```dart
// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only
```

What you contribute is licensed the same way ([NOTICE.md](NOTICE.md)); opening a pull request says you have the right to
contribute it on those terms.
