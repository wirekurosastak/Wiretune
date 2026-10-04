# Architecture

How the code is organised. What each part does for the user is in [user-guide.md](user-guide.md) and
[server.md](server.md); the audio path is in [audio.md](audio.md).

## Repository layout

```
app/                        the Flutter player (one app for every platform)
  lib/                        view models, layouts, pages, widgets, audio drivers
  android/ ios/ linux/        the native shells, one per platform
  macos/ windows/ tizen/
  test/
server/                     the Dart server
  bin/wiretune_server.dart    the command line
  lib/                        HTTP routes, accounts, per-account data, library scan
  test/                       integration tests (a real server per test) and the C# compatibility fixtures
packages/
  wiretune_core/              the shared library: models, database, tag reader, library, audio engine, server client
  wiretune_platform/          Wiretune's own Android code, as a Flutter plugin
docs/                       the documentation
.github/workflows/ci.yml    formatting, analysis, tests and builds
```

```
app ──► packages/wiretune_core ◄── server
app ──► packages/wiretune_platform (Android only)
```

| Package | Role |
|---|---|
| `packages/wiretune_core` (`wiretune_core`) | Pure Dart, shared by everything: models, SQLite persistence, the tag reader and scanner, library service, audio engine and the driver interface, spectrum analyser, localisation, server session and HTTP client. `lib/testing.dart` holds the test doubles the other packages' tests use |
| `server` (`wiretune_server`) | Pure Dart HTTP server on [shelf](https://pub.dev/packages/shelf): JWT authentication, per-account favourites, play counts and playlists, background library scan. `bin/wiretune_server.dart` is the command line |
| `app` (`wiretune`) | The Flutter player for every platform: view models, two layouts (wide and phone), pages, widgets, and the platform audio drivers. The platform folders (`android/`, `ios/`, `linux/`, `macos/`, `windows/`, `tizen/`) are the native shells |
| `packages/wiretune_platform` (`wiretune_platform`) | A small local plugin with Wiretune's own Android code (TV detection, CPU and Wi-Fi locks). It is a plugin, not activity code, so that it is also registered on the engine Android Auto starts without an activity |

Main libraries: [sqlite3](https://pub.dev/packages/sqlite3) (bundles SQLite through a build hook), `crypto`, `http`,
`shelf`, `bcrypt` (server), [media_kit](https://pub.dev/packages/media_kit) with libmpv (playback),
[audio_service](https://pub.dev/packages/audio_service) and `audio_service_mpris` (media session), `audio_session`
(audio focus), `audioplayers_tizen` (Tizen playback), `file_picker`, `path_provider`, `window_manager` (the desktop
window). Versions are in the `pubspec.yaml` files. The tag reader is Wiretune's own
(`packages/wiretune_core/lib/src/metadata`), with no native dependency, so the scanner runs anywhere Dart runs.

The server and the players share `LibraryService`, `MetadataScanner` and `DatabaseManager`: a server is, in
effect, a headless player that scans a folder and exposes the index over HTTP.

This is a port of the earlier C#/.NET version (Avalonia and ASP.NET Core; its code is in the git history, before the
move to Dart). It keeps that version's database schema, HTTP API, JSON shapes, token format and track IDs on purpose,
so that servers and players of both versions work together and the new ones open the old data.
`packages/wiretune_core/lib/src/util/dotnet_format.dart` writes and reads the .NET formats this requires (`TimeSpan`
durations, ISO timestamps with seven fractional digits, upper-case hex IDs, invariant upper/lower casing);
`server/test/csharp_compatibility_test.dart` checks it against a database and tokens made by the C# server.

## Library model

`LibraryService` keeps the whole library in memory as an **immutable snapshot** (`LibrarySnapshot`: tracks, albums,
artists, genres) that is replaced wholesale after every change, so readers never see a half-built state. Changes
are serialised: one scan at a time (`_scanGate`), and local scans and server merges pass through a commit gate
(`_commitGate`, an `AsyncLock`) so neither works on a stale view.

- **Tracks** come from `MetadataScanner`. The ID is the first 32 hex characters (upper case) of the SHA-256 of the
  lower-cased full path. The scan reads files in batches of 24 on 2–8 isolates and reuses an entry when path, size and
  modification time are unchanged.
- **Albums** are keyed by album title plus album artist (track artist when untagged), case-insensitively; the key is
  `Track.albumId`, which the server's cover route and the player's cover URLs share. Before grouping, tracks in one
  folder with the same album title and no clashing numbers are consolidated onto a single album artist (explicit tag,
  else majority artist, else *Various Artists*). That inferred value is only ever shown: `Track.albumArtistInferred`
  marks it and the database keeps what the tags say, so it cannot outlive the files it was inferred from. **Artists**
  are the album artists.
- **Hybrid library**: tracks from a local scan have no `streamUrl`, tracks from a server do.
  `TrackDeduplication.mergeTracks` drops a server track that duplicates a local one, merges its favourite flag, play
  count, last-played time and (if missing) cover into the local track, and rewrites playlist entries that pointed
  at the server copy. The duplicate rules are in the [user guide](user-guide.md#server-and-local-music-together).
- **Persistence**: a change to the track list is written to the `tracks` table in one transaction as a difference:
  rows that are gone are deleted, new rows inserted and changed rows updated, and a row that is identical is not
  written at all. `isFavorite`, `playCount`, `lastPlayed` and `dateAdded` are carried over by track ID, so they
  survive a rescan.
- **Who owns the user data.** `LibraryService.userDataMode` (`UserDataMode`) says where the favourites, play counts
  and playlists of *server* tracks live: `server` (signed in to a server that stores them), `serverUnavailable` (such
  a server, but not connected: server tracks and their playlists are read-only) or `local` (no server, or one that
  predates per-account data). Tracks from a local folder always keep theirs on the device. In `server` mode a change
  is applied to the in-memory snapshot and the player's database at once, so the screen answers immediately, and
  handed to `ServerSession`, which sends it to the server in order. The player's copy is a cache for offline display;
  on every refresh the server's data replaces it.

Events between the services are synchronous `Event<T>` objects (`packages/wiretune_core/lib/src/util/event.dart`):
`listen` returns a function that unsubscribes, and a handler runs before `emit` returns, as the C# events did.

## Persistence

SQLite in WAL mode (`busy_timeout` 5 s, `synchronous = NORMAL`), through one synchronous connection per database
(`DatabaseManager`). The schema version is `PRAGMA user_version` (currently 4) and every start upgrades an older
database in place, in one transaction: version 2 added `tracks.file_modified_utc`, version 3 the per-account tables
and `playlists.is_server`, version 4 makes the next scan of local files read their tags again (album artists that
were inferred used to be stored as if tagged). Both sides create every table through the same `DatabaseManager`;
each uses the ones it needs.

| Table | Used by | Content |
|---|---|---|
| `tracks` | both | The library index; in the player also the cached `isFavorite`, `playCount` and `lastPlayed` |
| `playlists` | player | Id, name, description, track IDs as JSON, timestamps, `is_server` (a cached copy of a server playlist) |
| `settings` | both | Key/value pairs (below) |
| `users` | server | Accounts: id, unique case-insensitive user name, bcrypt hash, admin flag, timestamps |
| `user_favorites` | server | `(user_id, track_id)` and when it was added |
| `user_plays` | server | `(user_id, track_id)`, play count, last played |
| `user_playlists` | server | `(user_id, id)`, name, description, track IDs as JSON, timestamps |

`settings` keys: `LibraryPath` (folder the index was scanned from), `LibrarySource` (`None`, `Server`, `Local` or
`Hybrid`), `ServerUrl`, `AuthToken` (only when kept signed in), `ServerUserData` (whether the server stores
per-account data), `ServerUserDataImported` (set once the device's old local data has been handed over, or found to
be empty: `{ServerUrl}|{UserId}` of the account that received it), `Preference.Language`, `Preference.Theme`,
`Preference.ShowPerformanceStats`, `Preference.OnlineLyrics` (player); `jwt_secret` (64 random bytes, Base64, created
on first start) and `library_path` (folder chosen through the API) (server).

The data directory is resolved by `AppPaths.getDataDirectory`: explicit setting, else `WIRETUNE_DATA_DIR`, else
`AppPaths.platformDataRoot`, else `<application data>/Wiretune` (`~/.config` or `$XDG_CONFIG_HOME` on Linux,
`%APPDATA%` on Windows, `~/Library/Application Support` on macOS); the server adds a `Server` subfolder unless
`Wiretune:DataDirectory` is set. On Android, iOS and Tizen `main()` sets `platformDataRoot` to the app's private
support folder first thing (on Android the same `files` folder the C# app used).

## Player and server

`ServerSession` is the player's connection state machine (`ServerConnectionState`: `notConfigured`, `connecting`,
`offline`, `setupRequired`, `loginRequired`, `connected`) and owner of the library source. Every failure becomes a
state with a message the UI can show; fire-and-forget commands never throw. Messages are stored as key plus arguments
and rendered on demand, so they follow language changes.

`ServerStreamingClient` wraps `package:http` with timeouts (15 s for the first probe, 30 s for normal calls, 3 minutes
for the library download, 2 minutes for the one-time import). Connecting probes `/api/auth/setup-required`; with a
stored token it loads `/api/auth/me`, `/api/tracks` and `/api/me/data` and merges the result. The whole track list is
fetched on every refresh; there is no incremental sync. A token is sent only to the address it was issued for
(changing the address forgets it), and stream URLs stored in tracks carry no credential: the engine appends `?token=`
only when it hands a source to a driver, and then a short-lived **stream token** from `ServerSession.getStreamToken`
(`/api/auth/stream-token`), never the sign-in token. A server that does not know that route is answered with the
sign-in token instead. `WiretuneLog` blanks `token=` values in every line, because those URLs end up in driver
messages.

Per-account data flows through `ServerSession`. Changes the user makes to server tracks and their playlists are
queued and sent in order by one background loop (`PUT/DELETE /api/me/favorites/{id}`, `POST /api/me/plays/{id}`,
`PUT/DELETE /api/me/playlists/{id}`). Before a refresh and before a sign-out the queue is flushed first
(`flushUserData`), so the download cannot undo what was just changed. A favourite the server did not take is put back;
a play or a playlist edit that failed is not retried (the next refresh shows what the server has). A server that
answers `400`, `409` or `413` can be reached and has only said no (an invalid value, an account limit), so the session
stays connected; any other failure turns it `offline` as for every server call. The first account that signs in on a
device receives, once, whatever the device already held for server tracks (`/api/me/data/import`, cut to the server's
limits first so that one bad playlist cannot make the server turn down the rest); an account that signs in later does
not, because by then what the device shows is a copy of someone's server data. A server that answers `404` for
`/api/me/data` is treated as an older server and `userDataMode` stays `local`.

`WiretuneServer.start` (`server/lib/src/server.dart`) wires the server: configuration (`ServerOptions`), data
directory, logging, `DatabaseManager`, `LibraryService`, `AuthService`, `UserDataService`, `SetupCode`,
`LibraryScanService` (a loop that waits for a request or the scan interval, whichever comes first, so it runs at
start-up, on schedule and on request), the routes table ([api.md](api.md)) with each route's access level
(anonymous, user, admin, media) and body limit, the sign-in rate limiter, and gzip for JSON answers. A method the
route does not take answers `405`, an unknown path `404`. Library routes answer with records that carry no absolute
paths.

- `UserDataService`: the favourites, play counts and playlists of each account (`user_*` tables). Every method takes
  the account ID from the validated token, so no route can address another account's rows; the limits are in
  `UserDataRules` and are enforced in the SQL of the insert, so two parallel requests cannot go past them. Writes
  go to the database when they are made, which is why none of it is lost on a restart.
- `SetupCode`: the secret that lets the first caller create the administrator; random per start unless
  `Wiretune:SetupCode` is set. The comparison is constant-time.
- `AuthService`: bcrypt (work factor 12, run in an isolate so a sign-in does not stall other requests), a dummy-hash
  check for unknown users to even out timing, HMAC-SHA256 JWTs (`jwt.dart`; issuer `WiretuneServer`, audience
  `WiretuneClient`, 2 minutes clock skew, the .NET claim names so C# tokens validate), first-admin creation as one
  atomic `INSERT … WHERE NOT EXISTS`. Every validated token is checked against the `users` table, so deleted accounts
  lose access immediately, and `?token=` is honoured only on `/api/stream` and `/api/cover`. A **stream token** carries
  a `scope=stream` claim and is rejected everywhere except those two routes.
- Streaming answers range requests (`206`) after checking that the file lies inside the library root (by whole path
  segments, so `/music2` is not inside `/music`).

## Audio

`WiretuneAudioEngine` holds the current track, device list, mode flags and volume and talks to one `AudioDriver`
(`packages/wiretune_core/lib/src/audio/audio_driver.dart`). The app picks the driver at start-up: `MediaKitAudioDriver`
(libmpv) on every platform except Tizen, `TizenAudioDriver` (the TV's media player, through `audioplayers_tizen`) there.
Drivers keep a *playback generation* counter so late callbacks from a replaced source are ignored. Details per platform:
[audio.md](audio.md).

Around the engine, the app adds the platform's side of playing music:

- `MobileAudio` (Android, iOS): audio focus through `audio_session` (a call pauses, a navigation prompt ducks,
  unplugged headphones pause) and, on Android, the CPU and Wi-Fi locks of the `wiretune_platform` plugin while
  playing.
- `WiretuneMediaSession` (Android, iOS, macOS, Linux): an `audio_service` handler that mirrors the player into the
  system's media controls (notification, lock screen, Control Center, MPRIS) and takes commands from them. On Android
  it is also the `MediaBrowserService` that Android Auto browses: the root offers albums, artists, playlists and
  favourites, and playing an item makes its list the queue, as a click in the app does.

## UI

Flutter, with `ChangeNotifier` view models and no state-management package. `main()` builds a `MainViewModel`,
which owns the audio engine, the library, the server session and one view model per area (player, tracks, albums,
artists, playlists, favourites, search, audio settings, server settings). `AppScope` (an `InheritedWidget`) hands it
to the widgets as `context.vm`.

- **Layouts.** `WiretuneApp` (`app.dart`) chooses one of two layouts over the same view models: `WideLayout` (header
  with search and the mode pills, sidebar, the page, player bar, status line) for desktops, tablets and every TV, and
  `PhoneLayout` (top bar, the page, mini player, bottom navigation; search and the full-screen player slide over it)
  below 720 logical pixels or on a phone. Each section is a page widget (`pages/`), the same in both layouts.
- **Navigation** is the `AppSection` enum (`tracks`, `albums`, `artists`, `playlists`, `favorites`, `settings`);
  `MainViewModel.selectedSection` holds it and `navigateTo` changes it. The sign-in screen, the full-screen player and
  the phone's search page are flags on the view model. `MainViewModel.tryNavigateBack()` closes layers and then walks
  the tab history; the system back button (Android, TV remotes) and Escape both go through it,
  and it needs no platform API, so it is unit-tested.
- **TV.** A TV gets the wide layout, focus highlights and a focused first item; the remote's arrows move the focus,
  its centre button activates, and its media keys reach the player through `Shortcuts` in `app.dart`.
- **Theme.** Each section has an accent family (cyan, purple, coral, lime) and a window gradient, defined in
  `theme/palette.dart` for the dark and the light theme; `buildTheme` makes a `ThemeData` from them and the
  `WiretuneColors` theme extension (`context.colors`) carries the rest. Themes are built once per section and reused.
- **Track lists** are slivers (`TrackSliver`), so a library of tens of thousands of tracks scrolls without building
  rows that are off screen; album, artist and playlist grids size their tiles by the cover plus the caption at the
  user's font size.
- **Covers** are decoded at the size they are shown (`CoverImage`), from files or from the server (with the sign-in
  token in a header, never in the URL), into Flutter's image cache (120 MB, 160 MB on a TV).
- **Quality tags.** `AudioFormat.tier` (`QualityTier`: gold = hi-res, silver = lossless, bronze = lossy) and
  `AudioFormat.tagSpec` describe one recording; `QualitySummary.of` reduces the tracks of an album or playlist to
  their lowest tier plus a spec or `MIXED`. The `QualityTag` widget draws the pill the same everywhere in the medal's
  colours, which it owns so they keep their contrast in both themes.
- **Lyrics.** `PlayerViewModel` loads them only while the queue panel or the lyrics page is open: first the
  `LyricsProvider` (the file's tag, or the server's `/api/lyrics`), then, when that is empty and the setting allows,
  `OnlineLyrics.find` (core): LRCLIB's exact-match endpoint, then its search (the same song by title, artist and length
  within 5 s), cached per track in `<data dir>/lyrics/<hash>.json`. A failed lookup throws and is never cached, which
  lets the panel say "could not reach" instead of "no lyrics". Time-synchronised lyrics are parsed by `LrcParser` and
  follow the song.
- `widgets/` holds the reusable parts and the visualisers (`SpectrumVisualizer`, the 32-band analyser;
  `NavVisualizer`, the animated logo).

## Localisation

`packages/wiretune_core/lib/src/localization/strings.dart` holds every text as `'Key': ('hu', 'en', 'de')`. `Localizer`
serves texts to code (`Localizer.get`, `Localizer.format`) and announces a language change; the app's `LanguageScope`
rebuilds the widgets that read texts through `context.tr` and `context.trf`. How to add texts or a language:
[development.md](development.md#add-or-change-texts-and-languages). The language is English until the user picks another
one and is remembered in `Preference.Language`; the system language is not read.
