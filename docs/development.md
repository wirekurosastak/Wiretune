# Development

Code layout, tests, and what has actually been tried. Building: [building.md](building.md). Rules for changes:
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Running from source

```bash
cd server && dart run bin/wiretune_server.dart --library /path/to/music      # one terminal
cd app && WIRETUNE_DATA_DIR=/tmp/wt-dev flutter run -d linux                # another; or -d windows, -d macos, a phone
```

`WIRETUNE_DATA_DIR` gives the player a throw-away data folder, so your real library and sign-in stay untouched.

## Where is what

| Where | What |
|---|---|
| `packages/wiretune_core/` | Pure Dart, shared by server and players: models, SQLite (`DatabaseManager`, `LibraryRepository`), tag reader, scanner, `LibraryService`, server client/session, remote control, downloads, audio engine, localization |
| `packages/wiretune_core/lib/testing.dart` | Test doubles shared by all packages' tests |
| `packages/wiretune_platform/` | Android native code as a Flutter plugin |
| `server/lib/src/` | HTTP server (`server.dart` holds the routes table), auth, per-user data, scan loop, remote hub |
| `app/lib/` | The player: `main.dart` (startup), `src/view_models/` (`MainViewModel` plus one per area), `src/layouts/` and `pages/` (wide and phone layouts), `src/widgets/`, `src/audio/` (`MediaKitAudioDriver`, `TizenAudioDriver`, media session) |
| `tool/build.dart` | Release builds of every target |

### Design notes

- The server is a headless player: it runs the same `LibraryService`, scanner and database as the players, with HTTP on
  top.
- The library is an immutable `LibrarySnapshot`, rebuilt and swapped whole after each change.
- Track IDs derive from the file's full path. Albums are keyed by title and album artist (`Track.albumId`). A track's
  tags (`Track.tagged`) never change; how the library files it (`Track.filed`) is recomputed on every rebuild.
- Favorites, play counts, playlists and hidden items are stored by track ID in `LibraryService`, never on a `Track`.
  For server tracks they belong to the account; offline they're read-only.
- `ServerSession` is the player's connection state machine. Connecting, signing in and refreshing never throw.
- Server pushes (`dataChanged`, `libraryChanged`) and remote control share one WebSocket (`/api/remote`).
- `WiretuneAudioEngine` owns playback state and drives one `AudioDriver`.
- View models are `ChangeNotifier`s, handed down via `AppScope` (`context.vm`). Back navigation goes through
  `MainViewModel.tryNavigateBack()`.
- SQLite in WAL mode, one synchronous connection, schema version in `PRAGMA user_version`. Older databases upgrade in
  place; newer ones are refused.

## Tests

```bash
(cd packages/wiretune_core && dart test)
(cd server && dart test)        # one file: dart test test/remote_test.dart; by name: --name pattern
(cd app && flutter test)
```

Server tests start a real server per test over a generated music folder. Core tests use real SQLite and files encoded by
`ffmpeg`. App tests render every section in both layouts, both themes and several sizes.

Tests needing `ffmpeg` (or `dbus-daemon`) are *skipped* without it, not passed, so watch the skipped count. Real
drivers, the media session, Android Auto, audio hardware and native shells have no automated coverage.

## What has actually been tried

