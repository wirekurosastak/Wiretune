# Development

## Running from source

```bash
cd server && dart run bin/wiretune_server.dart --library /path/to/music --data-dir /tmp/wt-dev-server   # one terminal
cd app && WIRETUNE_DATA_DIR=/tmp/wt-dev flutter run -d linux       # another; or -d windows, -d macos, a phone
```

`--data-dir` and `WIRETUNE_DATA_DIR` give the server and the player throw-away data folders, so a Wiretune you really
use on this machine stays untouched.

### On a phone, TV or car

On Android, run `flutter run -d <device>` in `app/` for a phone with USB debugging on, an emulator, or a TV after
`adb connect <tv-ip>`.

To try Android Auto without a car, install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager →
*SDK Tools*). On the phone, tap the version number in Android Auto's settings ten times to turn on developer mode, allow
*Unknown sources* and choose *Start head unit server*. Then run `adb forward tcp:5277 tcp:5277` and
`$ANDROID_HOME/extras/google/auto/desktop-head-unit`.

On a Samsung TV, run `sdb connect <tv-ip>`, then `flutter-tizen run -d <tv-ip>:26101` in `app/`
([preparing the TV](building.md#samsung-tv-player-tizen)).

## Where is what

- `packages/wiretune_core/` is pure Dart, shared by the server and every player. Under `lib/src/` are `models/` (with
  the formats in `audio_format.dart`, and the server's records and error codes in `protocol.dart`), `data/`
  (`DatabaseManager`, `LibraryRepository`), `metadata/` (the tag reader, `tag_reader.dart`), `services/`
  (`LibraryService`, the scanner, `server_client.dart`, `ServerSession`, remote control, downloads), `audio/`
  (`WiretuneAudioEngine`, the spectrum analyzer), `localization/strings.dart` and `util/`. `lib/testing.dart` holds the
  test doubles that every package's tests share.
- `server/lib/src/` holds `server.dart` (the routes table), `auth_service.dart`, `user_data_service.dart`,
  `library_scan_service.dart`, `remote_hub.dart` and `config.dart` (the options).
- `app/lib/main.dart` starts the player. Under `app/lib/src/` are `view_models/` (`MainViewModel` and one view model
  per area), `layouts/` (wide and phone), `pages/`, `widgets/`, `theme/`, `audio/` (`MediaKitAudioDriver`,
  `TizenAudioDriver`, the media session) and `debug/` (UI automation).
- `packages/wiretune_platform/` is the Android code, as a Flutter plugin.
- `tool/build.dart` makes the release builds of every target.

### How it fits together

The server is a headless player: it runs the same `LibraryService`, scanner and database as the players and puts HTTP
on top. The library is an immutable `LibrarySnapshot`, rebuilt and swapped whole after each change. A track's ID derives
from its file's full path, and albums are keyed by title and album artist (`Track.albumId`). A track's tags
(`Track.tagged`) never change, while how the library files it (`Track.filed`) is worked out again on every rebuild.

Favorites, play counts, playlists and hidden items are stored by track ID in `LibraryService`, never on a `Track`, and
for server tracks they belong to the account. The player's connection is the `ServerSession` state machine, whose
connecting, signing in and refreshing never throw. Server pushes (`dataChanged`, `libraryChanged`) share one WebSocket
(`/api/remote`) with remote control.

In the player, `WiretuneAudioEngine` owns the playback state and drives one `AudioDriver`. View models are
`ChangeNotifier`s handed down by `AppScope` (`context.vm`).

The database is SQLite in WAL mode with one synchronous connection. It keeps its schema version in
`PRAGMA user_version`, so an older database is upgraded in place and a newer one is refused.

## Tests

Each package has its own tests: `dart test` in `packages/wiretune_core/` and `server/`, `flutter test` in `app/`. Run a
single file with `dart test test/remote_test.dart`, or filter by name with `--name <pattern>`.
[CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests) lists every check to run before a pull request.

Server tests start a real server per test over a generated music folder. Core tests use real SQLite and files encoded by
`ffmpeg`. App tests render every section in both layouts, both themes and several sizes.

Tests that need `ffmpeg` or `dbus-daemon` are skipped when it's missing, not passed, so watch the skipped count. Nothing
automated covers the real audio drivers, the media session, Android Auto, audio hardware or the native shells.

### UI automation

Debug builds include a local HTTP remote control for scripted UI testing, which starts only when
`WIRETUNE_UI_AUTOMATION=1` is set:

```bash
cd app && flutter build linux --debug
WIRETUNE_UI_AUTOMATION=1 WIRETUNE_DATA_DIR=/tmp/wt-ui build/linux/x64/debug/bundle/wiretune
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=albums'        # saved to the temp folder
curl 'http://127.0.0.1:5201/api/ui/resize?width=400&height=820'   # phone width
```

The full list of routes is in `app/lib/src/debug/ui_automation_server.dart`. It has no authentication, so use it only on
a development machine with a throw-away data folder ([SECURITY.md](../SECURITY.md#players)).

## Debugging

The player logs to `wiretune.log` in its data folder ([where](user-guide.md#where-things-are)), and the server to
`wiretune-server.log` in its own ([where](server.md#data-directory)). `WIRETUNE_LOG_LEVEL=debug` adds paths and device
names. Every line passes through `WiretuneLog.redact`, which blanks `token=` values, so keep it that way when you log a
URL.

mpv's warnings and errors are logged under `MediaKitDriver`. The device list is mpv's own (`mpv --audio-device=help`)
plus, on Linux, the ALSA hardware from `aplay -l`. *Settings → Appearance → Performance statistics* shows Flutter's
performance overlay.

## Platform code

- **Android**: `MainActivity.kt` shares its Flutter engine with the media service. TV detection, the music folder, the
  permission to read audio and the CPU and Wi-Fi locks are in `packages/wiretune_platform`. The application ID is
  `com.wiretune.player`.
- **iOS and macOS**: `ios/Runner/Info.plist` declares background audio, local network access and plain HTTP;
  `ios/Runner/AppDelegate.swift` answers `excludeFromBackup` on the `wiretune/platform` channel, which keeps the
  downloads out of iCloud backups; `macos/Runner/*.entitlements` leaves the app unsandboxed, and its comment says why.
  The channel's methods on every platform are listed on `AppPlatform._channel` (`app/lib/src/platform.dart`).
- **Linux and Windows**: `main.dart` hides the system title bar, and the header draws its own window buttons.
- **Tizen**: `tizen/` is the .NET runner. Dart sees Tizen as Linux, so `App.cs` answers the `wiretune/platform` channel
  to report a TV. The TV can't load the SQLite library the sqlite3 package downloads for Linux on ARM, so
  `tool/build.dart` switches the Tizen build to the TV's own SQLite and restores `app/pubspec.yaml` afterwards.

## Extending

### An HTTP endpoint

Add the route to the table in `server/lib/src/server.dart` with its access level (never `Access.media` for a new one),
validate every input, and answer errors with `errorResponse` and a code from `ErrorCodes`. Its records go in
`packages/wiretune_core/lib/src/models/protocol.dart`. Follow the [trust boundaries](../CONTRIBUTING.md#code): never
return a server path, and take the account from the token (`call.principal`). If the player needs the route, add a
method to `server_client.dart`. Test it with the other server tests, including the `401` and `403` cases, and update
[api.md](api.md).

### A file type

Add the extension to `AudioFileTypes` in `models/audio_format.dart`, teach `metadata/tag_reader.dart` its tags and
duration, and add it to the list in [server.md](server.md#scanning). Whether it plays is up to libmpv, and on Tizen up
to the TV.

### Texts and languages

All interface text lives in `packages/wiretune_core/lib/src/localization/strings.dart`, one line per key:
`'Key': ('hu', 'en', 'de'),`. Widgets use `context.tr('Key')` and `context.trf('Key', [args])`, and other code
`Localizer.get` and `Localizer.format`. A `_One` variant is used when the first argument is exactly `1`. Text that's
composed once and kept, such as status lines and badges, has to be rebuilt in the view model's `refreshLocalizedTexts()`
to follow a language change. The tests catch missing translations, mismatched placeholders, and keys that are used but
undefined or defined but unused.

A fourth language is a code change, because each entry is a three-language record: extend the record and fill in every
key, add the constant, a `languages` entry and the case in `Localizer.lookup`, and update the tests.

### A view or a setting

A new section starts with an `AppSection` value; the compiler then points at the switches that need its page, icon,
accent and place in `navVisualOrder`. Add it by hand to the sidebar in `layouts/wide_layout.dart` and, if it belongs
there, to the phone's bottom bar in `layouts/phone_layout.dart`. A persistent setting is a key in the `settings` table,
read and written through `LibraryService`. Anything the back button has to respect goes into
`MainViewModel.tryNavigateBack()`.

### App icons

The app icons are generated from `app/assets/wiretune.png`: run `dart run flutter_launcher_icons` in `app/`.

## CI

`.github/workflows/ci.yml` checks the formatting, analyzes every package and `tool/` with `--fatal-infos`, runs every
test with `ffmpeg` installed, and builds the server, the APKs, the desktop players and an unsigned iOS app through
`tool/build.dart`, keeping `dist/server` and the APKs as artifacts. It doesn't build Tizen, and it runs nothing on a
device.

## What has actually been tried

| Area | What has been tried |
|---|---|
| Core, server | The tests, on Linux. The server binary has run against a real folder: scanning, sign-in, ranges, covers and live folder changes |
| App logic and layouts | The view-model and widget tests ([above](#tests)), including a small phone at 150 % font size and a 1080p TV |
| Downloads, remote control | Against the real server in the tests; remote control also between real devices |
| Linux desktop | Built and run against a real library (1,320 tracks) at several window sizes, with playback, the queue, the spectrum, MPRIS and the device list driven through UI automation |
| Windows | Built and run |
| Android | Built and run on a phone. **Untested on a TV and in a car**, and so is downloading into the shared *Music* folder without a permission (Android 11 and later) |
| macOS, iOS | Built by CI only; **never run** |
| Tizen | Built on Fedora and tried briefly on a 2024 Samsung TV (Tizen 8.0): it signs in and plays, and the remote reaches everything, but navigation is sluggish and **needs more work** |
| Exclusive, bit-perfect | Tried on Linux and Windows with an SMSL SU-1 DAC; not measured ([audio.md](audio.md#bit-perfect)) |
