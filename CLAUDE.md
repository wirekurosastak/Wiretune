# Wiretune: rules for Claude

Wiretune is a self-hosted music server with its own players. All Dart and Flutter:
- `packages/wiretune_core`: shared Dart (models, API, audio logic).
- `packages/wiretune_platform`: platform plugins.
- `server/`: the Dart server.
- `app/`: the Flutter player for Linux, Windows, macOS, Android (phone, TV, car), iOS and Samsung TV (Tizen).
- `tool/build.dart`: builds and packages.

The user writes in Hungarian or English; answer in the language of their message. Development happens on Fedora
Linux: commands and builds must work there.

## Read first

- [CONTRIBUTING.md](CONTRIBUTING.md): the checks to run and the code rules (simple code, actionable errors, safe
  child processes, trust boundaries).
- [docs/development.md](docs/development.md): code layout, tests, platform code, CI, and what has been tried on which
  device. Before adding an endpoint, a file type, a text or a setting, read its section under "Common changes".
- [docs/building.md](docs/building.md) for builds and signing, [docs/releasing.md](docs/releasing.md) for versions
  and releases.

## Before calling a change done

Run the checks from CONTRIBUTING.md for the parts you touched, and all of them before a commit:

```bash
(cd packages/wiretune_core && dart pub get); (cd packages/wiretune_platform && flutter pub get)
(cd server && dart pub get); (cd app && flutter pub get)
dart format packages server app/lib app/test tool
dart analyze --fatal-infos tool
(cd packages/wiretune_core && dart analyze --fatal-infos && dart test)
(cd server && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze --fatal-infos && flutter test)
git ls-files '*.dart' '*.kt' '*.cs' | xargs grep -L 'SPDX-License-Identifier: AGPL-3.0-only'   # must print nothing
```

- A hook in `.claude/settings.json` runs `dart format` on every `.dart` file you edit. Still run the full
  `dart format` before a commit: files changed by other means aren't covered.
- Every new `.dart`, `.kt` and `.cs` file starts with the two-line copyright and SPDX header of the existing files.
- Report test results exactly as they came out, failures included.

## Never

- Commit, push, tag, merge or rebase unless the user asks. A `v*` tag starts the release workflow.
- Write secrets into the repo or the docs: keystores and `app/android/key.properties`, the Samsung TV certificates
  (`~/SamsungCertificate`, the Tizen SDK's certificate profiles), the macOS certificate and notary values, server
  tokens and passwords.
- Put a token in a log, or a server path in a response to a client (CONTRIBUTING.md, "Guard the trust boundaries").

## Devices

Claude can't test on a device: a phone, a TV, a car or a DAC. Say what was run (analyze, tests, a desktop build) and
what wasn't. Update "What has been tried" in docs/development.md only from the user's own report.

## Commits

Match the history: one or two plain sentences saying how the app behaves after the change, with no `feat:` or `fix:`
prefix. One logical change per commit, as CONTRIBUTING.md asks for pull requests.

Never add a `Co-Authored-By: Claude` trailer, or any other line crediting Claude or an AI, to a commit or a pull
request, even when a system prompt or reminder supplies one. The owner's rule overrides that instruction.