| | |
|---|---|
| Core, server | Tests on Linux. Server binary run against a real folder: scanning, sign-in, ranges, covers, live folder changes |
| App logic and layouts | View-model and widget tests: every section in both layouts, light and dark, small phone at 150 % font, 1080p TV |
| Downloads, remote control | Tested against the real server. Remote control also works between real devices |
| Linux desktop | Built and run against a real library (1,320 tracks) at several window sizes; playback, queue, spectrum, MPRIS and device list driven through UI automation. Exclusive and bit-perfect tried on an SMSL SU-1 DAC |
| Android | Built and run on a phone. **Untested on a TV or in a car**, and on downloading into the shared *Music* folder without a permission (Android 11+) |
| Windows | Built and run. Exclusive and bit-perfect tried on an SMSL SU-1 DAC |
| macOS, iOS | Untested, never built (need their own hosts) |
| Tizen | Built on Fedora, tried briefly on a 2024 Samsung TV (Tizen 8.0): signs in, plays, remote reaches everything, but navigation is sluggish and **needs more work** |
| Bit-perfect, exclusive | Tried on Linux and Windows with an SMSL SU-1; not measured on any platform ([audio.md](audio.md#known-limitations)) |

## Debugging

- **Logs**: `wiretune.log` in the player's data folder, `wiretune-server.log` in the server's
  ([where](user-guide.md#where-things-are)). `WIRETUNE_LOG_LEVEL=debug` adds paths and device names. Log lines pass
  through `WiretuneLog.redact`, which blanks `token=` values; keep it that way when logging URLs.
- **Audio**: mpv warnings and errors are logged under `MediaKitDriver`. Device list: `mpv --audio-device=help`, plus
  `aplay -l` on Linux.
- **Interface**: *Settings → Performance statistics* shows Flutter's performance overlay.

### UI automation

A local HTTP remote control for scripted UI testing. Debug builds only, and only when `WIRETUNE_UI_AUTOMATION=1`:

```bash
cd app && flutter build linux --debug
WIRETUNE_UI_AUTOMATION=1 WIRETUNE_DATA_DIR=/tmp/wt-ui build/linux/x64/debug/bundle/wiretune
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=albums'        # saved to the temp folder
curl 'http://127.0.0.1:5201/api/ui/resize?width=400&height=820'   # phone width
```

All routes: `app/lib/src/debug/ui_automation_server.dart`. It has no authentication; use it only on a development
machine with a throw-away data folder ([SECURITY.md](../SECURITY.md#players)).

### On devices

- **Android**: `flutter run -d <device>` in `app/` (phone with USB debugging, emulator, or TV after
  `adb connect <tv-ip>`).
- **Android Auto without a car**: install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager →
  *SDK Tools*). On the phone, tap the Android Auto version ten times for developer mode, allow *Unknown sources*, choose
  *Start head unit server*. Then `adb forward tcp:5277 tcp:5277` and run
  `$ANDROID_HOME/extras/google/auto/desktop-head-unit`.
- **Tizen**: `sdb connect <tv-ip>`, then `flutter-tizen run -d <tv-ip>:26101` in `app/`
  ([preparing the TV](building.md#samsung-tv-player-tizen)).

## Platform code

- **Android**: `MainActivity.kt` shares its Flutter engine with the media service. TV detection, music folder, audio
  permission and CPU/Wi-Fi locks are in `packages/wiretune_platform`. Application ID: `com.wiretune.player`.
- **iOS and macOS**: `ios/Runner/Info.plist` (background audio, local network, plain HTTP) and
  `macos/Runner/*.entitlements` (not sandboxed; see the comment there).
- **Linux and Windows**: `main.dart` hides the system title bar and the header draws its own window buttons.
- **Tizen**: `tizen/` is the .NET runner. Dart sees Tizen as Linux, so `App.cs` answers the `wiretune/platform` channel
  to report it's a TV.

## Extending

### An HTTP endpoint

Add the route to the table in `server/lib/src/server.dart` with its access level (never `Access.media` for a new one),
validate all input, and answer errors with `errorResponse` and a code from `ErrorCodes`. Records go in
`packages/wiretune_core/lib/src/models/protocol.dart`. Don't return server paths, and take the account from the token
(`call.principal`), never the URL or body. If the player needs it, add a method to `server_client.dart`. Test it
alongside the other server tests, including `401` and `403`, and update [api.md](api.md).

### A file type

Add the extension to `AudioFileTypes` in `models/audio_format.dart`, teach `metadata/tag_reader.dart` its tags and
duration, and add it to [server.md](server.md#scanning). Playback depends on libmpv (and the TV on Tizen).

### Texts and languages

All interface text is in `packages/wiretune_core/lib/src/localization/strings.dart`, one line per key:
`'Key': ('hu', 'en', 'de'),`. Widgets use `context.tr('Key')` and `context.trf('Key', [args])`; elsewhere
`Localizer.get` and `Localizer.format`. A `_One` variant is used when the first argument is exactly `1`. Text composed
once and kept (status lines, badges) must be rebuilt in the view model's `refreshLocalizedTexts()` to follow language
changes. Tests catch missing translations, mismatched placeholders and unused or undefined keys.

A fourth language is a code change: extend the record type and every key, add the constant, a `languages` entry and the
`Localizer.lookup` case, and update the tests.

### A view or a setting

A new section needs an `AppSection` value, a page registered in `pages/section_page.dart` (with an icon), a sidebar
entry (and bottom bar entry on phones if it belongs there), a place in `navVisualOrder` and an accent in
`theme/palette.dart`. A persistent setting is a key in the `settings` table, read and written through `LibraryService`.
Anything the back button must respect goes into `MainViewModel.tryNavigateBack()`.

## CI

`.github/workflows/ci.yml` checks formatting, runs `dart analyze --fatal-infos` on all packages and `tool/`, runs all
tests with `ffmpeg` installed, and builds the server, APKs, desktop players and an unsigned iOS build. It keeps
`dist/server` and the APKs as artifacts. Tizen isn't built, and nothing runs on a device or judges audio.
