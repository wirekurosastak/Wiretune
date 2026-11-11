# HTTP API

The JSON API under `/api` used by the players. It isn't versioned: if you build on it, pin a server version. `GET /`
answers a line of text that says it's a Wiretune server, for a browser.

- camelCase JSON, ISO 8601 dates (UTC), durations in milliseconds.
- Errors: `{ "error": "message", "code": "code" }`, plus the number or path the message refers to (`limit`, `max`,
  `min`, `path` or `retryAfter`). `error` is English, for people. Players show their own text for the `code`
  ([codes](#error-codes)) and fall back to `error` for unknown codes.
- Auth: `Authorization: Bearer <token>`. Players that can't send headers may put a **stream token**
  (`POST /api/auth/stream-token`) in the URL as `?token=`, only on `/api/stream/…` and `/api/cover/…`. No other route
  and no other token type is accepted in a URL, because URLs end up in logs. Downloads use the sign-in token in the
  header.
- Roles: **anonymous**, **user**, **admin**. Bodies are limited to 64 KiB (playlists 4 MiB), above that `413`. Password
  rules: [server.md](server.md#accounts). Token lifetimes and the rate limit: [SECURITY.md](../SECURITY.md#server).

## Authentication

| Route | Role | |
|---|---|---|
| `GET /api/auth/setup-required` | anonymous | `{ "setupRequired": true }` while the server has no accounts |
| `POST /api/auth/setup` | anonymous | Creates the first account (administrator). Body `{ "username", "password", "setupCode" }`, with the code from the server log. `200` with an `AuthResponse`, `400` rule violation, `403` missing or wrong code, `409` already set up. Rate limited |
| `POST /api/auth/login` | anonymous | Body `{ "username", "password", "rememberMe" }`. `200` with an `AuthResponse`, `400` missing field, `401` wrong credentials. Rate limited |
| `POST /api/auth/login-with-code` | anonymous | Body `{ "code" }`: a sign-in code from `sign-in-code`. `200` with an `AuthResponse` that lasts 90 days, `400` no code, `401` `signInCodeInvalid` (wrong, used, expired, or made before the password changed). The code is used up. Rate limited |
| `POST /api/auth/sign-in-code` | user | No body. `200` with a `SignInCode`: a code that signs another device in to the caller's account once, within 5 minutes (a player shows it as a QR code). It replaces the account's earlier code. Kept in memory: a restart ends it |
| `POST /api/auth/stream-token` | user | No body. `200` with a `StreamTokenResponse`, valid 8 hours. A stream token can't request another |
| `POST /api/auth/change-password` | user | Body `{ "newPassword" }` (the current password isn't required). `200` with an `AuthResponse` and `"changed": true`: a new token for the caller, expiring when the old one would have. `400` invalid password. Rate limited. All earlier tokens (the caller's, other devices', stream tokens) stop working, and the account's remote-control connections close with `4401` |
| `POST /api/auth/change-username` | user | Body `{ "username" }`. Renames the caller: an administrator always, another account when the administrator lets members (`membersCanRename`). `200` with the `UserInfo`, `400` invalid name, `403` `renameNotAllowed`, `409` name taken. Rate limited. Sessions stay signed in; the next sign-in uses the new name |
| `GET /api/auth/me` | user | The caller's `UserInfo`, with `canRename`: whether it may change its own name |
| `GET /api/accounts` | user | Every account as `{ "id", "username" }`, by name: the friends to recommend to |
| `GET /api/users` | admin | All accounts |
| `POST /api/users` | admin | Creates a regular user. Body `{ "username", "password" }`. `200` with a `UserInfo`, `400`, or `409` name taken |
| `POST /api/users/{userId}/username` | admin | Body `{ "username" }`. Renames an account; it keeps its data and its sessions. `200` with the `UserInfo`, `400` invalid name, `404` unknown account, `409` name taken |
| `POST /api/users/{userId}/password` | admin | Body `{ "newPassword" }`. Sets another account's password and ends all its sessions. `200` `{ "changed": true }`, `400` invalid password or your own account (use `change-password`), `404` unknown account |
| `DELETE /api/users/{userId}` | admin | Deletes an account and its data. `400` your own account, `404` unknown account |

`AuthResponse`: `{ "token", "user": UserInfo, "expiresAt" }`.
`UserInfo`: `{ "id", "username", "isAdmin", "createdAt", "lastLoginAt" }`.
`StreamTokenResponse`: `{ "token", "expiresAt" }`.
`SignInCode`: `{ "code", "expiresAt" }`.

## Library

| Route | Role | |
|---|---|---|
| `GET /api/server` | user | `{ "version", "converts" }`: the server's version without the build number (`1.1.2026`), and whether it converts tracks for a lower streaming quality (it has `ffmpeg`). A player that gets `404` here knows the server is older than this route |
| `GET /api/library/status` | user | `{ "trackCount", "albumCount", "artistCount", "isScanning", "lastScanAt", "lastScanError", "lastScanProblem" }`. The last two say why the last scan didn't run or failed, in English and as a code (`folderMissing`, `folderLooksUnmounted`, `scanFailed`). Both are `null` when it went well, and for non-administrators (they name server folders) |
| `POST /api/library/scan` | admin | Requests a scan: `202 { "message": "Scan requested." }`. Poll the status route |
| `GET /api/tracks` | user | All tracks, with an `ETag`. Send it as `If-None-Match`: an unchanged list returns `304` with no body. A track's `details` (when its tags give any) hold `isrc`, `barcode`, `musicBrainzTrackId`, `label`, `copyright` (the ℗ line) and `composer`. A track whose file names no genre or label has its album's, when the server looked the album up |
| `GET /api/artists/pictures` | user | Artists with their own picture in the music folder (`artist.jpg`, see the [user guide](user-guide.md#the-library)): `{ artistId: version }`; the version changes with the file. `ETag` as on `/api/tracks` |
| `GET /api/config` | admin | `{ "musicFolder", "membersCanRename", "lookUpOnline" }` |
| `POST /api/config/online-lookups` | admin | Body `{ "enabled": true }` or `false`: whether the server looks music up online (on at first): albums on Deezer for their genre and label, tracks' credits on MusicBrainz. Turned on, it looks up the albums it hasn't asked about yet. `200` with the config, `400` not a boolean |
| `POST /api/config/members-can-rename` | admin | Body `{ "enabled": true }` or `false`: whether accounts that aren't administrators may change their own names (off at first). `200` with the config, `400` not a boolean |
| `POST /api/config/music-folder` | admin | Body `{ "musicFolder" }`. Switches the music folder (saved in the database, kept after a restart even while missing) and requests a scan. `400` for an empty or missing folder, a whole disk, `/proc`, `/sys`, `/dev` or `/run`, or a folder that contains or is inside the server's data folder (following symbolic links) |

A **track** has:

- `id`, `title`
- `artist` (several artists joined by ", "), `artists` (the list, only when there are several)
- `album`, `albumArtist` (the first one when there are several), `albumArtists` (the list, only when there are several)
- `trackNumber`, `trackCount`, `discNumber`, `releaseYear`, `bpm`, `genre`
- `durationMs`, `fileSizeBytes`, `fileModifiedAt`, `hasCoverArt`, `addedAt`
- `format`: `codec`, `sampleRate`, `bitsPerSample` (0 for lossy), `channels`, `bitrateKbps`, `isLossless`
- `coverVersion`, if it has a cover: changes with the album's cover. Players add it to the cover URL (`?v=`).

File paths never leave the server. Favorites and play counts come from `/api/me/data`. Players group albums and
artists themselves; `album`, `albumArtist`, `trackNumber` and `discNumber` already say how the server filed a folder of
one artist's songs ([user guide](user-guide.md#the-library)).

## Your data

The signed-in account's favorites, play counts, playlists and hidden items. These routes only touch the account in the
token, and none accepts a stream token.

Limits: 100,000 favorites, 100,000 tracks with play counts, 500 playlists of up to 20,000 tracks, 50,000 hidden items,
IDs up to 128 characters, playlist names up to 200, descriptions up to 1,000, 50 accounts a playlist is shared with
(invited ones too). Over a limit: `409`.

| Route | Role | |
|---|---|---|
| `GET /api/me/data` | user | Everything: `{ "favorites": [trackId], "favoritedAt": { trackId: when }, "plays": [{ "trackId", "playCount", "lastPlayedAt" }], "playlists": [{ "id", "name", "description", "trackIds", "createdAt", "modifiedAt", "owner", "members", "invited" }], "hiddenArtists": [artistId], "hiddenAlbums": [albumId], "hiddenTracks": [trackId] }`. Favorites are in the order they were marked; marking one again keeps its time. `ETag` as on `/api/tracks` |
| `PUT /api/me/favorites/{trackId}` | user | Marks a favorite (idempotent). `200 { "trackId", "isFavorite": true }`, `400` invalid ID, `409` at the limit |
| `DELETE /api/me/favorites/{trackId}` | user | Unmarks it. `200 { "trackId", "isFavorite": false }` |
| `GET /api/me/plays?from=…&to=…` | user | How often the account played each track from `from` until `to` (ISO times): `{ "plays": { trackId: count }, "since" }`, `since` when its play log begins (the log keeps the newest 200,000 plays). `400` `invalidPeriod` |
| `POST /api/me/plays/{trackId}` | user | Adds a play (also to the play log) and sets the last-played time. An optional body `{ "at" }` (an ISO time) says when it was played, for a player that couldn't reach the server then; without it, or with a time still to come, now. `200 { "trackId", "playCount", "lastPlayedAt" }`, `409` at the limit |
| `PUT /api/me/playlists/{playlistId}` | user | Creates or replaces a playlist. Body `{ "name", "description", "trackIds" }`. For a playlist shared with the account, only `trackIds` count. `200` with the stored playlist, `400` rule violation, `409` at the limit |
| `DELETE /api/me/playlists/{playlistId}` | user | Deletes it, with its sharing; leaves one shared with the account. `200 { "deleted": true }`, `404` unknown ID |
| `PUT /api/me/playlists/{playlistId}/members/{userId}` | user | Shares the account's own playlist with another account: an invitation. Sharing again changes nothing. `200 { "userId", "shared": true }`, `400` `playlistMemberInvalid`, `404` not the account's playlist, `409` `playlistMembersLimit` |
| `DELETE /api/me/playlists/{playlistId}/members/{userId}` | user | Stops sharing it with that account (a member or an invitation). `200 { "userId", "shared": false }`, `404` |
| `GET /api/me/playlist-invites` | user | The playlists others share with the account that it hasn't joined, newest first: `[{ "playlistId", "name", "owner": { "id", "username" }, "trackCount" }]`. None from an account it blocks |
| `POST /api/me/playlist-invites/{playlistId}` | user | Joins it: `200` with the playlist, `404` `playlistInviteNotFound` |
| `DELETE /api/me/playlist-invites/{playlistId}` | user | Turns it down. `200 { "declined": true }`, `404` `playlistInviteNotFound` |
| `PUT /api/me/hidden/{type}/{itemId}` | user | Hides an artist, album or track (`type`: `artist`, `album`, `track`). `200 { "itemType", "itemId", "hidden": true }`, `400` invalid type or ID, `409` at the limit |
| `DELETE /api/me/hidden/{type}/{itemId}` | user | Unhides it. `200 { "itemType", "itemId", "hidden": false }` |

A **shared playlist** stays its owner's. In `/api/me/data`, one shared with the account has `owner` (`{ "id", "username" }`)
and the other `members`; the owner's own has the `members` who joined and the accounts `invited`. Each is left out when
there is nobody. A change to a shared playlist sends `dataChanged` to everyone who has it, and an invitation sends
`playlistInvitesChanged` to the invited account. Blocking ends the sharing between the two accounts, either way.

The server doesn't check that a track ID exists (old IDs are kept across rescans). A scan that finds a moved file moves
its data to the new ID and sends `dataChanged`.

## Recommendations

What the accounts recommend to each other: an artist, an album or a track (`kind`: `artist`, `album`, `track`). An
account keeps its newest 200; one more pushes out the oldest.

| Route | Role | |
|---|---|---|
| `GET /api/me/recommendations` | user | What others recommended to this account, newest first: `[{ "id", "from": { "id", "username" }, "kind", "itemId", "note", "sentAt", "seen" }]` |
| `POST /api/me/recommendations` | user | Body `{ "kind", "itemId", "to": [accountId], "note" }`: an item of the library, 1 to 50 other accounts, a note of up to 200 characters (may be empty). `200 { "ids" }`, one per recipient that gets it: an account that blocked the sender doesn't, and the answer is otherwise the same. `400` rule violation, `404` not in the library |
| `POST /api/me/recommendations/seen` | user | Marks them all seen (the bell was opened). `200 { "seen": true }` |
| `DELETE /api/me/recommendations/{id}` | user | Its recipient dismisses it, or its sender takes it back. `200 { "deleted": true }`, `404` if it is neither's |

Each change sends `recommendationsChanged` to the recipient's players.

A **Blend** is a playlist the server mixes from two accounts' listening. One invites, the other accepts by inviting back,
and either leaves, which ends it for both. The mix takes each account's 100 most played tracks (a favorite counts 5
plays), then up to 50 in turns: one both have, one of the inviter's, one of the other's. A track either account hides
is never in it. It's mixed again at every `GET`, so it follows what both play.

| Route | Role | |
|---|---|---|
| `GET /api/me/blends` | user | The account's Blends, by the other's name: `[{ "id", "with": { "id", "username" }, "state", "trackIds" }]`. `state`: `invited` (the other asks this one), `inviting` (this one asks) or `active`; `trackIds` are empty until `active` |
| `POST /api/me/blends` | user | Body `{ "with": accountId }`: invites that account, or accepts its invitation. Inviting again changes nothing. `200` with the Blend, `400` `blendAccountInvalid` (not another account of the server), `409` `blendsLimit` (50 Blends and invitations) |
| `DELETE /api/me/blends/{id}` | user | Leaves it, or turns down or takes back the invitation. `200 { "deleted": true }`, `404` `blendNotFound` |

Each change sends `blendsChanged` to both accounts' players. Blocking ends a Blend. While one account blocks the other,
an invitation between them waits: its sender sees it as `inviting`, the account that blocks never sees it, and it
can't be accepted.

An account can block another, which isn't told: the blocked account's recommendations (sent ones included) and
invites to listen together stop reaching it. Blocking also ends their Blend and shared playlists, and hides each
one's shared players from the other.

| Route | Role | |
|---|---|---|
| `GET /api/me/blocked` | user | The accounts this one blocked, by name: `[{ "id", "username" }]` |
| `PUT /api/me/blocked/{userId}` | user | Blocks another account. `200 { "userId", "blocked": true }`, `404` for an unknown account or the caller's own |
| `DELETE /api/me/blocked/{userId}` | user | Unblocks it; what it sent before the block doesn't come back. `200 { "userId", "blocked": false }` |

## Media

| Route | Role | |
|---|---|---|
| `GET /api/stream/{trackId}` | user | The audio file, with range requests. `404` if the track is unknown, outside the music folder, or gone. With `?format=opus` or `mp3` and `&bitrate=<kbit/s>` (Opus 24–256, default 128; MP3 64–320, default 192), the track converted by `ffmpeg` and kept on disk ([how](server.md#streaming-on-a-slow-connection)); the file itself when the server can't convert it, or when it is lossy and at or below the bitrate |
| `GET /api/cover/album/{albumId}` | user | The cover of the album's first track that has one (`image/jpeg` or `image/png`), cacheable for a day. `404` if there's none. `?v=` is ignored |
| `GET /api/cover/artist/{artistId}` | user | The artist's own picture, like an album cover. `404` if there's none |
| `GET /api/tracks/{trackId}/credits` | user | Who did what: `{ "credits": [{ "role", "name", "detail" }] }`, `role` one of `composer`, `lyricist`, `writer`, `producer`, `arranger`, `vocal`, `instrument` (`detail`: which), `performer`, `programming`, `remixer`, `mix`, `engineer`, `recording`, in that order. From the file's composer tag and, when the lookups are on, MusicBrainz (asked the first time, by the file's MusicBrainz ID or ISRC, then kept). `404` unknown track |
| `GET /api/lyrics/{trackId}` | user | `{ "lyrics" }` from the file's tags (up to 100,000 characters), `404` if there are none. The server never looks online; the players ask LRCLIB themselves |

## Remote control

`GET /api/remote` upgrades to a WebSocket (user role, sign-in token in the header only: no stream token, no `?token=`).
Through it the players of one account see each other and send each other commands, a player can play on another
account's shared player on the same network (the same public address, or both on the server's side: private, loopback,
link-local, Tailscale), and players of different accounts [listen together](#listen-together). The server relays the
messages and stores none.

- A plain `GET`: `426`.
- A request from a web page (with an `Origin` header): `403`.
- An account that already has 40 connections: `429`.

Every message is a JSON text object with a `type`, at most 64 K characters.

| Message | Sent by | |
|---|---|---|
| `{ "type": "hello", "device": { "id", "name", "kind", "sharing" } }` | player | First, within 10 seconds. `id`: the player's permanent ID (up to 128 characters). `name`: up to 64, may be empty. `kind`: `desktop`, `phone`, `tablet` or `tv`. `sharing`: whether other accounts may play here, `off` (the default), `unhidden` (the player leaves out what its account hides) or `any`. Sending hello again renames the device or changes `sharing` |
| `{ "type": "state", "state" }` | player | What it's playing (below). Sent to the others, including players that connect later |
| `{ "type": "command", "to", "command" }` | player | For another player of the account, or another account's that `devices` lists, by ID. Ignored if that player is offline |
| `{ "type": "devices", "devices": [{ "id", "name", "kind", "account" }] }` | server | The account's other online players, and the other accounts' that share (`sharing` not `off`), whenever that changes. `account` (`{ "id", "username" }`) only on another account's. Never one of an account that blocks this one, or that this one blocks |
| `{ "type": "state", "device", "state" }` | server | Another player's state |
| `{ "type": "command", "from", "command", "account" }` | server | A command for this player. `account` (`{ "id", "username" }`) only when another account sent it |
| `{ "type": "dataChanged" }` | server | The account's favorites, playlists or hidden items changed (play counts aren't announced): download `/api/me/data` again. Not sent to the player that made the change, if it sent its device ID in an `X-Wiretune-Device` header with that request |
| `{ "type": "libraryChanged" }` | server | A scan changed `/api/tracks` or `/api/artists/pictures` (music added, changed or removed, a new cover or artist picture): download them again. Sent to every player of every account |
| `{ "type": "accountChanged" }` | server | The account was renamed: download `/api/auth/me` again |
| `{ "type": "playlistInvitesChanged" }` | server | The account's invitations to playlists changed: download `/api/me/playlist-invites` again. Not sent to the player that made the change, as for `dataChanged` |
| `{ "type": "blendsChanged" }` | server | The account's Blends changed: one was asked for, accepted or left: download `/api/me/blends` again. Not sent to the player that made the change, as for `dataChanged` |
| `{ "type": "recommendationsChanged" }` | server | What the account was recommended changed: one came or was taken back, or the bell was opened on another of its players: download `/api/me/recommendations` again. Not sent to the player that made the change, as for `dataChanged` |

A **state** is `{ "track", "playing", "positionMs", "volume", "muted", "volumeLocked", "shuffle", "repeat", "queue",
"queueIndex", "playingFor" }`:

- `track`: as `/api/tracks` lists it, or `null`
- `positionMs`: the position when the state was sent (the others count on from there while it plays)
- `volume`: 0 to 100
- `repeat`: `off`, `all` or `one`
- `queue`: up to 1,000 track IDs, with `queueIndex` for the current one (or -1)
- `playingFor`: the ID of the account whose music plays, when another account started it; left out otherwise. That
  account's player counts the plays, not this one

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

## Listen together

Over the same WebSocket, players of different accounts listen together: a host's music plays on its members' players,
each streaming the files itself. A group ends when its host leaves, or when its host's connection dropped and didn't
come back within 20 seconds.

| Message | Sent by | |
|---|---|---|
| `{ "type": "time", "t" }` | player | Asks the server's clock; `t` is the player's own. The answer: `{ "type": "time", "t", "server" }` (milliseconds since 1970) |
| `{ "type": "listenStart", "invite": [accountId] }` | player | Starts a group with this player as its host, inviting up to 50 accounts. A host that sends it again only invites |
| `{ "type": "listenInvite", "invite": [accountId] }` | host | Invites more |
| `{ "type": "listenJoin", "group" }` | player | Joins a group its account was invited to (up to 20 members), leaving any other |
| `{ "type": "listenLeave" }` | player | Leaves; the host's leaving ends the group |
| `{ "type": "listenState", "state" }` | host | What it plays (below). The server keeps the latest for members that join later |
| `{ "type": "listenCommand", "command" }` | member | A request for the host, a command as in remote control. Hosts carry out `next`, `previous`, `seek`, `playIndex`, `moveTrack`, `removeTrack`, `shuffle`, `repeat`, `playNext` and `addToQueue` |
| `{ "type": "listen", "group" }` | server | The player's group, whenever it changes: `{ "id", "host", "members": [...] }`, each `{ "accountId", "username", "deviceId", "deviceName" }`. `null` for none, also right after hello |
| `{ "type": "listenInvites", "invites": [{ "group", "host": { "id", "username" } }] }` | server | The groups that invite the player's account, after hello and whenever that changes |
| `{ "type": "listenState", "state" }` | server | The host's state, for a member |
| `{ "type": "listenCommand", "from", "command" }` | server | A member's request, with its username, for the host |

A **listen state** is `{ "queue", "queueIndex", "playing", "positionMs", "at" }`: up to 1,000 track IDs and the current
one's index, and the position at `at` (the server's clock, milliseconds since 1970). Members count on from there while
the host plays, and seek when they are more than 150 ms off.

## Error codes

| Code | Status | |
|---|---|---|
| `signInRequired`, `tokenInvalid`, `sessionExpired`, `passwordChanged`, `accountRemoved` | 401 | No token; a token this server didn't sign or that doesn't belong here; expired; issued before the password changed; a deleted account |
| `wrongCredentials` | 401 | Wrong user name or password |
| `signInCodeInvalid` | 401 | A sign-in code that is wrong, used, expired, or older than the password |
| `adminOnly` | 403 | An administrator's route |
| `rateLimited` | 429 | With `retryAfter` (seconds), also as the `Retry-After` header |
| `credentialsRequired`, `usernameInvalid` (`max`), `passwordTooShort` (`min`), `passwordTooLong` (`max`, in bytes) | 400 | Account rules |
| `alreadySetUp` (409), `setupCodeWrong` (403), `usernameTaken` (409), `userNotFound` (404), `cannotDeleteSelf` (400), `cannotResetOwnPassword` (400), `renameNotAllowed` (403) | | Accounts |
| `folderRequired`, `folderInvalid`, `folderMissing` (`path`), `folderUnreadable` (`path`), `folderWholeDisk`, `folderSystem`, `folderServerData` | 400 | The music folder |
| `invalidId`, `invalidItemType`, `playlistInvalid`, `playlistNameRequired`, `playlistNameTooLong` (`max`), `playlistDescriptionTooLong` (`max`), `playlistTooManyTracks` (`max`) | 400 | The account's data |
| `favoritesLimit`, `playCountsLimit`, `playlistsLimit`, `hiddenLimit` (all with `limit`) | 409 | The account's limits |
| `recommendationNoteTooLong` (`max`), `recommendationRecipientsInvalid` (`max`) | 400 | Recommendations |
| `playlistNotFound`, `recommendationNotFound`, `notFound` | 404 | |
| `unknownRoute` | 404 | The server has no such route: it's older than the player that asked. The players say so |
| `invalidPeriod` | 400 | `from` and `to` missing, unreadable, or in the wrong order |
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
