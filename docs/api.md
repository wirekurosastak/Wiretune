# HTTP API

The JSON API under `/api` used by the players. It isn't versioned: if you build on it, pin a server version.

- camelCase JSON, ISO 8601 dates (UTC), durations in milliseconds.
- Errors: `{ "error": "message", "code": "code" }`, plus the number or path the message refers to (`limit`, `max`,
  `min`, `path` or `retryAfter`). `error` is English, for people. Players show their own text for the `code`
  ([codes](#error-codes)) and fall back to `error` for unknown codes.
- Auth: `Authorization: Bearer <token>`. Players that can't send headers may put a **stream token**
  (`POST /api/auth/stream-token`) in the URL as `?token=`, only on `/api/stream/…` and `/api/cover/…`. No other route
  and no other token type is accepted in a URL, because URLs end up in logs. Downloads use the sign-in token in the
  header.
- Roles: **anonymous**, **user**, **admin**. Bodies are limited to 64 KiB (playlists 4 MiB), above that `413`. Password
  rules, token lifetimes and the rate limit: [server.md](server.md#accounts).

## Authentication

| Route | Role | |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `{ "setupRequired": true }` while the server has no accounts |
| `POST /api/auth/setup` | anonymous | Creates the first account (administrator). Body `{ "username", "password", "setupCode" }`, with the code from the server log. `200` with an `AuthResponse`, `400` rule violation, `403` missing or wrong code, `409` already set up. Rate limited |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe" }`. `200` with an `AuthResponse`, `400` missing field, `401` wrong credentials. Rate limited |
| `POST /api/auth/stream-token` | user | No body. `200` with a `StreamTokenResponse`, valid 8 hours. A stream token can't request another |
| `POST /api/auth/change-password` | user | Body `{ "newPassword" }` (the current password isn't required). `200` with an `AuthResponse` and `"changed": true`: a new token for the caller, expiring when the old one would have. `400` invalid password. Rate limited. All earlier tokens (the caller's, other devices', stream tokens) stop working, and the account's remote-control connections close with `4401` |
| `GET /api/auth/me` | user | The caller's `UserInfo` |
| `GET /api/users` | admin | All accounts |
| `POST /api/users` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a `UserInfo`, `400`, or `409` name taken |
| `POST /api/users/{userId}/password` | admin | Body `{ "newPassword" }`. Sets another account's password and ends all its sessions. `200` `{ "changed": true }`, `400` invalid password or your own account (use `change-password`), `404` unknown account |
| `DELETE /api/users/{userId}` | admin | Deletes an account and its data. `400` your own account, `404` unknown account |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLoginAt" }`.
`StreamTokenResponse`: `{ "token", "expiresAt" }`.

## Library

| Route | Role | |
|---|---|---|
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanAt", "lastScanError", "lastScanProblem" }`. The last two say why the last scan didn't run or failed, in English and as a code (`folderMissing`, `folderLooksUnmounted`, `scanFailed`). Both are `null` when it went well, and for non-administrators (they name server folders) |
| `POST /api/library/scan` | admin | Requests a scan: `202 { "message": "Scan requested." }`. Poll the status route |
| `GET /api/tracks` | user | All tracks, with an `ETag`. Send it as `If-None-Match`: an unchanged list returns `304` with no body |
| `GET /api/artists/pictures` | user | Artists with their own picture in the music folder (`artist.jpg`, see the [user guide](user-guide.md#the-library)): `{ artistId: version }`; the version changes with the file. `ETag` as on `/api/tracks` |
| `GET /api/config` | admin | `{ "musicFolder" }` |
| `POST /api/config/music-folder` | admin | Body `{ "musicFolder" }`. Switches the music folder (saved in the database, kept after a restart even while missing) and requests a scan. `400` for an empty or missing folder, a whole disk, `/proc`, `/sys`, `/dev` or `/run`, or a folder that contains or is inside the server's data folder (following symbolic links) |

A **track** has:

- `id`, `title`
- `artist` (several artists joined by ", "), `artists` (the list, only when there are several)
- `album`, `albumArtist` (the first one when there are several), `albumArtists` (the list, only when there are several)
- `trackNumber`, `trackCount`, `discNumber`, `releaseYear`, `bpm`, `genre`
- `durationMs`, `fileSizeBytes`, `fileModifiedAt`, `hasCoverArt`, `addedAt`
- `format`: `codec`, `sampleRate`, `bitsPerSample` (0 for lossy), `channels`, `bitrateKbps`, `isLossless`
- `coverVersion`, if it has a cover. It changes when the album's cover changes. Players add it to the cover URL
  (`?v=`), so a new cover is never mistaken for a cached one.

File paths never leave the server. Favorites and play counts are per account and come from `/api/me/data`. Players group
albums and artists themselves; `album`, `albumArtist`, `trackNumber` and `discNumber` already reflect how the server
filed a folder of one artist's songs ([user guide](user-guide.md#the-library)).

## Your data

The signed-in account's favorites, play counts, playlists and hidden items. These routes only touch the account in the
token, and none accepts a stream token.

Limits: 100,000 favorites, 100,000 tracks with play counts, 500 playlists of up to 20,000 tracks, 50,000 hidden items,
IDs up to 128 characters, playlist names up to 200, descriptions up to 1,000. Over a limit: `409`.

| Route | Role | |
|---|---|---|
| `GET /api/me/data` | user | Everything: `{ "favorites": [trackId], "favoritedAt": { trackId: when }, "plays": [{ "trackId", "playCount", "lastPlayedAt" }], "playlists": [{ "id", "name", "description", "trackIds", "createdAt", "modifiedAt" }], "hiddenArtists": [artistId], "hiddenAlbums": [albumId], "hiddenTracks": [trackId] }`. Favorites are in the order they were marked; marking one again keeps its time. `ETag` as on `/api/tracks` |
| `PUT /api/me/favorites/{trackId}` | user | Marks a favorite (idempotent). `200 { "trackId", "isFavorite": true }`, `400` invalid ID, `409` at the limit |
| `DELETE /api/me/favorites/{trackId}` | user | Unmarks it. `200 { "trackId", "isFavorite": false }` |
| `POST /api/me/plays/{trackId}` | user | Adds a play and sets the last-played time. `200 { "trackId", "playCount", "lastPlayedAt" }`, `409` at the limit |
| `PUT /api/me/playlists/{playlistId}` | user | Creates or replaces a playlist. Body `{ "name", "description", "trackIds" }`. `200` with the stored playlist, `400` rule violation, `409` at the limit |
| `DELETE /api/me/playlists/{playlistId}` | user | `200 { "deleted": true }`, `404` unknown ID |
| `PUT /api/me/hidden/{type}/{itemId}` | user | Hides an artist, album or track (`type`: `artist`, `album`, `track`). `200 { "itemType", "itemId", "hidden": true }`, `400` invalid type or ID, `409` at the limit |
| `DELETE /api/me/hidden/{type}/{itemId}` | user | Unhides it. `200 { "itemType", "itemId", "hidden": false }` |

The server doesn't check that a track ID exists: libraries get rescanned and moved, and old IDs are kept.

## Media

| Route | Role | |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with range requests. `404` if the track is unknown, outside the music folder, or gone |
| `GET /api/cover/album/{albumId}` | user | The cover of the album's first track that has one (`image/jpeg` or `image/png`), cacheable for a day. `404` if there's none. `?v=` is ignored |
| `GET /api/cover/artist/{artistId}` | user | The artist's own picture, like an album cover. `404` if there's none |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tags (up to 100,000 characters), `404` if there are none. The server never looks online; the players ask LRCLIB themselves |

## Remote control

`GET /api/remote` upgrades to a WebSocket (user role, sign-in token in the header only: no stream token, no `?token=`).
Through it the players of one account see each other and send each other commands. The server only relays messages
between players of the same account and stores none.

- A plain `GET`: `426`.
- A request from a web page (with an `Origin` header): `403`.
- An account that already has 40 connections: `429`.

Every message is a JSON text object with a `type`, at most 64 K characters.

| Message | Sent by | |
|---|---|---|
| `{ "type": "hello", "device": { "id", "name", "kind" } }` | player | First, within 10 seconds. `id`: the player's permanent ID (up to 128 characters). `name`: up to 64, may be empty. `kind`: `desktop`, `phone`, `tablet` or `tv`. Sending hello again renames the device |
| `{ "type": "state", "state" }` | player | What it's playing (below). Sent to the others, including players that connect later |
| `{ "type": "command", "to", "command" }` | player | For another player of the account, by ID. Ignored if that player is offline |
| `{ "type": "devices", "devices": [{ "id", "name", "kind" }] }` | server | The account's other online players, whenever that changes |
| `{ "type": "state", "device", "state" }` | server | Another player's state |
| `{ "type": "command", "from", "command" }` | server | A command for this player |
| `{ "type": "dataChanged" }` | server | The account's favorites, playlists or hidden items changed (play counts aren't announced): download `/api/me/data` again. Not sent to the player that made the change, if it sent its device ID in an `X-Wiretune-Device` header with that request |
| `{ "type": "libraryChanged" }` | server | A scan changed `/api/tracks` or `/api/artists/pictures` (music added, changed or removed, a new cover or artist picture): download them again. Sent to every player of every account |

A **state** is `{ "track", "playing", "positionMs", "volume", "muted", "volumeLocked", "shuffle", "repeat", "queue",
"queueIndex" }`:

- `track`: as `/api/tracks` lists it, or `null`
- `positionMs`: the position when the state was sent (the others count on from there while it plays)
- `volume`: 0 to 100
- `repeat`: `off`, `all` or `one`
- `queue`: up to 1,000 track IDs, with `queueIndex` for the current one (or -1)

Server tracks use the server's IDs, so the other players find them in their own library.

A **command** has an `action`:

- `play`, `pause`, `toggle`, `stop`, `next`, `previous`, `clearQueue`
- `seek` (`positionMs`), `volume` (`volume`), `mute` and `shuffle` (`on`), `repeat` (`repeat`)
- `playTracks`: `trackIds`, `index` to start at (-1: the player chooses), `positionMs` there
- `playIndex` (`index` in the queue), `moveTrack` (`index` to `toIndex`), `removeTrack` (`index`)
- `playNext` (`trackIds` right after the current track), `addToQueue` (`trackIds` at the end). With an empty queue,
  both start playing.

Players validate what they receive and ignore commands they don't understand.

Close codes: `4000` the same device connected again, `4001` more than 20 devices on one account, `4401` the token
expired or the account was deleted, `1008` an invalid message (or more than 200 in 10 seconds), `1009` a message too
long. Both sides ping every 25 seconds.

## Error codes

| Code | Status | |
|---|---|---|
| `signInRequired`, `tokenInvalid`, `sessionExpired`, `passwordChanged`, `accountRemoved` | 401 | No token; a token this server didn't sign or that doesn't belong here; expired; issued before the password changed; a deleted account |
| `wrongCredentials` | 401 | Wrong user name or password |
| `adminOnly` | 403 | An administrator's route |
| `rateLimited` | 429 | With `retryAfter` (seconds), also as the `Retry-After` header |
| `credentialsRequired`, `usernameInvalid` (`max`), `passwordTooShort` (`min`), `passwordTooLong` (`max`, in bytes) | 400 | Account rules |
| `alreadySetUp` (409), `setupCodeWrong` (403), `usernameTaken` (409), `userNotFound` (404), `cannotDeleteSelf` (400), `cannotResetOwnPassword` (400) | | Accounts |
| `folderRequired`, `folderInvalid`, `folderMissing` (`path`), `folderUnreadable` (`path`), `folderWholeDisk`, `folderSystem`, `folderServerData` | 400 | The music folder |
| `invalidId`, `invalidItemType`, `playlistInvalid`, `playlistNameRequired`, `playlistNameTooLong` (`max`), `playlistDescriptionTooLong` (`max`), `playlistTooManyTracks` (`max`) | 400 | The account's data |
| `favoritesLimit`, `playCountsLimit`, `playlistsLimit`, `hiddenLimit` (all with `limit`) | 409 | The account's limits |
| `playlistNotFound`, `notFound` | 404 | |
| `invalidJson` (400), `bodyTooLarge` (413), `internalError` (500) | | Any route |
| `notWebSocket` (400, 426), `originRefused` (403), `tooManyConnections` (429) | | `/api/remote` |

The list is `ErrorCodes` in `packages/wiretune_core/lib/src/models/protocol.dart`, shared by server and players. A new
code needs its text in `strings.dart` as `Error<Code>`.

## Example

```bash
TOKEN=$(curl -s http://localhost:5200/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

curl -s -H "Authorization: Bearer $TOKEN" http://localhost:5200/api/tracks | jq '.[].title'

STREAM=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:5200/api/auth/stream-token | jq -r .token)
mpv "http://localhost:5200/api/stream/<trackId>?token=$STREAM"
```
