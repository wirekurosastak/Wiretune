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
change, so readers never see half a library and never take a lock. One scan runs at a time. The database calls are
synchronous (SQLite answers at once), so a scan's commit and a server refresh can't interleave.

- **Track IDs** are the first 32 hex digits of the SHA-256 of the full path (lower-cased on Windows and macOS, whose
  file systems ignore case). Scans read in batches on 2 to 8 isolates and skip files whose path, size and modification
  time haven't changed.
- **Albums** are keyed by title plus album artist (`Track.albumId`, shared with the server's cover route). A track's
  tags (`Track.tagged`) never change and are what's stored; where the library files it (`Track.filed`) is worked out
  from them at every `LibrarySnapshot.build`, so it can't outlive the files it came from. A folder of tracks with one
  album title gets one inferred album artist, and a folder inside the music folder whose songs share one artist but
  carry several album tags (an "essentials" put together by hand) becomes one album.
- **Artists of a track**: `Track.artists` holds each one when the tags name several (repeated Vorbis `ARTIST`, `ARTISTS`,
  NUL-separated ID3v2.4 and APE values), and `Track.artist` joins them for display. Names are never split at `&`, `,`
  or `/`. Albums file under the main (first) artist; an artist's page also holds the songs they're featured on.
- **Hybrid**: local tracks have no `streamUrl`, server tracks do. `TrackDeduplication.mergeTracks` folds a server
  duplicate into the local copy, and the library moves its favourite, play count and playlist entries along.
- **Favourites and play counts** are the library's, by track ID (`LibraryService.isFavorite`, `playCount`), not fields
  of a `Track`: a refresh replaces the tracks without anything to copy across, and "is playing" is the player's current
  track ID (`PlayerViewModel.isCurrent`).
- **Writes are diffs**: one transaction per change, and rows that didn't change aren't touched.
- **User data** of server tracks lives on the server account. While signed in (`LibraryService.serverConnected`), a
  change lands locally at once and `ServerSession` sends it on; while not, server tracks and server playlists are
  read-only. The player's copy is a cache that every refresh overwrites. Hidden artists, albums and tracks work the same
  way: the account's (cached under its ID, so they also apply when the app starts offline) change only while signed
  in; without an account the device keeps its own.

The services talk through synchronous `Event<T>`s: a handler has run by the time `emit` returns.

## Persistence

SQLite in WAL mode, one synchronous connection per database, instants stored as microseconds since the epoch. The
schema version is `PRAGMA user_version` (5). A database of an earlier version runs the upgrade steps after its own
(`DatabaseManager._upgrades`, one per version) in one transaction; a newer one, or tables without a version, is refused
(`IncompatibleDatabaseException`) rather than misread. A change to the tables raises the version and appends its step.
Both sides create every table and use what they need:

| Table | Used by | Holds |
|---|---|---|
| `tracks` | both | The index; in the player also the cached favourites (and when each was marked) and play counts |
| `playlists` | player | Playlists; `is_server` marks a cached server one |
| `settings` | both | Key/value pairs: the player's server address, token and preferences; the server's `jwt_secret` and music folder |
| `users` | server | Accounts, with bcrypt hashes and the token version a password change raises |
| `user_favorites`, `user_plays`, `user_playlists`, `user_hidden` | both | On the server each account's data; the player keeps its hidden items there too, its own (`local`) and a copy of the signed-in account's |
| `downloads` | player | Which file in the downloads folder is the copy of which server track, and of which version of its file |

## Player and server

`ServerSession` is the player's connection state machine: `notConfigured`, `connecting`, `offline`, `setupRequired`,
`loginRequired`, `connected`. Every failure becomes a state with a message the UI can show, and its commands never
throw. Connecting probes `/api/auth/setup-required`, then loads `/api/auth/me`, all of `/api/tracks` (there's no
incremental sync) and `/api/me/data`.

The sign-in token only ever goes to the address that issued it, and it is stored with the account's ID (`auth_user_id`).
Stream URLs are stored without credentials: the engine appends a short-lived stream token at the moment it hands one
to a driver, and `WiretuneLog` blanks every `token=` anyway. A password change swaps in the token the server answers
with; a `401` for a token that has been replaced meanwhile doesn't sign the session out.

Changes to the account's data go through one ordered queue, flushed before every refresh and sign-out so that a
download can't undo them. A favourite the server refused is put back; a failed play or playlist edit isn't retried.
`400`, `409` and `413` mean "reachable, but no" and keep the session connected; anything else marks it offline. Every
error answer carries a code (`ErrorCodes`), which `describeServerError` turns into a sentence in the user's language;
a `401` says why the token stopped working, and the session shows that.

**Downloads** (`DownloadService`): what the user marked (tracks, albums, artists, playlists, the favourites) is a
preference, and the tracks it covers are worked out again from the library after every change, so a playlist that grows
grows on the device too. With sync off, a mark adds only what it covers when it is made (kept as `pending` until it
arrives), and nothing else is fetched on its own. One file at a time comes from `/api/stream` with the sign-in token in
the header, into the app's own `DownloadCache/partial` (an interrupted one continues with a range request), and is
moved into the downloads folder once it is complete and as long as the listing says: `Wiretune` in the music folder
(`AppPaths.musicFolder`, the XDG one on Linux; on Android the folder the plugin names, which needs no permission),
`Downloads` in the app's data on iOS and Tizen. Copies are named after the tags (`Album artist/Album/01 - Title.flac`,
`DownloadService.safeFileName`), and the `downloads` table records which file is which track's copy and of which
version of the server's file (size and modification time): two tracks with one name get two files, a file that isn't
a copy is never taken for one or overwritten, a move cut short by the app's end is noticed (the record says "moving"),
and a copy of a changed file is replaced in place once the new one is there. Copies named by hashes, from earlier
versions, are moved into place. The engine plays a copy instead of the stream (and asks for no stream token, which might
hang without a server); covers (in `DownloadCache/covers`) and lyrics come from copies too.

