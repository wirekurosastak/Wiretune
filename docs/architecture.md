# Architecture

How the code is organised. What each part does for the user is in [user-guide.md](user-guide.md) and
[server.md](server.md); the audio path is in [audio.md](audio.md).

## Projects

```
Wiretune.Desktop ──► Wiretune.UI ──► Wiretune.Core ◄── Wiretune.Server
Wiretune.Android ──►
Wiretune.Tests references Core, UI and Server
```

| Project | Role |
|---|---|
| `Wiretune.Core` | Everything shared: models, SQLite persistence, tag scanner, library service, audio engine and drivers, localisation, server session and HTTP client |
| `Wiretune.Server` | ASP.NET Core minimal API: JWT authentication, per-account favourites, play counts and playlists, background library scan |
| `Wiretune.UI` | Avalonia views, view models, controls and services; one `App` for desktop and Android |
| `Wiretune.Desktop` | Entry point for Linux and Windows |
| `Wiretune.Android` | Entry point for Android: activity, `MediaPlayer` driver, foreground service. Not part of the solution build (needs the Android workload) |
| `Wiretune.Tests` | xUnit tests |

Everything targets .NET 10. Main libraries: TagLibSharp (tags), Microsoft.Data.Sqlite with Dapper (persistence),
NAudio.Wasapi (Windows audio), Avalonia 11 with CommunityToolkit.Mvvm (UI), BCrypt.Net-Next and
`Microsoft.AspNetCore.Authentication.JwtBearer` (server). Versions are in the `.csproj` files.

The server and the players share `LibraryService`, `MetadataScanner` and `DatabaseManager`: a server is, in
effect, a headless player that scans a folder and exposes the index over HTTP.

## Library model

`LibraryService` keeps the whole library in memory as an **immutable snapshot** (tracks, albums, artists, genres)
that is replaced wholesale after every change, so readers never lock. Changes are serialised: one scan at a time,
and local scans and server merges pass through a commit gate so neither works on a stale view.

- **Tracks** come from `MetadataScanner`. The ID is the first 32 hex characters of the SHA-256 of the lower-cased
  full path. The scan runs on 2–8 threads and reuses an entry when path, size and modification time are unchanged.
- **Albums** are keyed by album title plus album artist (track artist when untagged), case-insensitively; the key
  is `Track.AlbumId`, which the server's cover route and the player's cover URLs share. Before grouping, tracks in
  one folder with the same album title and no clashing numbers are consolidated onto a single album artist (explicit
  tag, else majority artist, else *Various Artists*). That inferred value is only ever shown: `Track.AlbumArtistInferred`
  marks it and the database keeps what the tags say, so it cannot outlive the files it was inferred from.
  **Artists** are the album artists.
- **Hybrid library**: tracks from a local scan have no `StreamUrl`, tracks from a server do.
  `TrackDeduplication.MergeTracks` drops a server track that duplicates a local one, merges its favourite flag, play
  count, last-played time and (if missing) cover into the local track, and rewrites playlist entries that pointed
  at the server copy. The duplicate rules are in the [user guide](user-guide.md#server-and-local-music-together).
- **Persistence**: a change to the track list is written to the `tracks` table in one transaction as a difference:
  rows that are gone are deleted, new rows inserted and changed rows updated, and a row that is identical is not
  written at all. `IsFavorite`, `PlayCount`, `LastPlayed` and `DateAdded` are carried over by track ID, so they
  survive a rescan.
- **Who owns the user data.** `LibraryService.UserDataMode` says where the favourites, play counts and playlists of
  *server* tracks live: `Server` (signed in to a server that stores them), `ServerUnavailable` (such a server, but
  not connected: server tracks and their playlists are read-only) or `Local` (no server, or one that predates
  per-account data). Tracks from a local folder always keep theirs on the device. In `Server` mode a change is applied
  to the in-memory snapshot and the player's database at once, so the screen answers immediately, and handed to
  `ServerSession`, which sends it to the server in order. The player's copy is a cache for offline display; on every
  refresh the server's data replaces it.

## Persistence

SQLite in WAL mode (`busy_timeout` 5 s, `synchronous = NORMAL`). The schema version is `PRAGMA user_version`
(currently 4) and every start upgrades an older database in place, in one transaction: version 2 added
`tracks.file_modified_utc`, version 3 the per-account tables and `playlists.is_server`, version 4 makes the next scan
of local files read their tags again (album artists that were inferred used to be stored as if tagged). Both sides
create every table through the same `DatabaseManager`; each uses the ones it needs.

| Table | Used by | Content |
|---|---|---|
| `tracks` | both | The library index; in the player also the cached `IsFavorite`, `PlayCount` and `LastPlayed` |
| `playlists` | player | Id, name, description, track IDs as JSON, timestamps, `is_server` (a cached copy of a server playlist) |
| `settings` | both | Key/value pairs (below) |
| `users` | server | Accounts: id, unique case-insensitive user name, bcrypt hash, admin flag, timestamps |
| `user_favorites` | server | `(user_id, track_id)` and when it was added |
| `user_plays` | server | `(user_id, track_id)`, play count, last played |
| `user_playlists` | server | `(user_id, id)`, name, description, track IDs as JSON, timestamps |

`settings` keys: `LibraryPath` (folder the index was scanned from), `LibrarySource` (`None`, `Server`, `Local` or
`Hybrid`), `ServerUrl`, `AuthToken` (only when kept signed in), `ServerUserData` (whether the server stores
per-account data), `ServerUserDataImported` (set once the device's old local data has been handed over, or found to
be empty: `{ServerUrl}|{UserId}` of the account that received it), `Preference.Language`, `Preference.Theme`, `Preference.ShowPerformanceStats` (player); `jwt_secret` (64
random bytes, Base64, created on first start) and `library_path` (folder chosen through the API) (server).

The data directory is resolved by `AppPaths.GetDataDirectory`: explicit setting, else `WIRETUNE_DATA_DIR`, else
`<ApplicationData>/Wiretune`; the server adds a `Server` subfolder unless `Wiretune:DataDirectory` is set. On
Android, `MainActivity` sets `WIRETUNE_DATA_DIR` to the app's private files folder first thing.

## Player and server

`ServerSession` is the player's connection state machine (`NotConfigured`, `Connecting`, `Offline`,
`SetupRequired`, `LoginRequired`, `Connected`) and owner of the library source. Every failure becomes a state with a
message the UI can show; fire-and-forget commands never throw. Messages are stored as key plus arguments and
rendered on demand, so they follow language changes.

