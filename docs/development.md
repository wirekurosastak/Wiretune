# Development

Testing, debugging and extending Wiretune. Building is in [building.md](building.md), the rules a change must follow
in [CONTRIBUTING.md](../CONTRIBUTING.md), and the design in [architecture.md](architecture.md).

## Running it

Flutter 3.47 or newer brings Dart 3.13, which is all the server and the core need; `flutter doctor` tells you what your
platform still wants. On Linux that's libmpv, plus `ffmpeg` for the spectrum and the tag-reader tests.

```bash
# one terminal
cd server && dart run bin/wiretune_server.dart --library /path/to/music

# another
cd app && flutter run -d linux          # or -d windows, -d macos, or a device from `flutter devices`
```

`WIRETUNE_DATA_DIR=/tmp/wt-dev flutter run -d linux` gives you a throw-away player that leaves your real library and
sign-in alone.

## Tests

```bash
(cd packages/wiretune_core && dart test)
(cd server && dart test)        # one file: dart test test/server_hardening_test.dart; by name: --name pattern
(cd app && flutter test)
```

The server tests start a real server per test, on a free port over a generated music folder, and go through sign-in,
per-account data, restarts, the hardening (setup code, stream tokens, rate limits, odd paths and ranges, body limits),
the scan loop and the options. The player's side of the account data runs against that same real server. The core
tests cover the repository on real SQLite, the tag reader on files that `ffmpeg` encodes, track IDs, the library,
deduplication, lyrics, the spectrum and the audio engine (with `FakeAudioDriver`). The app tests cover the view models, back navigation, and every section in both layouts, both
themes and several sizes.

Tests that need `ffmpeg` are *skipped* when it's missing, not passed, so mind the skipped count. Nothing covers the
real drivers, the media session, Android Auto, audio hardware or the native shells.

## What has actually been tried