**Remote control** (`RemoteClient`): while signed in, one WebSocket to `/api/remote`, reconnected with a growing pause
and given up on a refusal until the sign-in changes. `PlayerViewModel` tells the others its state at every change and
at a position jump (never as a track plays on), carries out their commands on its own player, and in remote mode shows
another device instead: its track (this library's copy, for the cover and lyrics), its queue as far as the library
knows it, and its position counted on once a second; every command then goes there, and this device's playback carries
on underneath, untouched.

The same connection keeps the account's data in step: when the server stores a favourite, a playlist or a hidden item,
it says `dataChanged` to the account's other players (each names itself in an `X-Wiretune-Device` header), and so does
the client to itself after a reconnection. `ServerSession.refreshUserData` then downloads only `/api/me/data` and merges
it into the track list it downloaded last, unless a change made here meanwhile is still on its way (its own
announcement brings the next refresh). With remote control switched off, the data follows at the next connection.

## Server

`WiretuneServer.start` wires the options (`ServerOptions`: command-line flags, each also a `WIRETUNE_*` variable),
the database, the library, `AuthService`, `UserDataService`, `SetupCode` and `LibraryScanService` to a routes table,
where every route declares its access level (anonymous, user, admin, media) and its body limit.

- **Auth**: bcrypt (cost 12) in an isolate, a dummy hash for unknown names so the timing gives nothing away,
  HMAC-SHA256 JWTs (`sub`, `name`, `ver`, and an `aud` that tells a sign-in token from a stream token), and
  first-admin creation as one atomic `INSERT … WHERE NOT EXISTS`. Every token is checked against `users`
  (`AuthService.authenticate`): deleting an account locks it out at once, a token whose `ver` isn't the account's
  `token_version` (which a password change or reset raises) is refused, and the role and name are the account's present
  ones. A stream token opens only the media routes, and it's the only kind `?token=` takes.
- **User data**: every method takes the account from the token, so no route can reach another account's rows, and the
  limits are part of each insert's SQL, so parallel requests can't sneak past them.
- **Scanning**: a loop that wakes for a request or the interval. Stopping the server cancels a running scan.
- **Streaming** checks that the file lies inside the library root by whole path segments (`/music2` isn't inside
  `/music`) before it serves a byte.
- **Remote control**: `/api/remote` upgrades by hand to `dart:io`'s `WebSocket`, and `RemoteHub` keeps each account's
  connections, passes states and commands between them only (and tells them when the account's data changed), and
  stores nothing. A connection ends when its token
  expires or its account is deleted.

## Audio

`WiretuneAudioEngine` (core) owns the track, devices, modes and volume, and drives one `AudioDriver`:
`MediaKitAudioDriver` (libmpv) everywhere but Tizen, `TizenAudioDriver` there. A *playback generation* counter makes
the drivers ignore late callbacks from a source that has since been replaced, and the engine doesn't start a track
whose stream token arrived after another track was asked for. A device that disappears takes exclusive and bit-perfect
with it. On Linux the ALSA card for exclusive playback is claimed through `ExclusiveCardHolder`, which carries out claims
and releases one at a time, so overlapping output changes can't leave a claim behind; the card goes back when playback
stops, ends or fails, or the app closes. For gapless playback `PlayerViewModel` keeps the engine told of the queue's
next entry (`setNextTrack`); the engine hands its source to the driver ahead (`AudioDriver.setNext`), the driver
reports `advanced` once mpv plays it, and the engine passes that on as the new track without a new start. The queue
itself (track IDs, the place in it, shuffle and repeat) is saved as a preference when it changes and every 30 seconds
while playing, and picked up paused at start-up. Around the engine, `MobileAudio`
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
- **Theme**: an accent per section (`theme/palette.dart`), built once per section. Over the window's neutral base
  the backdrop washes in the colours of the cover that's playing (`widgets/ambient.dart`): the cover is decoded at 64
  px and blurred once into a 96 px bitmap, so nothing is blurred per frame, and it turns only on a desktop while music
  plays (not with the system's reduced motion).
- **Battery**: on a phone or tablet (`AppPlatform.isMobile`) nothing animates on its own: the backdrop doesn't turn,
  the logo doesn't breathe, the bars beside the playing track don't bounce, and the progress
  follows `PlayerViewModel.elapsedSeconds`, so music that plays on draws a frame a second; controlling another device,
  the position is counted on at that same pace.
  `WiretuneMediaSession` publishes changes, never a position that keeps pace: the system moves its own progress on from
  the last one.
- **Telling the user**: a short notice over either layout (`MainViewModel.showNotice`, shown by the app root) for what
  needs no answer: a change refused offline (`LibraryService.changeNotice`) or by the server
  (`ServerSession.changeRefused`), something that went through. A banner while the server's music can't play
  (unreachable, or signed out, with why). A question first (`confirmAction`) before what can't easily be undone:
  signing out with downloads, switching servers, changing the server's music folder, deleting an account or a
  playlist, showing all hidden items. A refusal next to the field it's about. A page of its own when the player can't
  start.
- **Automatic playlists** (*Most played*, *Recently played*) are `Playlist`s with `isAutomatic`, put together by
  `PlaylistsViewModel` from the tracks' play counts on each refresh and opening of the section; never stored, synced or
  offered as a target.
- **Lyrics** load only while they're on screen: the file's own (or the server's `/api/lyrics`), then LRCLIB if
  allowed, cached per track. A failed lookup isn't cached, so the panel can tell "couldn't reach" from "no lyrics".

## Localisation

Every text is one line in `wiretune_core/lib/src/localization/strings.dart`: `'Key': ('hu', 'en', 'de')`. Widgets read
them through `context.tr` and `context.trf` and rebuild when the language changes. It's English until the user picks
another; the system language is never read. Adding text or a language:
[development.md](development.md#texts-and-languages).
