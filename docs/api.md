# HTTP API

The JSON API under `/api` that the players speak. It isn't versioned: if you build on it, pin a server version.

- camelCase JSON, dates in ISO 8601 (UTC), durations in milliseconds.
- Errors look like `{ "error": "message" }`; `401` and `403` come with an empty body.
- Send `Authorization: Bearer <token>`. Players that can't send headers may put a **stream token**
  (`POST /api/auth/stream-token`) into the URL as `?token=` on `/api/stream/…` and `/api/cover/…`. That's the only
  place a token is read from a URL, and the only kind of token accepted there: URLs end up in logs.
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
| `POST /api/auth/change-password` | user | Body `{ "currentPassword", "newPassword" }`. `200` `{ "changed": true }`, `400` for a password that breaks the rules, `403` when the current one is wrong. Rate limited. Tokens issued earlier stay valid until they expire |
| `GET /api/auth/me` | user | The caller's `UserInfo` |
| `GET /api/users` | admin | Every account |
| `DELETE /api/users/{userId}` | admin | Deletes an account and its data. `400` for your own account, `404` for an unknown one |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLogin" }`.
`StreamTokenResponse`: `{ "token", "expiresAt" }`.

## Library

| Route | Role | |
|---|---|---|
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanCompletedUtc", "lastScanError" }` |
| `POST /api/library/scan` | admin | Asks for a scan: `202 { "message": "Scan requested." }`. Poll the status route |
| `GET /api/tracks` | user | Every track; `?q=text` filters by title, artist, album, album artist or genre |
| `GET /api/config` | admin | `{ "libraryPath" }` |
| `POST /api/config/library-path` | admin | Body `{ "newPath" }`. Switches the music folder (kept in the database) and asks for a scan. `400` for an empty or missing folder |

A **track** has `id`, `title`, `artist`, `album`, `albumArtist`, `trackNumber`, `trackCount`, `discNumber`, `year`,
`genre`, `durationMs`, `fileSizeBytes`, `fileModifiedUtc`, `hasCoverArt`, `dateAdded` and `format` (`codec`,
`sampleRate`, `bitsPerSample` (0 for lossy), `channels`, `bitrateKbps`, `isLossless`). Files stay on the server, and so
do their paths. Favourites and play counts are per account and come from `/api/me/data`. The players group albums and
artists themselves.

## Your data

The signed-in account's favourites, play counts and playlists. Every route here touches only the account in the token,
and none takes a stream token. Limits: 100,000 favourites, 100,000 tracks with play counts, 500 playlists of up to
20,000 tracks, IDs up to 128 characters, playlist names up to 200 and descriptions up to 1,000. Over a limit you get
`409`.

| Route | Role | |
|---|---|---|
| `GET /api/me/data` | user | All of it: `{ "favorites": [trackId], "plays": [{ "trackId", "playCount", "lastPlayed" }], "playlists": [{ "id", "name", "description", "trackIds", "createdAt", "modifiedAt" }] }` |
| `PUT /api/me/favorites/{trackId}` | user | Marks a favourite (idempotent). `200 { "trackId", "isFavorite": true }`, `400` for an invalid ID, `409` at the limit |
| `DELETE /api/me/favorites/{trackId}` | user | Unmarks it. `200 { "trackId", "isFavorite": false }` |
| `POST /api/me/plays/{trackId}` | user | One more play, and the last-played time. `200 { "trackId", "playCount", "lastPlayed" }`, `409` at the limit |
| `PUT /api/me/playlists/{playlistId}` | user | Creates or replaces a playlist. Body `{ "name", "description", "trackIds" }`. `200` with the stored playlist, `400` for a rule violation, `409` at the limit |
| `DELETE /api/me/playlists/{playlistId}` | user | `200 { "deleted": true }`, `404` for an unknown ID |

The server doesn't check that a track ID exists: libraries get rescanned and moved, and old IDs stay.

## Media

| Route | Role | |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with range requests. `404` when the track is unknown, outside the music folder, or gone |
| `GET /api/cover/{trackId}` | user | The cover (`image/jpeg` or `image/png`), cacheable for a day. `404` when there is none |
| `GET /api/cover/album/{albumId}` | user | The cover of the album's first track that has one. The players use this one, so an album's tracks share one URL and one download |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tags (up to 100,000 characters), `404` when there are none. The server never looks online; the players ask LRCLIB themselves |

## Example

```bash
TOKEN=$(curl -s http://localhost:5200/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

curl -s -H "Authorization: Bearer $TOKEN" 'http://localhost:5200/api/tracks?q=coltrane' | jq '.[].title'

STREAM=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:5200/api/auth/stream-token | jq -r .token)
mpv "http://localhost:5200/api/stream/<trackId>?token=$STREAM"
```