| | |
|---|---|
| Core, server | The tests, on Linux. The server binary has run against a real folder: scanning, sign-in, gzip, ranges, covers |
| App logic and layouts | View-model and widget tests: every section in both layouts, light and dark, a small phone at 150 % font size, a 1080p TV |
| Linux desktop | Built and run against a real server and library (1,288 tracks), every screen checked at 1280×820, 900×700 and phone width, and playback, the queue, the spectrum, MPRIS and the device list driven through UI automation. Exclusive and bit-perfect not tried on a DAC |
| Android | Debug and release APKs build, with the TV, media service and Android Auto entries in the manifest. **Not yet run on a phone, a TV or in a car** |
| Windows, macOS, iOS | Not yet built (they need their own hosts) |
| Tizen | Dependencies resolve with flutter-tizen. **Not yet built** or run on a TV |
| Bit-perfect, exclusive | Not measured on any platform ([audio.md](audio.md#known-limitations)) |

"Not yet" means exactly that. If you have one of those devices, you can move a row.

## Debugging

- **Logs**: `wiretune.log` in the player's data directory (`~/.config/Wiretune`, `%APPDATA%\Wiretune`,
  `~/Library/Application Support/Wiretune`, or the app's private folder on phones and TVs), `wiretune-server.log` in
  the server's ([server.md](server.md#data-directory)). `WIRETUNE_LOG_LEVEL=debug` adds paths and device names, so use
  it only while you hunt something. Every line passes through `WiretuneLog.redact`, which blanks `token=` values: keep
  it that way when you log a URL.
- **Audio**: mpv's warnings and errors land in the log under `MediaKitDriver`. The device list is mpv's own
  (`mpv --audio-device=help`) plus, on Linux, the ALSA hardware from `aplay -l`.
- **Server**: run it in the foreground; it logs to the console too.
- **Interface**: *Settings → Performance statistics* turns on Flutter's performance overlay.

### UI automation

A local HTTP remote control for scripted UI testing, in debug builds only:

```bash
cd app && flutter build linux --debug
WIRETUNE_UI_AUTOMATION=1 build/linux/x64/debug/bundle/wiretune
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=albums'        # saved to the temp folder
curl 'http://127.0.0.1:5201/api/ui/resize?width=400&height=820'   # down to phone width
```

The rest of the routes (search, playback, sign-in, playlists…) are in `app/lib/src/debug/ui_automation_server.dart`.
Release and profile builds contain none of it, and it only starts when the variable is exactly `1`. It listens on
loopback only and turns away anything that looks like a web page's request, but it has no authentication (`login`
takes the password in the query string, `logout` signs out for real), so keep it to a development machine and a
throw-away `WIRETUNE_DATA_DIR`.

## Platform code

- **Android**: `MainActivity.kt` shares its Flutter engine with the media service; TV detection and the CPU and Wi-Fi
  locks are in `packages/wiretune_platform`. The manifest declares the TV launcher entry and banner, the media service
  that Android Auto browses, and `automotive_app_desc.xml`. The application ID is `com.wiretune.player`.
- **iOS and macOS**: `ios/Runner/Info.plist` (background audio, local network, plain HTTP) and
  `macos/Runner/*.entitlements` (not sandboxed, and the comment there says why).
- **Linux and Windows**: the runners set the window's size and icon; `main.dart` hides the system title bar, and the
  header draws its own window buttons.
- **Tizen**: `tizen/` is the .NET runner. Dart thinks Tizen is Linux, so `App.cs` answers the `wiretune/platform`
  channel to say it's a TV.

## Extending

### An HTTP endpoint

Add the route to the table in `server/lib/src/server.dart` with its access level (never `Access.media` for a new one),
validate every input, and answer errors as `{ "error": "…" }`. Records go into
`packages/wiretune_core/lib/src/models/protocol.dart`. Nothing that lists the library carries a server path, and
per-person data takes the account from the token (`call.principal`), never from the URL or the body. If a player needs
the route, add a method to `server_client.dart` and turn its failures into a session state. Test it next to the other
server tests, the `401` and `403` cases included, and update [api.md](api.md).

### A file type

Add the extension to `AudioFileTypes` in `models/audio_format.dart`, teach `metadata/tag_reader.dart` its tags and
duration, and add it to the list in [server.md](server.md#scanning). Whether it plays is up to libmpv, and on Tizen up
to the TV.

### Texts and languages

All interface text lives in `packages/wiretune_core/lib/src/localization/strings.dart`, one line per key:
`'Key': ('hu', 'en', 'de'),`. Widgets use `context.tr('Key')` and `context.trf('Key', [args])`; everything else
`Localizer.get` and `Localizer.format`. A `_One` variant is picked when the first argument is exactly `1`. Text that's
composed once and kept (status lines, badges) has to be rebuilt in the view model's `_refreshLocalizedTexts()`, or it
won't follow a language change. The tests catch missing translations, mismatched placeholders, and keys that are used
but undefined or defined but unused.

A fourth language is a code change, because each entry is a three-language record: extend the record and fill in every
key, add the constant, a `languages` entry and the case in `Localizer.lookup`, and update the tests.

### A view or a setting

A new section is a new `AppSection` value, a page registered in `pages/section_page.dart`, an entry in the wide
layout's sidebar (and the phone's bottom bar, if it belongs there), a place in `navVisualOrder` (the animated logo's
order), and an accent and gradient in `theme/palette.dart`. A persistent player setting is a key in the `settings`
table, read and written through `LibraryService`. Anything the back button has to respect goes into
`MainViewModel.tryNavigateBack()`.

## CI

`.github/workflows/ci.yml` checks the formatting, analyses all three packages with `--fatal-infos`, runs every test
with `ffmpeg` installed, and builds the server (Linux, Windows, macOS), the APKs, the three desktop players and an
unsigned iOS build, keeping the server executables and the APKs as artifacts. It doesn't build Tizen, runs nothing on a
device, and can't hear a thing, so try those parts by hand.
