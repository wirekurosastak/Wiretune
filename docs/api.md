# HTTP API

The JSON API under `/api` that the players speak. It isn't versioned: if you build on it, pin a server version.

- camelCase JSON, dates in ISO 8601 (UTC), durations in milliseconds.
- Errors look like `{ "error": "message", "code": "code" }`, plus the one number or path the message names (`limit`,
  `max`, `min`, `path` or `retryAfter`). `error` is English, for people; a player shows its own text for the `code`
  ([below](#error-codes)) and falls back to `error` for one it doesn't know.
- Send `Authorization: Bearer <token>`. Players that can't send headers may put a **stream token**
  (`POST /api/auth/stream-token`) into the URL as `?token=` on `/api/stream/…` and `/api/cover/…`. That's the only
  place a token is read from a URL, and the only kind of token accepted there: URLs end up in logs. The players
  download with the sign-in token in the header.
- Roles are **anonymous**, **user** and **admin**. Bodies are capped at 64 KiB (a playlist 4 MiB), then `413`.
  Password rules, token lifetimes and the rate limit are in [server.md](server.md#accounts).

## Authentication

| Route | Role | |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `{ "setupRequired": true }` while the server has no accounts |
| `POST /api/auth/setup` | anonymous | Creates the first account, the administrator. Body `{ "username", "password", "setupCode" }`, the code being the one in the server's log. `200` with an `AuthResponse`, `400` for a rule violation, `403` for a missing or wrong code, `409` once set up. Rate limited |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe" }`. `200` with an `AuthResponse`, `400` for a missing field, `401` for wrong credentials. Rate limited |
| `POST /api/auth/register` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a `UserInfo`, `400`, or `409` when the name is taken |
| `POST /api/auth/stream-token` | user | No body. `200` with a `StreamTokenResponse`, valid 8 hours. A stream token can't get another one |
| `POST /api/auth/change-password` | user | Body `{ "currentPassword", "newPassword" }`. `200` with an `AuthResponse` and `"changed": true`: a new token for the caller, which expires when the old one would have. `400` for a password that breaks the rules, `403` when the current one is wrong. Rate limited. Every token issued before (the caller's, other devices', stream tokens) stops working, and the account's remote-control connections close with `4401` |
| `GET /api/auth/me` | user | The caller's `UserInfo` |
| `GET /api/users` | admin | Every account |
| `POST /api/users/{userId}/password` | admin | Body `{ "newPassword" }`. Sets another account's password and ends all its sessions, as a change does. `200` `{ "changed": true }`, `400` for a password that breaks the rules or for your own account (change that with the current one), `404` for an unknown one |
| `DELETE /api/users/{userId}` | admin | Deletes an account and its data. `400` for your own account, `404` for an unknown one |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLoginAt" }`.
`StreamTokenResponse`: `{ "token", "expiresAt" }`.

## Library

| Route | Role | |
|---|---|---|
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanAt", "lastScanError", "lastScanProblem" }`. Why the last scan didn't run or failed, in English and as a code (`folderMissing`, `folderLooksUnmounted`, `scanFailed`); both `null` when it went well, and for anyone but an administrator, since they name the server's folders |
| `POST /api/library/scan` | admin | Asks for a scan: `202 { "message": "Scan requested." }`. Poll the status route |
| `GET /api/tracks` | user | Every track |
| `GET /api/config` | admin | `{ "musicFolder" }` |
| `POST /api/config/music-folder` | admin | Body `{ "musicFolder" }`. Switches the music folder (kept in the database, and kept after a restart even while it's missing) and asks for a scan. `400` for an empty or missing folder, a whole disk, `/proc`, `/sys`, `/dev` or `/run`, or a folder that holds or lies inside the server's data directory, judged where symbolic links lead |

A **track** has `id`, `title`, `artist` (several artists joined by ", "), `artists` (each of them, only when there
are several), `album`, `albumArtist`, `trackNumber`, `trackCount`, `discNumber`, `releaseYear`,
`genre`, `durationMs`, `fileSizeBytes`, `fileModifiedAt`, `hasCoverArt`, `addedAt` and `format` (`codec`,
`sampleRate`, `bitsPerSample` (0 for lossy), `channels`, `bitrateKbps`, `isLossless`). Files stay on the server, and so
do their paths. Favourites and play counts are per account and come from `/api/me/data`. The players group albums and
artists themselves; `album`, `albumArtist`, `trackNumber` and `discNumber` already say how the server filed a folder's
collection ([user guide](user-guide.md#the-library)).

## Your data

The signed-in account's favourites, play counts, playlists and hidden content preferences. Every route here touches
only the account in the token, and none takes a stream token. Limits: 100,000 favourites, 100,000 tracks with play
counts, 500 playlists of up to 20,000 tracks, 50,000 hidden items, IDs up to 128 characters, playlist names up to 200 and
descriptions up to 1,000. Over a limit you get `409`.

| Route | Role | |
|---|---|---|
| `GET /api/me/data` | user | All of it: `{ "favorites": [trackId], "favoritedAt": { trackId: when }, "plays": [{ "trackId", "playCount", "lastPlayedAt" }], "playlists": [{ "id", "name", "description", "trackIds", "createdAt", "modifiedAt" }], "hiddenArtists": [artistId], "hiddenAlbums": [albumId], "hiddenTracks": [trackId] }`. The favourites come in the order they were marked; marking one again keeps its time |
| `PUT /api/me/favorites/{trackId}` | user | Marks a favourite (idempotent). `200 { "trackId", "isFavorite": true }`, `400` for an invalid ID, `409` at the limit |
| `DELETE /api/me/favorites/{trackId}` | user | Unmarks it. `200 { "trackId", "isFavorite": false }` |
| `POST /api/me/plays/{trackId}` | user | One more play, and the last-played time. `200 { "trackId", "playCount", "lastPlayedAt" }`, `409` at the limit |
| `PUT /api/me/playlists/{playlistId}` | user | Creates or replaces a playlist. Body `{ "name", "description", "trackIds" }`. `200` with the stored playlist, `400` for a rule violation, `409` at the limit |
| `DELETE /api/me/playlists/{playlistId}` | user | `200 { "deleted": true }`, `404` for an unknown ID |
| `PUT /api/me/hidden/{type}/{itemId}` | user | Hides an artist, album, or track (`type`: `artist`, `album`, `track`). `200 { "itemType", "itemId", "hidden": true }`, `400` for an invalid type or ID, `409` at the limit |
| `DELETE /api/me/hidden/{type}/{itemId}` | user | Unhides an item. `200 { "itemType", "itemId", "hidden": false }` |

The server doesn't check that a track ID exists: libraries get rescanned and moved, and old IDs stay.

## Media

| Route | Role | |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with range requests. `404` when the track is unknown, outside the music folder, or gone |
| `GET /api/cover/album/{albumId}` | user | The cover of the album's first track that has one (`image/jpeg` or `image/png`), cacheable for a day. `404` when there is none |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tags (up to 100,000 characters), `404` when there are none. The server never looks online; the players ask LRCLIB themselves |

## Remote control

`GET /api/remote` (user, with the sign-in token in the header: never a stream token, never `?token=`) upgrades to a
WebSocket. Through it the players of one account see each other and send each other commands. The server passes the
messages on between the players of that account and nowhere else, and keeps none of them. A plain `GET` gets `426`, a
request from a web page (one with an `Origin` header) `403`, and an account that already holds 40 connections `429`.

Every message is a JSON object with a `type`, sent as text, at most 64 K characters.

| Message | Sent by | |
|---|---|---|
| `{ "type": "hello", "device": { "id", "name", "kind" } }` | player | First, within 10 seconds. `id` is the player's own lasting ID (up to 128 characters), `name` up to 64 (empty is fine), `kind` one of `desktop`, `phone`, `tablet`, `tv`. Saying hello again renames the device |
| `{ "type": "state", "state" }` | player | What it plays (below). The others get it, and so do players that connect later |
| `{ "type": "command", "to", "command" }` | player | For another player of the account, by its ID; one that isn't online is ignored |
| `{ "type": "devices", "devices": [{ "id", "name", "kind" }] }` | server | The account's other players that are online, every time that changes |
| `{ "type": "state", "device", "state" }` | server | Another player's state |
| `{ "type": "command", "from", "command" }` | server | A command for this player |
| `{ "type": "dataChanged" }` | server | The account's favourites, playlists or hidden items changed (play counts aren't announced): download `/api/me/data` again. Not sent to the player that made the change when it named itself in an `X-Wiretune-Device` header (its device ID) on that request |

A **state** is `{ "track", "playing", "positionMs", "volume", "muted", "volumeLocked", "shuffle", "repeat", "queue",
"queueIndex" }`: the track as `/api/tracks` lists it (or `null`), the position when the state was sent (the others
count on from there while it plays), the volume from 0 to 100, `repeat` as `off`, `all` or `one`, and up to 1,000
track IDs of the queue with the current one's index (or -1). Tracks from the server go by the server's IDs, so the other
players find them in their own library.

A **command** has an `action`: `play`, `pause`, `toggle`, `stop`, `next`, `previous`, `seek` (with `positionMs`),
`volume` (`volume`), `mute` and `shuffle` (`on`), `repeat` (`repeat`), `playTracks` (`trackIds`, the `index` to start
at or -1 for the player's own choice, and `positionMs` there), `playIndex` (`index` in its queue), `moveTrack` (from
`index` to `toIndex` in its queue), `removeTrack` (`index`), `clearQueue`, `playNext` (`trackIds` right after the
current track) or `addToQueue` (`trackIds` at the end; with nothing queued both start playing). A player checks what it gets and ignores a
command it doesn't understand.

The server closes a connection with `4000` when the same device connects again, `4001` beyond 20 devices on one
account, `4401` when the token expires or the account is deleted, `1008` for a message it doesn't accept (or more than
200 in 10 seconds), and `1009` for one that is too long. Both sides ping every 25 seconds.

## Error codes

| Code | Status | |
|---|---|---|
| `signInRequired`, `tokenInvalid`, `sessionExpired`, `passwordChanged`, `accountRemoved` | 401 | No token; one this server didn't sign or that doesn't belong here; expired; issued before the password changed; of a deleted account |
| `wrongCredentials` | 401 | The sign-in's user name or password |
| `adminOnly` | 403 | An administrator's route |
| `rateLimited` | 429 | With `retryAfter` (seconds), also as the `Retry-After` header |
| `credentialsRequired`, `usernameInvalid` (`max`), `passwordTooShort` (`min`), `passwordTooLong` (`max`, in bytes) | 400 | Account rules |
| `alreadySetUp` (409), `setupCodeWrong` (403), `currentPasswordWrong` (403), `usernameTaken` (409), `userNotFound` (404), `cannotDeleteSelf` (400), `cannotResetOwnPassword` (400) | | Accounts |
| `folderRequired`, `folderInvalid`, `folderMissing` (`path`), `folderUnreadable` (`path`), `folderWholeDisk`, `folderSystem`, `folderServerData` | 400 | The music folder |
| `invalidId`, `invalidItemType`, `playlistInvalid`, `playlistNameRequired`, `playlistNameTooLong` (`max`), `playlistDescriptionTooLong` (`max`), `playlistTooManyTracks` (`max`) | 400 | The account's data |
| `favoritesLimit`, `playCountsLimit`, `playlistsLimit`, `hiddenLimit` (all with `limit`) | 409 | The account's limits |
| `playlistNotFound`, `notFound` | 404 | |
| `invalidJson` (400), `bodyTooLarge` (413), `internalError` (500) | | Any route |
| `notWebSocket` (400, 426), `originRefused` (403), `tooManyConnections` (429) | | `/api/remote` |

The list lives in `ErrorCodes` (`packages/wiretune_core/lib/src/models/protocol.dart`), shared by the server and the
players; a new code gets its text in `strings.dart` as `Error<Code>`.

## Example

```bash
TOKEN=$(curl -s http://localhost:5200/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

curl -s -H "Authorization: Bearer $TOKEN" http://localhost:5200/api/tracks | jq '.[].title'

STREAM=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:5200/api/auth/stream-token | jq -r .token)
mpv "http://localhost:5200/api/stream/<trackId>?token=$STREAM"
```