`ServerStreamingClient` is a typed `HttpClient` wrapper with timeouts (15 s for the first probe, 30 s for normal
calls, 3 minutes for the library download) and gzip/deflate/brotli. Connecting probes `/api/auth/setup-required`;
with a stored token it loads `/api/auth/me`, `/api/tracks` and `/api/me/data` and merges the result. The whole track
list is fetched on every refresh; there is no incremental sync. A token is sent only to the address it was issued for
(changing the address forgets it), and stream URLs stored in tracks carry no credential: the engine appends
`?token=` only when it hands a source to a player, and then a short-lived **stream token** from
`ServerSession.GetStreamTokenAsync` (`/api/auth/stream-token`), never the sign-in token. A server that does not know
that route is answered with the sign-in token instead. `WiretuneLog` blanks `token=` values in every line, because
those URLs end up in driver messages.

Per-account data flows through `ServerSession`. Changes the user makes to server tracks and their playlists are
queued and sent in order by one background loop (`PUT/DELETE /api/me/favorites/{id}`, `POST /api/me/plays/{id}`,
`PUT/DELETE /api/me/playlists/{id}`). Before a refresh and before a sign-out the queue is flushed first, so the
download cannot undo what was just changed. A favourite the server did not take is put back; a play or a playlist
edit that failed is not retried (the next refresh shows what the server has). A server that answers `400`, `409` or
`413` can be reached and has only said no (an invalid value, an account limit), so the session stays connected; any
other failure turns it `Offline` as for every server call. The first account that signs in on a device receives, once,
whatever the device already held for server tracks (`/api/me/data/import`, cut to the server's limits first so that one
bad playlist cannot make the server turn down the rest); an account that signs in later does not, because by then what
the device shows is a copy of someone's server data. A server that answers `404` for `/api/me/data` is treated as an
older server and `UserDataMode` stays `Local`.

`Wiretune.Server/Program.cs` wires everything: configuration, data directory, logging, `DatabaseManager`,
`LibraryService`, `AuthService`, `UserDataService`, `SetupCode`, `LibraryScanService` (a `BackgroundService` that
waits on a semaphore with the scan interval as timeout, so it runs at start-up, on schedule and on request), JWT bearer
authentication, the `admin` policy, the sign-in rate limiter, response compression and the routes ([api.md](api.md)).
Library routes answer with the `Server*Dto` records in `ServerDtos.cs`, which carry no absolute paths.

- `UserDataService`: the favourites, play counts and playlists of each account (`user_*` tables). Every method takes
  the account ID from the validated token, so no route can address another account's rows; the limits are in
  `UserDataRules` and are enforced in the SQL of the insert, so two parallel requests cannot go past them. Writes
  go to the database when they are made, which is why none of it is lost on a restart.
- `SetupCode`: the secret that lets the first caller create the administrator; random per start unless
  `Wiretune:SetupCode` is set. The comparison is constant-time.

