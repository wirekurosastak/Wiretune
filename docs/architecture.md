# Architecture

How Wiretune is put together. For what each part does for the user, see [user-guide.md](user-guide.md) and
[server.md](server.md); for the audio path, [audio.md](audio.md).

## Projects

```
Wiretune.Desktop ──► Wiretune.UI ──► Wiretune.Core ◄── Wiretune.Server
Wiretune.Android ──►     │                ▲                  ▲
                         └────────────────┴──────────────────┘
Wiretune.Tests references Core, UI and Server
```

| Project | Type | Role |
|---|---|---|
| `Wiretune.Core` | class library | Everything shared: models, SQLite persistence, tag scanner, library service, audio engine and drivers, localisation, server session and HTTP client |
| `Wiretune.Server` | ASP.NET Core web app | Minimal API, JWT authentication, background library scan |
| `Wiretune.UI` | class library | Avalonia views, view models, controls and services; one `App` for desktop and Android |
| `Wiretune.Desktop` | WinExe | Entry point for Linux and Windows: starts logging and Avalonia with the platform's default backend |
| `Wiretune.Android` | `net10.0-android` (API 21+) | Entry point for Android: `MainActivity`, the `MediaPlayer` driver, the foreground service, display-performance helpers. Not part of the solution build (it needs the Android workload) |
| `Wiretune.Tests` | xUnit | See [development.md](development.md#tests) |

All projects target .NET 10 (`global.json` pins SDK 10.0.100 with roll-forward to the latest feature band).
Main third-party libraries: TagLibSharp (tags), Microsoft.Data.Sqlite and Dapper (persistence), NAudio.Wasapi
(Windows audio), Avalonia 11 with CommunityToolkit.Mvvm and Material.Icons.Avalonia (UI), BCrypt.Net-Next and
`Microsoft.AspNetCore.Authentication.JwtBearer` (server). Versions are in the `.csproj` files.

## Wiretune.Core

| Folder | Content |
|---|---|
| `Models/` | `Track`, `Album`, `Artist`, `Playlist`, `AudioFormat`, `AudioOutputDevice`, `PlaybackState`, the auth DTOs and `AuthRules`, `AudioFileTypes` (the single list of indexed extensions, codec labels and MIME types) |
| `Data/` | `DatabaseManager` (connection, schema and migrations) and `LibraryRepository` (Dapper queries) |
| `Services/` | `LibraryService`, `MetadataScanner`, `TrackDeduplication`, `ServerSession`, `ServerStreamingClient`, `ArtistPictureService`, `AppPaths`, `WiretuneLog` |
| `Audio/` | `WiretuneAudioEngine`, `IAudioDriver` with `FfmpegAudioDriver` and `WasapiAudioDriver`, `AudioDeviceManager`, spectrum analysis (`FxSoundSpectrumEngine`, `AudioPcmCache`) |
| `Localization/` | `Localizer` and `Strings` |

The server and the clients use the same `LibraryService`, `MetadataScanner` and `DatabaseManager`. A server
is, in effect, a headless client that scans a folder and exposes the resulting index over HTTP.

## Library model

`LibraryService` keeps the whole library in memory as an **immutable snapshot** (tracks, tracks by ID, albums,
artists, genres) that is replaced wholesale after every change, so readers never take a lock. Changes are
serialised: one scan at a time, and local scans and server merges pass through a commit gate so neither works on
a stale view.

- **Tracks** are read by `MetadataScanner` (TagLibSharp). A track ID is the first 32 hex characters of the
  SHA-256 of the file's lower-cased full path. The scan runs on 2–8 threads (the processor count, clamped) and
  reuses an existing entry when path, size and modification time are unchanged.
- **Albums** are built from tracks: the key is album title plus album artist (the track artist when no album
  artist is tagged), case-insensitively. Before grouping, tracks in the same folder with the same album title and
  no clashing disc/track numbers are consolidated onto one album artist (explicit tag, else the majority artist,
  else *Various Artists*).
- **Artists** are the album artists: the Artists list contains one entry per album artist, with their albums and
  tracks, so performers who only guest on others' albums have no entry of their own.
- **Persistence**: every change to the track list replaces the `tracks` table in one transaction.
  `IsFavorite`, `PlayCount`, `LastPlayed`, `DateAdded` and the "is playing" highlight are copied over by track ID so
  they survive a rescan or a server refresh. Favourites, play counts and playlists are written to the client's
  database only; the server never changes them.
- **Hybrid library**: tracks from a local scan have no `StreamUrl`; tracks fetched from a server do.
  `TrackDeduplication.MergeTracks` combines the two lists. A server track that duplicates a local one is dropped,
  its favourite flag, play count, last-played time and (if the local one has none) cover are merged into the
  local track, and playlist entries that pointed at the server copy are rewritten to the local copy. The rules for
  "duplicate" are in the [user guide](user-guide.md#server-and-local-music-together).
- **Preferences** (language, theme, statistics switch) are stored as `Preference.<name>` rows of the `settings`
  table.

## Persistence

SQLite in WAL mode (`PRAGMA busy_timeout = 5000`, `synchronous = NORMAL`). Schema version is kept in
`PRAGMA user_version` (currently 2; version 2 added `tracks.file_modified_utc`).

| Table | Content |
|---|---|
| `tracks` | The library index (client: local and server tracks; server: the scanned folder) |
| `playlists` | Id, name, description, track IDs as JSON, timestamps (client only in practice) |
| `settings` | Key/value pairs |
| `users` | Server accounts: id, user name (unique, case-insensitive), bcrypt hash, admin flag, timestamps (server only in practice) |

Both sides create all four tables; the server does not use `playlists`, the client does not use `users`.

`settings` keys in use:

| Key | Used by | Meaning |
|---|---|---|
| `LibraryPath` | both | Folder the current index was scanned from |
| `LibrarySource` | client | `None`, `Server`, `Local` or `Hybrid` |
| `ServerUrl`, `AuthToken` | client | Server address and (when "keep me signed in") the access token |
| `Preference.Language`, `Preference.Theme`, `Preference.ShowPerformanceStats` | client | UI preferences |
| `jwt_secret` | server | Token-signing key (64 random bytes, Base64), generated on first start |
| `library_path` | server | Folder chosen through the admin API |

Data directory, resolved by `AppPaths.GetDataDirectory`: explicit setting, else `WIRETUNE_DATA_DIR`, else
`<ApplicationData>/Wiretune`; the server adds a `Server` subfolder unless `Wiretune:DataDirectory` is set.

| Client file | |
|---|---|
| `wiretune.db` | Library index, playlists, settings |
| `Covers/` | Cover images extracted while scanning local folders |
| `artist_pictures.json` | Cache of artist-picture lookups |
| `wiretune.log` | Log |

On Android `MainActivity` sets `WIRETUNE_DATA_DIR` to the app's private files directory before anything else
runs.

## Client–server

`ServerSession` is the client's connection state machine (`NotConfigured`, `Connecting`, `Offline`,
`SetupRequired`, `LoginRequired`, `Connected`) and the owner of the library source (`None`, `Server`, `Local`,
`Hybrid`). Every failure becomes a state with a message the UI can show; fire-and-forget commands never throw.
Status messages are stored as a key plus arguments and rendered on demand, so they follow language changes.

`ServerStreamingClient` is a thin typed `HttpClient` wrapper with per-request timeouts (15 s for the first
reachability probe, 30 s for normal calls, 3 minutes for the library download) and gzip/deflate/brotli
decompression. Connecting works like this: probe `/api/auth/setup-required`; if a token is stored, load `/api/auth/me`
and download `/api/tracks`; merge the result into the library. The whole track list is fetched on every refresh;
there is no incremental sync.

Token handling:

- A token is only ever sent to the server address it was issued for: changing the address forgets it.
- API calls send `Authorization: Bearer`. Stream URLs stored in tracks carry no credential; the engine appends
  `?token=` only when it hands a source to a player. The Linux driver replaces the token with `***` in its log
  lines; the Windows driver does not (see [../SECURITY.md](../SECURITY.md)).
- `CoverArtService` sends the bearer token only to the configured server URL.

## Server

`Wiretune.Server/Program.cs` wires everything: configuration, data directory and logging, `DatabaseManager`,
`LibraryService`, `AuthService`, `LibraryScanService` (a `BackgroundService`), JWT bearer authentication,
the `admin` policy, a fixed-window rate limiter for sign-in, response compression, a 64 KiB request body limit,
and the minimal-API routes (see [api.md](api.md)).

- `AuthService`: bcrypt (work factor 12), a dummy hash check for unknown users to even out response times,
  HMAC-SHA256 JWTs (issuer `WiretuneServer`, audience `WiretuneClient`, 2 minutes clock skew), first-admin
  creation as a single atomic `INSERT … WHERE NOT EXISTS`.
- JWT events: `?token=` is honoured only on `/api/stream` and `/api/cover`; every validated token is checked
  against the `users` table so deleted accounts lose access immediately.
- `LibraryScanService`: waits on a semaphore with the configured interval as timeout, so it scans at start-up, on
  schedule and on request, and guards against an unmounted share.
- Streaming uses `Results.File(..., enableRangeProcessing: true)` after checking that the file lies inside the
  library root (whole path segments, so `/music2` is not inside `/music`).

## Audio

`WiretuneAudioEngine` holds the current track, device list, mode flags and volume, and talks to one `IAudioDriver`
(`FfmpegAudioDriver` unless Windows; the Android head sets `App.AudioDriverFactory` to supply its own).
It raises events for state, position, track, mode, devices, spectrum and failures. Drivers keep a *playback
generation* counter so late callbacks from a replaced player (process exit, slow source open) are ignored.
Everything platform-specific is in [audio.md](audio.md).

## UI

Avalonia 11 with compiled bindings and the Fluent theme, MVVM through CommunityToolkit.Mvvm.

- `App` builds a `MainViewModel` (`MainViewModel.CreateDefault`) and shows `MainWindow` (hosting `MainView`) on
  desktop lifetimes or `AndroidMainView` on single-view lifetimes (Android).
- `MainViewModel` owns `ThemeService`, `WiretuneAudioEngine`, `LibraryService`, `ServerSession` and one view
  model per area: `PlayerViewModel` (queue, shuffle, repeat, lyrics, volume, spectrum), `TracksViewModel`,
  `AlbumsViewModel`, `ArtistsViewModel`, `PlaylistsViewModel`, `FavoritesViewModel`, `SearchResultsViewModel`,
  `AudiophileSettingsViewModel`, `ServerSettingsViewModel`.
- Navigation is an index: 0 Tracks, 1 Albums, 2 Artists (the start page), 3 Playlists, 4 Favorites, 5 Settings.
  Detail pages (album, artist, playlist) open within their tab. The sign-in screen is a separate full-view layer
  (`IsLoginViewActive`): it is shown when no library source is configured yet or the server needs a sign-in, and
  can be opened again from the account button. The phone layout adds a full-screen player, a search page and a back
  stack (`TryNavigateBack`) that closes layers and then walks the tab history; that logic needs no Android API and is
  covered by `PhoneNavigationTests`.
- Desktop and phone layouts are two separate views (`MainView.axaml`, `AndroidMainView.axaml`) over the same
  view models; the desktop view switches to icon-only navigation under 1000 pixels width.
- `Controls/` holds list and grid controls tuned for scrolling large libraries on a phone (`RecyclingList`,
  `TileGrid`, `SmoothFling`, `CoverImage`, `SquareBorder`, `RowPressSync`, `TrackRowView`, `PhoneHeader`), the
  visualisers (`FxVisualizerControl`, the 32-band analyser; `NavVisualizerControl`, the 8-band animated logo;
  `EqualizerBars`, the "now playing" indicator) and the statistics `FrameGraph`.
- `CoverArtService` loads covers from files or the server, decoded at display size, in an LRU cache of at most
  300 bitmaps; downloads (6 at a time) and decoding (2 at a time) run off the UI thread, requests nobody waits for
  any more are dropped, downloads are capped at 16 MiB and failed URLs are retried after two minutes.
- `Ui.Post` / `Ui.Forget` marshal to the UI thread and log failures of fire-and-forget tasks.
- Diagnostics: `RenderingInfo` reports whether Avalonia draws with the GPU, `FrameMonitor` and `UiFrameProbe` measure
  frames, and the Android head adds refresh-rate and CPU performance-hint control (`DisplayPerformance`). The phone
  settings page can overlay these statistics.
- `UiAutomationServer` is a development aid; see [development.md](development.md#ui-automation-endpoint-desktop-development-only).

## Localisation

`Strings.cs` holds every text as `T("Key", hu, en, de)`. `Localizer` is a singleton that serves texts to code
(`Localizer.Get`, `Localizer.Format`) and to XAML (`{loc:T Key}`, `{loc:TFormat Key, Path=…}`) through an indexer
whose change notification updates every bound text when the language changes. A key with a `_One` variant is
used when the first format argument is exactly `1`. Texts computed once in a view model (status lines, badges)
are rebuilt in `RefreshLocalizedTexts()`. Data such as the placeholder artist `Unknown artist` is not interface text and
is not translated. The language is English until the user picks another one; it is remembered in `Preference.Language`.
`Localizer.DetectSystemLanguage()` exists and is tested but is not called at start-up. The localisation tests
enforce that every key has all three texts, that placeholders match across languages, that keys are PascalCase,
that every key used in code or XAML exists and that every key is used.

## Logging

`WiretuneLog` writes `[time] [LEVEL] [category] message` lines to the data directory (`wiretune.log` for
clients, `wiretune-server.log` for the server) at `Debug` level by default. At 10 MiB the file is moved to `.1`
(one backup). Exceptions are logged with their full stack trace. Child-process command lines are logged with
tokens replaced by `token=***`.
