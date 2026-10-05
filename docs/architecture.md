# Architecture

How the code hangs together. What it does for people is in the [user guide](user-guide.md), [server.md](server.md)
and [audio.md](audio.md).

## The shape of it

```
app/                          the Flutter player: view models, layouts, pages, widgets, audio drivers, native shells
server/                       the Dart server: bin/ is the command line, lib/ the routes, accounts and scanning
packages/wiretune_core/       shared by everything: models, database, tag reader, library, audio engine, server client
packages/wiretune_platform/   Wiretune's own Android code, as a Flutter plugin
tool/build.dart               release builds of every target, collected in dist/
```

The server is a headless player: it runs the same `LibraryService`, `MetadataScanner` and `DatabaseManager` from
`wiretune_core` (pure Dart) and puts HTTP on top. The tag reader is Wiretune's own, with no native code, so the scanner
runs anywhere Dart does. `wiretune_platform` is a plugin rather than activity code because Android Auto can start the
Flutter engine without an activity, and plugins still get registered there. Shared test doubles live in
`wiretune_core/lib/testing.dart`.

## The library

`LibraryService` keeps the library in memory as an immutable `LibrarySnapshot` and swaps it wholesale after every
change, so readers never see half a library and never take a lock. One scan runs at a time, and scans and server
merges take turns through a commit gate.

- **Track IDs** are the first 32 hex digits of the SHA-256 of the full path (lower-cased on Windows and macOS, whose
  file systems ignore case). Scans read in batches on 2 to 8 isolates and skip files whose path, size and modification
  time haven't changed.