- `AuthService`: bcrypt (work factor 12), a dummy-hash check for unknown users to even out timing, HMAC-SHA256
  JWTs (issuer `WiretuneServer`, audience `WiretuneClient`, 2 minutes clock skew), first-admin creation as one atomic
  `INSERT … WHERE NOT EXISTS`. Every validated token is checked against the `users` table, so deleted accounts lose
  access immediately, and `?token=` is honoured only on `/api/stream` and `/api/cover`. A **stream token** carries a
  `scope=stream` claim and is rejected everywhere except those two routes.
- Streaming uses `Results.File(…, enableRangeProcessing: true)` after checking that the file lies inside the
  library root (by whole path segments, so `/music2` is not inside `/music`).

## Audio

`WiretuneAudioEngine` holds the current track, device list, mode flags and volume and talks to one `IAudioDriver`:
`FfmpegAudioDriver` unless Windows, and on Android the head supplies its own through `App.AudioDriverFactory`.
Drivers keep a *playback generation* counter so late callbacks from a replaced player (process exit, slow source
open) are ignored. `FfmpegAudioDriver` runs its commands (play, pause, seek, stop) one after the other on its own
queue, so the UI thread that issued one never waits for a process to start or die, and it raises its events only
after releasing its internal lock, so a handler can call back into the driver.

## UI

Avalonia 11 with compiled bindings and MVVM through CommunityToolkit.Mvvm. `App` builds a `MainViewModel`, which
owns the theme, the audio engine, the library, the server session and one view model per area (player, tracks,
albums, artists, playlists, favourites, search, audio settings, server settings). The desktop window
(`MainWindow`/`MainView`) and the phone layout (`AndroidMainView`) are separate views over the same view models.

- **Views.** `MainView` is the frame of the desktop window: header bar, navigation, player bar and the layers on top
  (queue, search results, sign-in). Each section is its own `UserControl` (`TracksView`, `AlbumsView`, `ArtistsView`,
  `PlaylistsView`, `FavoritesView`, `SettingsView`, plus `SearchResultsView`, `QueueView` and `LoginView`) that inherits
  the `MainViewModel` as its `DataContext`. The views have no logic beyond the pointer and drag handlers that need
  the visual tree; `MainView.axaml.cs` holds only the window-chrome handlers.
- **Navigation** is the `AppSection` enum (`Tracks`, `Albums`, `Artists`, `Playlists`, `Favorites`, `Settings`);
  `MainViewModel.SelectedSection` holds it and `NavigateTo(AppSection)` changes it. The sign-in screen is a full-view
  layer (`IsLoginViewActive`). The phone layout adds a full-screen player, a search page and a back stack
  (`TryNavigateBack`) that closes layers and then walks the tab history; it needs no Android API and is unit-tested.
  The UI automation route takes the enum's names (`/api/ui/navigate?section=Albums`).
- **Theme.** Each section has an accent family (cyan, purple, coral, lime) and a window gradient. The colours are
  defined in the two theme dictionaries of `App.axaml` (`CyanAccentColor`, `WindowGradientAlbumsColor`, …) and
  `ThemeService` only picks and applies them for the active section, so a colour is changed in XAML, not in code.
- **Styles per head.** `App.axaml` holds the resources every head needs. The two that depend on the head are added
  in `App.AddHeadStyles()`: the DataGrid theme on desktop (the phone layout has no DataGrid) and `PhoneStyles` on
  Android.
- **Track tables.** The cells that every table shows the same way (artist link, album link, quality badge, favourite
  star, add-to-playlist) are shared `DataTemplate` resources in `App.axaml`, used as
  `CellTemplate="{StaticResource TrackAlbumLinkCell}"`; they reach the `MainViewModel` through the `UserControl` they
  sit in. Cells that differ per table stay in that table.
- `CoverArtService` decodes covers at display size into an LRU cache (300 bitmaps; 6 downloads and 2 decodes at a
  time, off the UI thread; downloads capped at 16 MiB; failed URLs retried after 2 minutes).
- `Controls/` holds the list and grid controls tuned for scrolling large libraries on a phone and the visualisers
  (`SpectrumVisualizerControl`, the 32-band analyser; `NavVisualizerControl`, the animated logo).
- Diagnostics: `RenderingInfo`, `FrameMonitor` and `UiFrameProbe` measure rendering, and the Android head adds
  refresh-rate and performance-hint control (`DisplayPerformance`).

## Localisation

`Strings.cs` holds every text as `T("Key", hu, en, de)`. `Localizer` serves texts to code and XAML through an
indexer whose change notification updates every bound text when the language changes. How to add texts or a
language: [development.md](development.md#add-or-change-texts-and-languages). The language is English until the
user picks another one and is remembered in `Preference.Language`; the system language is not read.
