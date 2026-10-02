# HTTP API

The JSON API under `/api` that the Wiretune players use. It is not versioned; pin a server version if you build
on it.

## Conventions

- JSON names are camelCase. Dates are ISO 8601; durations are .NET `TimeSpan` strings (`"00:03:45.1230000"`).
- API errors look like `{ "error": "message" }`. `401` and `403` have an empty body.
- Send `Authorization: Bearer <token>`. Only `/api/stream/…` and `/api/cover/…` also accept `?token=<token>`
  (for players that cannot set headers); everywhere else the query token is rejected.
- Roles: **anonymous**, **user** (any account), **admin**. Request bodies are limited to 64 KiB.
- Credential rules, token lifetimes and the sign-in rate limit (`429` with `Retry-After`) are described in
  [server.md](server.md#accounts).

## Authentication

| Route | Role | Description |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `{ "setupRequired": true }` while the server has no accounts |
| `POST /api/auth/setup` | anonymous | Creates the first (admin) account. Body `{ "username", "password" }`. `200` with an `AuthResponse`, `400` for rule violations, `409` if already set up. Rate limited |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe" }`. `200` with an `AuthResponse`, `400` for a missing field, `401` for wrong credentials. Rate limited |
| `POST /api/auth/register` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a `UserInfo`, `400`, `409` if the name is taken |
| `GET /api/auth/me` | user | The caller's `UserInfo` |
| `GET /api/users` | admin | All accounts |
| `DELETE /api/users/{userId}` | admin | Deletes an account. `400` when deleting oneself, `404` for an unknown ID |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLogin" }`.

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
`id` is derived from the file path ([server.md](server.md#library-and-scanning)). `filePath` is the **absolute
path on the server** and is visible to every signed-in user. `streamUrl`, `isFavorite`, `playCount` and
`lastPlayed` belong to the client and are never set by the server.

## Media

| Route | Role | Description |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with HTTP range support. `404` if the track is unknown, outside the library folder, or gone |
| `GET /api/cover/{trackId}` | user | Cover image (`image/jpeg` or `image/png`), cached for a day. `404` when there is none |
| `GET /api/cover/album/{albumId}` | user | Cover of the first track of the album that has one |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tag (up to 100,000 characters); `404` when there are none |

## Example

```bash
TOKEN=$(curl -s http://localhost:5200/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

curl -s -H "Authorization: Bearer $TOKEN" 'http://localhost:5200/api/tracks?q=coltrane' | jq '.[].title'
ffplay -nodisp "http://localhost:5200/api/stream/<trackId>?token=$TOKEN"
```