- **Albums** are keyed by title plus album artist (`Track.albumId`, shared with the server's cover route). A folder of
  tracks with one album title gets one inferred album artist, which is shown but never stored
  (`Track.albumArtistInferred`), so it can't outlive the files it came from.
- **Hybrid**: local tracks have no `streamUrl`, server tracks do. `TrackDeduplication.mergeTracks` folds a server
  duplicate into the local copy, favourite, play count and playlist entries included.
- **Writes are diffs**: one transaction per change, and rows that didn't change aren't touched.
- **User data** of server tracks lives on the server account. While signed in (`LibraryService.serverConnected`), a
  change lands locally at once and `ServerSession` sends it on; while not, server tracks and server playlists are
  read-only. The player's copy is a cache that every refresh overwrites.

The services talk through synchronous `Event<T>`s: a handler has run by the time `emit` returns.

## Persistence

SQLite in WAL mode, one synchronous connection per database, instants stored as microseconds since the epoch. The
schema version is `PRAGMA user_version` (1), and a database of any other version is refused
(`IncompatibleDatabaseException`) rather than misread. A change to the tables raises the version and adds the step that
upgrades the previous one in place. Both sides create every table and use what they need:

| Table | Used by | Holds |
|---|---|---|
| `tracks` | both | The index; in the player also the cached favourites and play counts |
| `playlists` | player | Playlists; `is_server` marks a cached server one |
| `settings` | both | Key/value pairs: the player's server address, token and preferences; the server's `jwt_secret` and music folder |
| `users` | server | Accounts, with bcrypt hashes |
| `user_favorites`, `user_plays`, `user_playlists` | server | Each account's data |

## Player and server

`ServerSession` is the player's connection state machine: `notConfigured`, `connecting`, `offline`, `setupRequired`,
`loginRequired`, `connected`. Every failure becomes a state with a message the UI can show, and its commands never
throw. Connecting probes `/api/auth/setup-required`, then loads `/api/auth/me`, all of `/api/tracks` (there's no
incremental sync) and `/api/me/data`.

The sign-in token only ever goes to the address that issued it. Stream URLs are stored without credentials: the engine
appends a short-lived stream token at the moment it hands one to a driver, and `WiretuneLog` blanks every `token=`
anyway.

Changes to the account's data go through one ordered queue, flushed before every refresh and sign-out so that a
download can't undo them. A favourite the server refused is put back; a failed play or playlist edit isn't retried.
`400`, `409` and `413` mean "reachable, but no" and keep the session connected; anything else marks it offline.

## Server

`WiretuneServer.start` wires the options (`ServerOptions`: command-line flags, each also a `WIRETUNE_*` variable),
the database, the library, `AuthService`, `UserDataService`, `SetupCode` and `LibraryScanService` to a routes table,
where every route declares its access level (anonymous, user, admin, media) and its body limit.

- **Auth**: bcrypt (cost 12) in an isolate, a dummy hash for unknown names so the timing gives nothing away,
  HMAC-SHA256 JWTs (`sub`, `name`, `role`, and an `aud` that tells a sign-in token from a stream token), and
  first-admin creation as one atomic `INSERT … WHERE NOT EXISTS`. Every token is checked against `users`, so deleting
  an account locks it out at once. A stream token opens only the media routes, and it's the only kind `?token=` takes.
- **User data**: every method takes the account from the token, so no route can reach another account's rows, and the
  limits are part of each insert's SQL, so parallel requests can't sneak past them.
- **Scanning**: a loop that wakes for a request or the interval. Stopping the server cancels a running scan.
- **Streaming** checks that the file lies inside the library root by whole path segments (`/music2` isn't inside
  `/music`) before it serves a byte.

## Audio

`WiretuneAudioEngine` (core) owns the track, devices, modes and volume, and drives one `AudioDriver`:
`MediaKitAudioDriver` (libmpv) everywhere but Tizen, `TizenAudioDriver` there. A *playback generation* counter makes
the drivers ignore late callbacks from a source that has since been replaced. Around the engine, `MobileAudio`
handles audio focus and Android's CPU and Wi-Fi locks, and `WiretuneMediaSession` mirrors the player into the system's
media controls; on Android it's also the `MediaBrowserService` that Android Auto browses. Per platform:
[audio.md](audio.md).

## Interface

`ChangeNotifier` view models, no state-management package. `MainViewModel` owns the engine, the library, the session
and one view model per area, and `AppScope` hands it down as `context.vm`.

- **Two layouts**, `WideLayout` (desktop, tablet, every TV) and `PhoneLayout` (below 720 logical pixels, or a phone),
  share the view models and the pages.
- **Navigation** is the `AppSection` enum plus a few flags. `MainViewModel.tryNavigateBack()` closes layers and walks
  the tab history for the back button and Escape alike; it needs no platform API, so it's unit-tested.
- **Big libraries** stay smooth: track lists are slivers, and covers are decoded at the size they're shown, into a 120
  MB image cache (160 MB on a TV). The token for server covers travels in a header, never in the URL.
- **Theme**: an accent and a window gradient per section (`theme/palette.dart`), built once per section. Over the
  gradient the backdrop washes in the colours of the cover that's playing (`widgets/ambient.dart`): the cover is
  decoded at 64 px and blurred once into a 96 px bitmap, so nothing is blurred per frame, and it turns only on a
  desktop while music plays (not with the system's reduced motion).
- **Battery**: on a phone or tablet (`AppPlatform.isMobile`) nothing animates on its own: the backdrop doesn't turn,
  the logo and the player's cover don't breathe, and the progress follows `PlayerViewModel.elapsedSeconds`, so music
  that plays on draws a frame a second. `WiretuneMediaSession` publishes changes, never a position that keeps pace: the
  system moves its own progress on from the last one.
- **Lyrics** load only while they're on screen: the file's own (or the server's `/api/lyrics`), then LRCLIB if
  allowed, cached per track. A failed lookup isn't cached, so the panel can tell "couldn't reach" from "no lyrics".

## Localisation

Every text is one line in `wiretune_core/lib/src/localization/strings.dart`: `'Key': ('hu', 'en', 'de')`. Widgets read
them through `context.tr` and `context.trf` and rebuild when the language changes. It's English until the user picks
another; the system language is never read. Adding text or a language:
[development.md](development.md#texts-and-languages).
