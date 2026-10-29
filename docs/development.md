# Development

## Running from source

```bash
cd server && dart run bin/wiretune_server.dart --library /path/to/music --data-dir /tmp/wt-dev-server   # one terminal
cd app && WIRETUNE_DATA_DIR=/tmp/wt-dev flutter run -d linux       # another; or -d windows, -d macos, a phone
```

`--data-dir` and `WIRETUNE_DATA_DIR` use throw-away data folders, so your real Wiretune data stays untouched.

### On a phone, TV or car

**Android:** run `flutter run -d <device>` in `app/`, for a phone with USB debugging, an emulator, or a TV after
`adb connect <tv-ip>`.

**Android Auto without a car:**

1. Install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager → *SDK Tools*).
2. On the phone, tap the version number in Android Auto's settings ten times to enable developer mode, allow *Unknown
   sources* and choose *Start head unit server*.
3. Run `adb forward tcp:5277 tcp:5277` and `$ANDROID_HOME/extras/google/auto/desktop-head-unit`.

**Samsung TV:** run `sdb connect <tv-ip>`, then `flutter-tizen run -d <tv-ip>:26101` in `app/`
([preparing the TV](building.md#samsung-tv-player-tizen)).

## Where is what

- `packages/wiretune_core/`: pure Dart, shared by the server and every player. In `lib/src/`:
  - `models/`: formats (`audio_format.dart`), the server's records and error codes (`protocol.dart`)
  - `data/`: `DatabaseManager`, `LibraryRepository`
  - `metadata/`: the tag reader (`tag_reader.dart`)
  - `services/`: `LibraryService`, the scanner, `server_client.dart`, `ServerSession`, remote control, downloads, the
    update check (`update_check.dart`)
  - `audio/`: `WiretuneAudioEngine`, the spectrum analyzer
  - `localization/strings.dart`, `util/`

  `lib/testing.dart` has the test doubles shared by every package's tests.
- `server/lib/src/`: `server.dart` (the route table), `auth_service.dart`, `user_data_service.dart`,
  `library_scan_service.dart`, `remote_hub.dart`, `config.dart` (the options).
- `app/lib/main.dart` starts the player. In `app/lib/src/`: `view_models/` (`MainViewModel` and one view model per
  area), `layouts/` (wide and phone), `pages/`, `widgets/`, `theme/`, `audio/` (`MediaKitAudioDriver`,
  `TizenAudioDriver`, the media session), `debug/` (UI automation), `update_installer.dart` (installing an update on
  each platform).
- `packages/wiretune_platform/`: the Android code, as a Flutter plugin.
- `tool/build.dart`: release builds for every target.

### How it fits together

- **The server is a headless player.** It runs the same `LibraryService`, scanner and database as the players, with
  HTTP on top.
- **The library** is an immutable `LibrarySnapshot`, rebuilt and swapped whole after each change. A track's ID comes
  from its full file path. Albums are keyed by title and album artist (`Track.albumId`). A track's tags
  (`Track.tagged`) never change; how the library files it (`Track.filed`) is recomputed on every rebuild.
- **User data** (favorites, play counts, playlists, hidden items) is stored by track ID in `LibraryService`, never on
  a `Track`. For server tracks it belongs to the account.
- **The connection** is the `ServerSession` state machine. Connecting, signing in and refreshing never throw. Server
  pushes (`dataChanged`, `libraryChanged`) share one WebSocket (`/api/remote`) with remote control.
- **Playback:** `WiretuneAudioEngine` owns the playback state and drives one `AudioDriver`. View models are
  `ChangeNotifier`s passed down by `AppScope` (`context.vm`).
- **The database** is SQLite in WAL mode with one synchronous connection. The schema version is in
  `PRAGMA user_version`: older databases are upgraded in place, newer ones are refused.

## Tests

Each package has its own tests: `dart test` in `packages/wiretune_core/` and `server/`, `flutter test` in `app/`. Run
one file with `dart test test/remote_test.dart`, or filter by name with `--name <pattern>`. The full pre-push checks are
in [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

- Server tests start a real server per test, over a generated music folder.
- Core tests use real SQLite and files encoded with `ffmpeg`.
- App tests render every section in both layouts, both themes and several sizes.

Tests that need `ffmpeg` or `dbus-daemon` are skipped (not passed) when it's missing: watch the skip count. Nothing
automated covers the real audio drivers, the media session, Android Auto, audio hardware or the native shells.

### UI automation

Debug builds include a local HTTP remote control for scripted UI tests. It only starts with `WIRETUNE_UI_AUTOMATION=1`:

```bash
cd app && flutter build linux --debug
WIRETUNE_UI_AUTOMATION=1 WIRETUNE_DATA_DIR=/tmp/wt-ui build/linux/x64/debug/bundle/wiretune
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=albums'        # saved to the temp folder
curl 'http://127.0.0.1:5201/api/ui/resize?width=400&height=820'   # phone width
```

All routes are in `app/lib/src/debug/ui_automation_server.dart`. There's no authentication: use it only on a
development machine with a throw-away data folder ([SECURITY.md](../SECURITY.md#players)).

## Debugging

- Logs: the player writes `wiretune.log` in its data folder ([where](user-guide.md#where-things-are)), the server
  `wiretune-server.log` in its own ([where](server.md#data-directory)). `WIRETUNE_LOG_LEVEL=debug` adds paths and device
  names.
- Every log line goes through `WiretuneLog.redact`, which blanks `token=` values. Keep it that way when logging a URL.
- mpv's warnings and errors are logged under `MediaKitDriver`.
- The device list is mpv's (`mpv --audio-device=help`), plus on Linux the ALSA hardware from `aplay -l`.
- *Settings → Appearance → Performance statistics* shows Flutter's performance overlay.

## Platform code

- **Android:** `MainActivity.kt` shares its Flutter engine with the media service. `packages/wiretune_platform` has TV
  detection, the music folder, the audio permission, the CPU and Wi-Fi locks, and installing updates. Application ID:
  `com.wiretune.player`.
- **iOS and macOS:** `ios/Runner/Info.plist` declares background audio, local network access and plain HTTP.
  `ios/Runner/AppDelegate.swift` handles `excludeFromBackup` on the `wiretune/platform` channel (keeps downloads out of
  iCloud backups). `macos/Runner/*.entitlements` leaves the app unsandboxed; its comment says why. Every platform's
  channel methods are listed on `AppPlatform._channel` (`app/lib/src/platform.dart`).
- **Linux and Windows:** `main.dart` hides the system title bar; the header draws its own window buttons.
- **Tizen:** `tizen/` is the .NET runner. Dart sees Tizen as Linux, so `App.cs` answers the `wiretune/platform` channel
  to report a TV. The TV can't load the SQLite library the sqlite3 package downloads for Linux on ARM, so
  `tool/build.dart` switches the Tizen build to the TV's own SQLite and restores `app/pubspec.yaml` afterwards.

## Extending

### An HTTP endpoint

1. Add the route to the table in `server/lib/src/server.dart` with its access level (never `Access.media` for a new
   one).
2. Validate every input. Answer errors with `errorResponse` and a code from `ErrorCodes`.
3. Put its records in `packages/wiretune_core/lib/src/models/protocol.dart`.
4. Follow the [trust boundaries](../CONTRIBUTING.md#code): never return a server path, take the account from the token
   (`call.principal`).
5. If the player needs it, add a method to `server_client.dart`.
6. Test it with the other server tests, including the `401` and `403` cases, and update [api.md](api.md).

### A file type

Add the extension to `AudioFileTypes` in `models/audio_format.dart`, teach `metadata/tag_reader.dart` its tags and
duration, and add it to the list in [server.md](server.md#scanning). Whether it plays depends on libmpv, and on Tizen on
the TV.

### Texts and languages

All interface text is in `packages/wiretune_core/lib/src/localization/strings.dart`, one line per key:
`'Key': ('hu', 'en', 'de'),`.

- Widgets use `context.tr('Key')` and `context.trf('Key', [args])`; other code uses `Localizer.get` and
  `Localizer.format`.
- A `_One` variant is used when the first argument is exactly `1`.
- Text built once and kept (status lines, badges) must be rebuilt in the view model's `refreshLocalizedTexts()` to
  follow a language change.
- The tests catch missing translations, mismatched placeholders, and keys used but undefined or defined but unused.

A fourth language is a code change: extend the record and fill in every key, add the constant, a `languages` entry and
the case in `Localizer.lookup`, and update the tests.

### A view or a setting

- A new section starts with an `AppSection` value. The compiler then points to the switches that need its page, icon,
  accent and place in `navVisualOrder`.
- Add it by hand to the sidebar in `layouts/wide_layout.dart` and, if it belongs there, the phone's bottom bar in
  `layouts/phone_layout.dart`.
- A persistent setting is a key in the `settings` table, read and written through `LibraryService`.
- Anything the back button must respect goes in `MainViewModel.tryNavigateBack()`.

### App icons

Generated from `app/assets/wiretune.png`: run `dart run flutter_launcher_icons` in `app/`. Tizen's and the Linux menu's
icons are made by hand; the commands are in `app/pubspec.yaml`.

## CI

`.github/workflows/ci.yml`:

- checks formatting and the license headers
- analyzes every package and `tool/` with `--fatal-infos`
- runs every test, with `ffmpeg` installed
- builds the server, the APKs, the desktop players, the Linux packages and an unsigned iOS app through
  `tool/build.dart`, and keeps `dist/server` and the APKs as artifacts

It doesn't build Tizen and runs nothing on a device.

## What has actually been tried

| Area | What has been tried |
|---|---|
| Core, server | The tests, on Linux. The server binary has run against a real folder: scanning, sign-in, ranges, covers and live folder changes |
| App logic and layouts | The view-model and widget tests ([above](#tests)), including a small phone at 150 % font size and a 1080p TV |
| Downloads, remote control | Against the real server in the tests; remote control also between real devices |
| Linux desktop | Built and run against a real library (1,320 tracks) at several window sizes, with playback, the queue, the spectrum, MPRIS and the device list driven through UI automation |
| Linux packages | The `.deb` and `.rpm` installed and started on Ubuntu 24.04, Debian 13 and Fedora 44 (in containers) |
| Windows | Built and run |
| Android | Built and run on a phone. **Untested on a TV and in a car**, and so is downloading into the shared *Music* folder without a permission (Android 11 and later) |
| macOS, iOS | Built by CI only; **never run** |
| Tizen | Built on Fedora and tried briefly on a 2024 Samsung TV (Tizen 8.0): signs in, plays, the remote reaches everything, but navigation is slow and **needs more work** |
| Updates | In the tests: the check, the download and its checksum, and replacing a Linux folder. No release exists yet, so no copy has updated itself for real. The package, Windows, macOS and Android steps are untried |
| Exclusive, bit-perfect | Tried on Linux and Windows with an SMSL SU-1 DAC; not measured ([audio.md](audio.md#bit-perfect)) |
