# Development

Where the code is, how to test it, and what has really been tried. Building is in [building.md](building.md); the
rules a change has to follow are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Running it from the source

```bash
cd server && dart run bin/wiretune_server.dart --library /path/to/music      # one terminal
cd app && WIRETUNE_DATA_DIR=/tmp/wt-dev flutter run -d linux                # another; or -d windows, -d macos, a phone
```

`WIRETUNE_DATA_DIR` gives you a throw-away player that leaves your real library and sign-in alone.

## Where is what

| Where | What |
|---|---|
| `packages/wiretune_core/` | Shared by the server and every player, pure Dart: |
| `…/lib/src/models/` | `Track`, `Album`, `Artist`, `Playlist`; formats and quality tiers; the server's records and error codes (`protocol.dart`); remote-control messages |
| `…/lib/src/data/` | SQLite: `DatabaseManager` (the schema and its upgrade steps) and `LibraryRepository` (every query) |
| `…/lib/src/metadata/` | The tag reader, Wiretune's own: ID3, FLAC and Vorbis comments, MP4, APE, WAV and AIFF chunks, DSF |
| `…/lib/src/services/` | `LibraryService` (the library), `MetadataScanner` (folder → tracks), `FolderWatch`, `ServerClient` and `ServerSession` (the player's server connection), `RemoteClient`, `DownloadService`, online lyrics and artist pictures |
| `…/lib/src/audio/` | `WiretuneAudioEngine`, the `AudioDriver` it drives, the spectrum analyzer |
| `…/lib/src/localization/strings.dart` | Every text, in three languages |
| `…/lib/testing.dart` | Test doubles and helpers shared by all three packages' tests |
| `server/lib/src/` | `server.dart` (the routes table), `auth_service.dart`, `user_data_service.dart`, `library_scan_service.dart` (the scan loop and the folder watch), `remote_hub.dart` |
| `app/lib/main.dart` | What starts the player: platform, paths, driver, view model |
| `app/lib/src/view_models/` | `MainViewModel` owns everything else; one view model per area (player, lyrics, the library's lists, search, settings, downloads) |
| `app/lib/src/layouts/`, `pages/` | `WideLayout` and `PhoneLayout`; a page per section, the full-screen player, the queue and lyrics, the sign-in |
| `app/lib/src/widgets/` | The shared pieces, a file each: page parts, buttons, links, badges, dialogs, cards, the track list, covers, the player controls … |
| `app/lib/src/audio/` | `MediaKitAudioDriver` (libmpv), `TizenAudioDriver`, the system media session, a phone's audio focus and locks |
| `packages/wiretune_platform/` | Wiretune's Android code, as a plugin (Android Auto starts the app without an activity) |
| `tool/build.dart` | Release builds of every target |

### How it fits together

- **The server is a headless player**: it runs the same `LibraryService`, scanner and database as the players and puts
  HTTP on top. Routes declare their access (anonymous, user, admin, media) in one table.
- **The library** is an immutable `LibrarySnapshot`, rebuilt and swapped whole after each change, so readers never see
  half of one. Services talk through synchronous `Event`s: a handler has run when `emit` returns.
- **Track IDs** come from the file's full path. **Albums** are keyed by title and album artist (`Track.albumId`, also
  the key of the server's cover route). A track's tags (`Track.tagged`) never change; where the library files it
  (`Track.filed`: folder albums, an inferred album artist) is worked out at every rebuild.
- **Scans** read only new and changed files (path, size, time, and the cover next to them), on 2 to 8 isolates, and a
  scan that finds nothing changes nothing. The server scans when its folder changes (`FolderWatch`), on an interval
  and on request; a player reads its local folder at start, on changes (computers) and when it comes to the front
  (phones). Downloads in the local folder are left out.
- **Favorites, play counts, playlists and hidden items** are kept by `LibraryService`, by track ID, never on a
  `Track`. For server tracks they belong to the account on the server: a change lands at once and `ServerSession`
  queues it for the server; offline, server tracks are read-only.
- **The player's connection** (`ServerSession`) is a state machine (`notConfigured`, `connecting`, `offline`,
  `setupRequired`, `loginRequired`, `connected`): connecting, signing in and refreshing never throw. It downloads the track list and the account
  data with their ETags, so a check is cheap; while the server is out of reach it asks again by itself.
- **Pushes** ride on the remote-control WebSocket (`RemoteClient`, `RemoteHub`): `dataChanged` when the account's data
  changed elsewhere, `libraryChanged` when a scan changed the library. The same connection carries the players' states
  and commands; controlling another device, the player shows that device and sends its commands there.
- **Covers**: the scanner caches a file's picture under a name with its size, so a new picture is a new file. The
  server adds each album cover's version to the track list, the players put it in the cover's address, and they keep
  the server's covers on disk (`CoverArt` in `widgets/cover_image.dart`).
- **Downloads** (`DownloadService`): what the user chose to download is kept as a choice, and the tracks it covers are
  worked out again after every change. One file at a time, resumable, into the app's own folder first, then moved into
  place; the `downloads` table records which file is which track's copy, and of which version.
- **Audio**: `WiretuneAudioEngine` owns the track, the devices, the modes and the volume, and drives one
  `AudioDriver`. A generation counter makes the drivers ignore late callbacks. For gapless playback the player keeps the
  engine told of the next entry. On Linux, exclusive playback claims the ALSA card through D-Bus device reservation.
- **The interface**: `ChangeNotifier` view models, handed down by `AppScope` as `context.vm`. Two layouts share them.
  Back and Escape close a dialog or menu first, then `MainViewModel.tryNavigateBack()` walks back (unit-tested). On a
  phone nothing animates by itself, for the battery.
- **The database**: SQLite in WAL mode, one synchronous connection, schema version 8 (`PRAGMA user_version`). An older
  database runs the upgrade steps after its own in one transaction; a newer one is refused, never misread.

## Tests

```bash
(cd packages/wiretune_core && dart test)
(cd server && dart test)        # one file: dart test test/remote_test.dart; by name: --name pattern
(cd app && flutter test)
```

The server tests start a real server per test, on a free port over a generated music folder: sign-in, per-account
data, restarts, the hardening, the scan loop and the folder watch, pushes over real WebSockets. The player's side of
the account data runs against that same real server. The core tests cover the repository on real SQLite, the tag reader
on files that `ffmpeg` encodes, the scanner, the library, deduplication, lyrics, the spectrum and the audio engine
(with `FakeAudioDriver`). The app tests cover the view models, back navigation, and every section in both layouts, both
themes and several sizes.

Tests that need `ffmpeg` (or `dbus-daemon`, for the sound card reservation) are *skipped* without it, not passed, so
mind the skipped count. Nothing covers the real drivers, the media session, Android Auto, audio hardware or the native
shells.

## What has actually been tried

| | |
|---|---|
| Core, server | The tests, on Linux. The server binary has run against a real folder: scanning, sign-in, gzip, ranges, covers, and music copied into the folder picked up by itself |
| App logic and layouts | View-model and widget tests: every section in both layouts, light and dark, a small phone at 150 % font size, a 1080p TV |
| Downloads, remote control | Against the real server in the tests: copies byte for byte, played with the server switched off, and two players of one account over real WebSockets. Remote control also works between real devices |
| Linux desktop | Built and run against a real server and library (1,320 tracks), every screen checked at 1280×820, 900×700 and phone width, and playback, the queue, the spectrum, MPRIS and the device list driven through UI automation. Exclusive and bit-perfect tried on an SMSL SU-1 DAC |
| Android | Built and run on a phone. **Not yet run on a TV or in a car**, and downloading into the shared *Music* folder without a permission (Android 11 and later) hasn't been tried on a device |
| Windows | Built and run. Exclusive and bit-perfect tried on an SMSL SU-1 DAC |
| macOS, iOS | Not yet built (they need their own hosts) |
| Tizen | Built on Fedora and quickly tried on a 2024 Samsung TV (Tizen 8.0): it signs in and plays, and the remote reaches everything, but moving around is sluggish and **needs more work** |
| Bit-perfect, exclusive | Tried on Linux and Windows with an SMSL SU-1; not measured on any platform ([audio.md](audio.md#known-limitations)) |

"Not yet" means exactly that. If you have one of those devices, you can move a row.

## Debugging

- **Logs**: `wiretune.log` in the player's data folder, `wiretune-server.log` in the server's
  ([where](user-guide.md#where-things-are)). `WIRETUNE_LOG_LEVEL=debug` adds paths and device names, so use it only
  while you hunt something. Every line passes through `WiretuneLog.redact`, which blanks `token=` values: keep it that
  way when you log a URL.
- **Audio**: mpv's warnings and errors land in the log under `MediaKitDriver`. The device list is mpv's own
  (`mpv --audio-device=help`) plus, on Linux, the ALSA hardware from `aplay -l`.
- **Interface**: *Settings → Performance statistics* turns on Flutter's performance overlay.

### UI automation

A local HTTP remote control for scripted UI testing, in debug builds only:

```bash
cd app && flutter build linux --debug
WIRETUNE_UI_AUTOMATION=1 WIRETUNE_DATA_DIR=/tmp/wt-ui build/linux/x64/debug/bundle/wiretune
curl http://127.0.0.1:5201/api/ui/state
curl 'http://127.0.0.1:5201/api/ui/navigate?section=Albums'
curl 'http://127.0.0.1:5201/api/ui/screenshot?name=albums'        # saved to the temp folder
curl 'http://127.0.0.1:5201/api/ui/resize?width=400&height=820'   # down to phone width
```

The rest of the routes (search, playback, sign-in, playlists, language, theme, sorting …) are in
`app/lib/src/debug/ui_automation_server.dart`. Release and profile builds contain none of it, and it only starts when
the variable is exactly `1`. It has no authentication, so keep it to a development machine and a throw-away data
folder ([SECURITY.md](../SECURITY.md#players)).

### On devices

- **Android**: `flutter run -d <device>` in `app/`, for a phone with USB debugging on, an emulator, or a TV after
  `adb connect <tv-ip>` (the Android TV emulator image, API 30 or newer, works too).
- **Android Auto without a car**: install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager →
  *SDK Tools*). On the phone, open Android Auto's settings, tap the version ten times for developer mode, allow
  *Unknown sources* and choose *Start head unit server*. Then `adb forward tcp:5277 tcp:5277` and run
  `$ANDROID_HOME/extras/google/auto/desktop-head-unit`.
- **Tizen**: `sdb connect <tv-ip>`, then `flutter-tizen run -d <tv-ip>:26101` in `app/`
  ([preparing the TV](building.md#samsung-tv-player-tizen)).

## Platform code

- **Android**: `MainActivity.kt` shares its Flutter engine with the media service; TV detection, the music folder, the
  permission to read audio files and the CPU and Wi-Fi locks are in `packages/wiretune_platform`. The manifest declares
  the TV launcher entry and banner, the media service that Android Auto browses, and `automotive_app_desc.xml`. The
  application ID is `com.wiretune.player`.
- **iOS and macOS**: `ios/Runner/Info.plist` (background audio, local network, plain HTTP) and
  `macos/Runner/*.entitlements` (not sandboxed, and the comment there says why).
- **Linux and Windows**: the runners set the window's size and icon; `main.dart` hides the system title bar, and the
  header draws its own window buttons.
- **Tizen**: `tizen/` is the .NET runner. Dart thinks Tizen is Linux, so `App.cs` answers the `wiretune/platform`
  channel to say it's a TV.

## Extending

### An HTTP endpoint

Add the route to the table in `server/lib/src/server.dart` with its access level (never `Access.media` for a new one),
validate every input, and answer errors with `errorResponse` (an English message and a code from `ErrorCodes`). Records
go into `packages/wiretune_core/lib/src/models/protocol.dart`. Nothing that lists the library carries a server path,
and per-person data takes the account from the token (`call.principal`), never from the URL or the body. If a player
needs the route, add a method to `server_client.dart` and turn its failures into a session state. Test it next to the
other server tests, the `401` and `403` cases included, and update [api.md](api.md).

### A file type

Add the extension to `AudioFileTypes` in `models/audio_format.dart`, teach `metadata/tag_reader.dart` its tags and
duration, and add it to the list in [server.md](server.md#scanning). Whether it plays is up to libmpv, and on Tizen up
to the TV.

### Texts and languages

All interface text lives in `packages/wiretune_core/lib/src/localization/strings.dart`, one line per key:
`'Key': ('hu', 'en', 'de'),`. Widgets use `context.tr('Key')` and `context.trf('Key', [args])`; everything else
`Localizer.get` and `Localizer.format`. A `_One` variant is picked when the first argument is exactly `1`. Text that's
composed once and kept (status lines, badges) has to be rebuilt in the view model's `refreshLocalizedTexts()`, or it
won't follow a language change. The tests catch missing translations, mismatched placeholders, and keys that are used
but undefined or defined but unused.

A fourth language is a code change, because each entry is a three-language record: extend the record and fill in every
key, add the constant, a `languages` entry and the case in `Localizer.lookup`, and update the tests.

### A view or a setting

A new section is a new `AppSection` value, a page registered in `pages/section_page.dart`, an entry in the wide
layout's sidebar (and the phone's bottom bar, if it belongs there), a place in `navVisualOrder` (the animated logo's
order), an icon in `pages/section_page.dart` and an accent in `theme/palette.dart`. A persistent player setting is a key in the `settings` table, read and
written through `LibraryService`. Anything the back button has to respect goes into `MainViewModel.tryNavigateBack()`.

## CI

`.github/workflows/ci.yml` checks the formatting, analyses all three packages and `tool/` with `--fatal-infos`, runs
every test with `ffmpeg` installed, and builds the server (Linux, Windows, macOS), the APKs and the three desktop
players with `tool/build.dart`, plus an unsigned iOS build, keeping `dist/server` and the APKs as artifacts. It doesn't
build Tizen, runs nothing on a device, and can't hear a thing, so try those parts by hand.
