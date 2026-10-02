# HTTP API

The server exposes a small JSON API under `/api`. This is the interface the Wiretune clients use; it is not
versioned, so avoid depending on it from other software without pinning a server version.

## Conventions

- JSON property names are camelCase (`trackCount`). Dates are ISO 8601 strings; durations are .NET `TimeSpan`
  strings (`"00:03:45.1230000"`).
- Errors from the API itself have the form `{ "error": "message" }`. Authentication failures (`401`) and
  authorisation failures (`403`) have an empty body.
- Authenticated requests send `Authorization: Bearer <token>`. As an exception, `/api/stream/…` and
  `/api/cover/…` also accept the token as a `?token=<token>` query parameter, for players that cannot set
  headers. The query token is rejected everywhere else.
- Roles: **anonymous**, **user** (any account) and **admin**.
- Request bodies are limited to 64 KiB.

## Authentication

| Method and route | Role | Description |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `200 { "setupRequired": true }` while the server has no accounts. |
| `POST /api/auth/setup` | anonymous | Creates the first (administrator) account. Body `{ "username", "password" }`. `200` with an [`AuthResponse`](#authresponse); `400` if the credentials break the rules; `409` if the server is already set up. Rate limited. |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe": false }`. `200` with an `AuthResponse`; `400` if a field is missing; `401` for wrong credentials. Rate limited. |
| `POST /api/auth/register` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a [`UserInfo`](#userinfo); `400` for rule violations; `409` if the name is taken. |
| `GET /api/auth/me` | user | The caller's `UserInfo`. |
| `GET /api/users` | admin | All accounts, ordered by user name. |
| `DELETE /api/users/{userId}` | admin | Deletes an account (its tokens stop working at once). `400` when deleting oneself, `404` for an unknown ID. |

Rate limit for setup and login: 10 requests per minute per client address, counted together; excess requests
get `429` with a `Retry-After` header and `{ "error": "Too many attempts. Try again in a minute." }`.

Credential rules: user name 1–64 characters without control characters (leading and trailing white space is
trimmed; names are unique ignoring case); password at least 8 characters and at most 72 bytes in UTF-8.

### AuthResponse

```json
{
  "token": "<jwt>",
  "user": { "id": "…", "username": "alice", "isAdmin": false, "createdAt": "…", "lastLogin": "…" },
  "expiresAt": "2026-10-03T12:00:00Z"
}
```

### UserInfo

`{ "id": string, "username": string, "isAdmin": bool, "createdAt": date, "lastLogin": date | null }`

Tokens are valid for 24 hours, or 90 days when `rememberMe` is true; the token returned by the first-run setup
is valid for 90 days.

## Library

| Method and route | Role | Description |
|---|---|---|
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanCompletedUtc", "lastScanError" }`. The last two are `null` when no scan has finished or no error occurred. |
| `POST /api/library/scan` | admin | Requests a scan. `202 { "message": "Scan requested." }`; poll `/api/library/status`. |
| `GET /api/tracks` | user | All tracks. With `?q=text`, only tracks whose title, artist, album, album artist or genre contains the text (case-insensitive). |
| `GET /api/albums` | user | The server's grouping of the library into albums, each with its tracks nested. |
| `GET /api/artists` | user | The server's grouping into artists (album artists), each with its albums nested. |
| `GET /api/config` | admin | `{ "libraryPath": "…" }`, the folder the server currently serves. |
| `POST /api/config/library-path` | admin | Body `{ "newPath": "/path" }`. Switches the library folder (stored in the database, survives restarts) and requests a scan. `400` for an empty, invalid or non-existent folder. Returns the new `{ "libraryPath" }`. |

The bundled clients only use `/api/tracks` and build albums and artists themselves; `/api/albums` and
`/api/artists` can be large because tracks are nested.

### Track

| Field | Type | Notes |
|---|---|---|
| `id` | string | 32 hex characters, derived from the file's full path (lower-cased). Stable until the file is moved or renamed. |
| `title`, `artist`, `album` | string | Missing tags are replaced: file name, `Unknown artist`, `Unknown album`. |
| `albumArtist` | string or null | |
| `trackNumber`, `trackCount`, `discNumber`, `year` | int or null | |
| `genre` | string or null | First genre of the tag. |
| `duration` | TimeSpan string | |
| `fileSizeBytes` | int | |
| `fileModifiedUtc` | date or null | |
| `filePath` | string | **Absolute path on the server.** Visible to every authenticated user. |
| `streamUrl` | null | Set by the client, never by the server. |
| `hasCoverArt` | bool | |
| `coverArtPath` | string or null | Server-side path; clients replace it with the cover URL. |
| `format` | object | `{ "codec", "sampleRate", "bitsPerSample", "channels", "bitrateKbps", "isLossless" }`. `bitsPerSample` is `0` for lossy formats. |
| `dateAdded` | date | |
| `isFavorite`, `playCount`, `lastPlayed` | | Present for the client's benefit; the server never changes them (favourites and play counts live in each client's own database). |

## Media

| Method and route | Role | Description |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file with HTTP range support (`Accept-Ranges`, `206`) and a MIME type chosen by file extension. `404` if the track is unknown, outside the library folder, or the file is gone. |
| `GET /api/cover/{trackId}` | user | Cover image of a track (`image/jpeg` or `image/png`), `Cache-Control: private, max-age=86400`. `404` when there is none. |
| `GET /api/cover/album/{albumId}` | user | Cover of the first track of the album that has one. |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics": "…" }` from the file's tag (at most 100,000 characters); `404` when the file has none. |

## Examples

```bash
# sign in and keep the token
TOKEN=$(curl -s http://localhost:5200/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"correct horse battery"}' | jq -r .token)

# search
curl -s -H "Authorization: Bearer $TOKEN" 'http://localhost:5200/api/tracks?q=coltrane' | jq '.[].title'

# play with a tool that cannot send headers
ffplay -nodisp "http://localhost:5200/api/stream/<trackId>?token=$TOKEN"
```
