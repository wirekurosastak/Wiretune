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
| `Wiretune.Server` | ASP.NET Core minimal API: JWT authentication, background library scan |
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
- **Albums** are keyed by album title plus album artist (track artist when untagged), case-insensitively. Before
  grouping, tracks in one folder with the same album title and no clashing numbers are consolidated onto a single
  album artist (explicit tag, else majority artist, else *Various Artists*). **Artists** are the album artists.
- **Hybrid library**: tracks from a local scan have no `StreamUrl`, tracks from a server do.
  `TrackDeduplication.MergeTracks` drops a server track that duplicates a local one, merges its favourite flag, play
  count, last-played time and (if missing) cover into the local track, and rewrites playlist entries that pointed
  at the server copy. The duplicate rules are in the [user guide](user-guide.md#server-and-local-music-together).
- **Persistence**: any change to the track list replaces the `tracks` table in one transaction.
  `IsFavorite`, `PlayCount`, `LastPlayed` and `DateAdded` are copied over by track ID, so they survive a rescan.
  Favourites, play counts and playlists are written to the player's database only; the server never changes them.

## Persistence

SQLite in WAL mode (`busy_timeout` 5 s, `synchronous = NORMAL`). The schema version is `PRAGMA user_version`
(currently 2; version 2 added `tracks.file_modified_utc`). Both sides create all four tables, but the server does
not use `playlists` and the player does not use `users`.

| Table | Content |
|---|---|
| `tracks` | The library index |
| `playlists` | Id, name, description, track IDs as JSON, timestamps |
| `settings` | Key/value pairs (below) |
| `users` | Accounts: id, unique case-insensitive user name, bcrypt hash, admin flag, timestamps |

`settings` keys: `LibraryPath` (folder the index was scanned from), `LibrarySource` (`None`, `Server`, `Local` or
`Hybrid`), `ServerUrl`, `AuthToken` (only when kept signed in), `Preference.Language`, `Preference.Theme`,
`Preference.ShowPerformanceStats` (player); `jwt_secret` (64 random bytes, Base64, generated on first start) and
`library_path` (folder chosen through the API) (server).

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
with a stored token it loads `/api/auth/me` and `/api/tracks` and merges the result. The whole track list is
fetched on every refresh; there is no incremental sync. A token is sent only to the address it was issued for
(changing the address forgets it), and stream URLs stored in tracks carry no credential: the engine appends
`?token=` only when it hands a source to a player.

`Wiretune.Server/Program.cs` wires everything: configuration, data directory, logging, `DatabaseManager`,
`LibraryService`, `AuthService`, `LibraryScanService` (a `BackgroundService` that waits on a semaphore with the
scan interval as timeout, so it runs at start-up, on schedule and on request), JWT bearer authentication, the
`admin` policy, the sign-in rate limiter, response compression and the routes ([api.md](api.md)).

- `AuthService`: bcrypt (work factor 12), a dummy-hash check for unknown users to even out timing, HMAC-SHA256
  JWTs (issuer `WiretuneServer`, audience `WiretuneClient`, 2 minutes clock skew), first-admin creation as one atomic
  `INSERT … WHERE NOT EXISTS`. Every validated token is checked against the `users` table, so deleted accounts lose
  access immediately, and `?token=` is honoured only on `/api/stream` and `/api/cover`.
- Streaming uses `Results.File(…, enableRangeProcessing: true)` after checking that the file lies inside the
  library root (by whole path segments, so `/music2` is not inside `/music`).

## Audio

`WiretuneAudioEngine` holds the current track, device list, mode flags and volume and talks to one `IAudioDriver`:
`FfmpegAudioDriver` unless Windows, and on Android the head supplies its own through `App.AudioDriverFactory`.
Drivers keep a *playback generation* counter so late callbacks from a replaced player (process exit, slow source
open) are ignored.

## UI

Avalonia 11 with compiled bindings and MVVM through CommunityToolkit.Mvvm. `App` builds a `MainViewModel`, which
owns the theme, the audio engine, the library, the server session and one view model per area (player, tracks,
albums, artists, playlists, favourites, search, audio settings, server settings). The desktop window
(`MainWindow`/`MainView`) and the phone layout (`AndroidMainView`) are separate views over the same view models.

- Navigation is an index (0 Tracks, 1 Albums, 2 Artists, 3 Playlists, 4 Favorites, 5 Settings). The sign-in screen
  is a full-view layer (`IsLoginViewActive`). The phone layout adds a full-screen player, a search page and a back
  stack (`TryNavigateBack`) that closes layers and then walks the tab history; it needs no Android API and is
  unit-tested.
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
user picks another one and is remembered in `Preference.Language`; `Localizer.DetectSystemLanguage()` exists but is
not called at start-up.
