# HTTP API

The JSON API under `/api` that the Wiretune players use. It is not versioned; pin a server version if you build
on it.

## Conventions

- JSON names are camelCase. Dates are ISO 8601; durations are .NET `TimeSpan` strings (`"00:03:45.1230000"`),
  kept from the C# server so that players and servers of both versions understand each other.
- API errors look like `{ "error": "message" }`. `401` and `403` have an empty body.
- Send `Authorization: Bearer <token>`. Only `/api/stream/…` and `/api/cover/…` also accept `?token=<token>`
  (for players that cannot set headers); everywhere else the query token is rejected. For those URLs use a **stream
  token** (`POST /api/auth/stream-token`): it opens the two media routes and nothing else.
- Roles: **anonymous**, **user** (any account), **admin**. Request bodies are limited to 64 KiB, except a playlist
  (4 MiB) and the one-time import (32 MiB); a bigger body is answered with `413`.
- Credential rules, token lifetimes and the sign-in rate limit (`429` with `Retry-After`) are described in
  [server.md](server.md#accounts).

## Authentication

| Route | Role | Description |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `{ "setupRequired": true }` while the server has no accounts |
| `POST /api/auth/setup` | anonymous | Creates the first (admin) account. Body `{ "username", "password", "setupCode" }`; the code is the one the server prints in its log. `200` with an `AuthResponse`, `400` for rule violations, `403` for a missing or wrong setup code, `409` if already set up. Rate limited |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe" }`. `200` with an `AuthResponse`, `400` for a missing field, `401` for wrong credentials. Rate limited |
| `POST /api/auth/register` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a `UserInfo`, `400`, `409` if the name is taken |
| `POST /api/auth/stream-token` | user | No body. `200` with a `StreamTokenResponse`: a token for stream and cover URLs, valid 8 hours. A stream token itself is refused here |
| `POST /api/auth/change-password` | user | Body `{ "currentPassword", "newPassword" }`. `200` `{ "changed": true }`, `400` for a password that breaks the rules, `403` when the current one is wrong. Rate-limited like sign-in. Tokens already issued stay valid until they expire |
| `GET /api/auth/me` | user | The caller's `UserInfo` |
| `GET /api/users` | admin | All accounts |
| `DELETE /api/users/{userId}` | admin | Deletes an account. `400` when deleting oneself, `404` for an unknown ID |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLogin" }`.
`StreamTokenResponse`: `{ "token", "expiresAt" }`.

## Library

| Route | Role | Description |
|---|---|---|
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanCompletedUtc", "lastScanError" }` |
| `POST /api/library/scan` | admin | Requests a scan: `202 { "message": "Scan requested." }`. Poll the status route |
| `GET /api/tracks` | user | All tracks; `?q=text` filters by title, artist, album, album artist or genre |
| `GET /api/albums` | user | The server's album grouping, tracks nested |
| `GET /api/artists` | user | The server's artist (album artist) grouping, albums nested |
| `GET /api/config` | admin | `{ "libraryPath" }` |
| `POST /api/config/library-path` | admin | Body `{ "newPath" }`. Switches the library folder (kept in the database) and requests a scan. `400` for an empty or non-existent folder |

The Wiretune players only use `/api/tracks` and build albums and artists themselves; `/api/albums` and
`/api/artists` nest every track and can be large.

A **track** has `id`, `title`, `artist`, `album`, `albumArtist`, `trackNumber`, `trackCount`, `discNumber`,
`year`, `genre`, `duration`, `fileSizeBytes`, `fileModifiedUtc`, `hasCoverArt`, `dateAdded` and
`format` (`codec`, `sampleRate`, `bitsPerSample` (0 for lossy), `channels`, `bitrateKbps`, `isLossless`). The
`id` is derived from the file path ([server.md](server.md#library-and-scanning)). `filePath` is only a placeholder,
`server:{id}`: the real path never leaves the server, and neither does the location of the cover cache. The routes
send no `streamUrl`, `isFavorite`, `playCount` or `lastPlayed`: the first is built by the client, the others are
per account and come from `/api/me/data`.

## Your data (per account)

Favourites, play counts and playlists of the signed-in account, stored in the server's database. Every route here
reads or writes only the account in the token, and each is refused for a stream token. Limits: 100,000 favourites,
100,000 tracks with statistics, 500 playlists of up to 20,000 tracks each; IDs up to 128 characters; playlist names
up to 200 and descriptions up to 1,000 characters. Over a limit the answer is `409` (adding) or `400` (importing).

| Route | Role | Description |
|---|---|---|
| `GET /api/me/data` | user | Everything at once: `{ "favorites": [trackId], "plays": [{ "trackId", "playCount", "lastPlayed" }], "playlists": [{ "id", "name", "description", "trackIds", "createdAt", "modifiedAt" }] }` |
| `PUT /api/me/favorites/{trackId}` | user | Marks the track as a favourite (idempotent). `200 { "trackId", "isFavorite": true }`, `400` for an invalid ID, `409` at the limit |
| `DELETE /api/me/favorites/{trackId}` | user | Removes it. `200 { "trackId", "isFavorite": false }` |
| `POST /api/me/plays/{trackId}` | user | Counts one more play and sets the last-played time. `200` with the track's `{ "trackId", "playCount", "lastPlayed" }`, `409` at the limit |
| `PUT /api/me/playlists/{playlistId}` | user | Creates the playlist or replaces it. Body `{ "name", "description", "trackIds" }`. `200` with the stored playlist, `400` for rule violations, `409` at the limit |
| `DELETE /api/me/playlists/{playlistId}` | user | `200 { "deleted": true }`, `404` for an unknown ID |
| `POST /api/me/data/import` | user | One-time hand-over of what a player kept on the device: body as `GET /api/me/data`, up to 32 MiB. It only adds: favourites are added, play counts are raised to the larger value, playlists the account already has are left alone. `200` with the resulting counts, `400` (nothing stored) if anything is invalid |

The server does not check that a track ID exists: the library can be rescanned or moved, and IDs of vanished tracks
simply stay as they are.

## Media

| Route | Role | Description |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with HTTP range support. `404` if the track is unknown, outside the library folder, or gone |
| `GET /api/cover/{trackId}` | user | Cover image (`image/jpeg` or `image/png`), cached for a day. `404` when there is none |
| `GET /api/cover/album/{albumId}` | user | Cover of the first track of the album that has one. The players use this one, so the tracks of an album share one URL and the image is downloaded once |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tag (up to 100,000 characters); `404` when there are none. The server has no online lookup; players fall back to LRCLIB on their own |

## Example

```bash
TOKEN=$(curl -s http://localhost:5200/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

curl -s -H "Authorization: Bearer $TOKEN" 'http://localhost:5200/api/tracks?q=coltrane' | jq '.[].title'
mpv "http://localhost:5200/api/stream/<trackId>?token=$TOKEN"
```
