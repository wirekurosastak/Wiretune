# Running the server

`Wiretune.Server` indexes one music folder and serves it to Wiretune players. It is an ordinary ASP.NET Core
application: it only reads the music folder, keeps its own SQLite database, and speaks HTTP ([api.md](api.md)).
Read [SECURITY.md](../SECURITY.md) before putting it on a network you do not fully trust.

## Starting it

```bash
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/srv/music
```

It listens on `http://0.0.0.0:5200`, scans the folder, and waits for the first player to create the
administrator account. Until that exists it prints a line like `No administrator account exists yet. Create it in the
player with the setup code K7QP-2WXM` in its log: the player asks for that code ([Accounts](#accounts)). For a
deployment, publish it:

```bash
dotnet publish Wiretune.Server -c Release -o /opt/wiretune
dotnet /opt/wiretune/Wiretune.Server.dll
```

Add `-r <runtime-id> --self-contained` to publish a build that needs no installed .NET runtime.

## Configuration

Settings are in `Wiretune.Server/appsettings.json` under `Wiretune` and can be overridden on the command line
(`--Wiretune:Port=8080`) or by environment variable (`Wiretune__Port=8080`).

| Key | Default | Meaning |
|---|---|---|
| `Wiretune:LibraryPath` | empty | Music folder, absolute or relative to the server's working directory. If empty or missing, the user's Music folder is tried and a warning is logged. A folder an administrator chose through the API or the player is stored in the database and takes precedence after a restart, as long as it still exists. |
| `Wiretune:DataDirectory` | empty | Folder for the database, cover cache and log. Empty: `~/.config/Wiretune/Server` on Linux, `%APPDATA%\Wiretune\Server` on Windows. |
| `Wiretune:ScanIntervalMinutes` | `30` | Background rescan interval. `0` disables it (start-up and requested scans still run). |
| `Wiretune:Port` | `5200` | HTTP port. Ignored when `--urls` or `ASPNETCORE_URLS` is set. |
| `Wiretune:SetupCode` | empty | The code needed to create the first account. Empty: a random one is generated at every start and printed in the log for as long as no account exists. Case, spaces and dashes do not matter when it is typed. |

Environment variables:

| Variable | Meaning |
|---|---|
| `WIRETUNE_DATA_DIR` | Root of Wiretune's data. The server uses its `Server` subfolder (a desktop player on the same machine uses the root, so they never share a database). `Wiretune:DataDirectory` wins when set. |
| `ASPNETCORE_URLS` | Standard listen addresses, e.g. `http://127.0.0.1:5200` for loopback only. |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | `true` behind a reverse proxy, see [below](#reverse-proxy-and-tls). |

## Data directory

| File | Content |
|---|---|
| `wiretune-server.db` | SQLite database: track index, accounts, **each account's favourites, play counts and playlists**, the token-signing key, and the library folder chosen through the API |
| `wiretune-server.db-wal`, `-shm` | SQLite's write-ahead log; part of the database while the server runs (see below) |
| `Covers/` | Cover images extracted from tags; rebuilt by scanning |
| `wiretune-server.log` | Log; moved to `.1` at 10 MiB (one backup) |

**Everything in the database survives a restart of the server**: every change is written to disk when it is made;
nothing is kept only in memory, and a restart only reloads the index from the database and rescans. What does *not*
survive is a data directory that is gone or different: a container without a persistent volume, a changed
`WIRETUNE_DATA_DIR`, a `StateDirectory` the service user cannot write. The server then starts empty, as a fresh
installation (and asks for the setup code again), so mount the data directory on persistent storage and check the
first log lines, which name it.

The index and covers can be rebuilt by scanning. Accounts, the signing key and the per-account data cannot: without
them every user has to be created again, every player has to sign in again, and favourites and playlists are gone.
Back up while the server is stopped, or copy `wiretune-server.db` together with its `-wal` and `-shm` files (copying
only the `.db` of a running server can miss the latest changes).

**Upgrading** needs nothing from you: the schema version is kept in the database (`PRAGMA user_version`, currently 4)
and an older database is upgraded in place the first time the new server starts. Back it up first all the same, and
note that a database written by a newer server must not be opened by an older one.

## Library and scanning

The server scans the folder recursively at start-up, every `ScanIntervalMinutes`, when an administrator asks
(**Reindex**, `POST /api/library/scan`) and after the library folder is changed. One scan runs at a time. Scans are
incremental: a file with the same path, size and modification time is not read again. Files that disappeared drop
out of the index; hidden and system files (on Linux, names starting with a dot) and unreadable files are skipped.

What is indexed is decided by the extension: FLAC, WAV, AIFF/AIF, WavPack, APE and DSF (all labelled lossless),
M4A (ALAC when the stream says so, otherwise AAC), AAC, MP3, Ogg Vorbis and Opus (`AudioFileTypes.cs`). Whether a
file also *plays* depends on the player's platform ([audio.md](audio.md)). Tags are read with TagLibSharp. A missing title becomes the file name, a missing artist the album artist and then
`Unknown artist`, a missing album `Unknown album` (not translated). Cover art is the first embedded picture
(cached in `Covers/`), otherwise a folder image as described in the [user guide](user-guide.md#how-the-library-is-organised).
Lyrics are read on request from the file's tag. The server never goes to the internet for them: a player that wants
lyrics for a track without any asks the public LRCLIB database itself ([user guide](user-guide.md#playing-music)).

If the index is not empty and the folder it was built from suddenly contains nothing, the scan is skipped with
*Library folder is empty (unmounted share?)* and the old index is kept. Pointing the server at a different, empty
folder is deliberate and does clear the index.

**Track IDs** are derived from the file's full path (lower-cased). Two limits follow:

- Moving or renaming a file, or changing the library folder, gives its tracks new IDs. The favourites, play counts and
  playlist entries of the old IDs stay in the database, but they no longer point at anything in the library, and the
  tracks start over. There is no tool that moves them across.
- Two files in one folder whose names differ only in case (`A.flac`, `a.flac`) get the same ID, so only one of them
  appears in the library. Only file systems that distinguish case, such as Linux ones, allow this.

Album covers are fetched per album (`/api/cover/album/{id}`), where the album is the title plus the album artist.

## Accounts

- A fresh server has no accounts. The first call to `POST /api/auth/setup` (the player's sign-in screen makes it)
  creates the administrator, works once, and answers `409` afterwards. It also needs the **setup code** from the
  server's log (or `Wiretune:SetupCode`), and answers `403` without it: this keeps a server that accidentally starts
  empty, because of a wrong data path or an unmounted volume, from being taken over by whoever connects first. Once an
  account exists the code is not used again.
- Only the administrator creates or deletes users (desktop player: *Settings → Users*), and every account created
  that way is a regular user. There is no way to promote one. An administrator cannot delete their own account.
- **Rules**: user names up to 64 characters, no control characters, unique ignoring case; passwords at least 8
  characters and at most 72 bytes (bcrypt silently ignores the rest, so longer ones are rejected).
- **Tokens** (JWT) last 24 hours, or 90 days with *Keep me signed in*; the setup call returns a 90-day token.
  Deleting a user cuts off access immediately. Players put a separate **stream token** (8 hours, audio and covers
  only) in stream URLs, and renew it themselves.
- **Per-account data.** Each account has its own favourites, play counts and playlists, kept on the server and
  therefore the same on every device the person signs in on. Deleting an account (*Settings → Users*) deletes its
  favourites, play counts and playlists with it; an account created afterwards starts empty. The first account that signs in on a device that
  already holds such data from before the server stored it receives it, once (it only adds; see
  `POST /api/me/data/import` in [api.md](api.md#your-data-per-account)). Limits per account: 100,000 favourites,
  100,000 tracks with statistics and 500 playlists (see the API page).
- **Rate limit**: setup and sign-in together, 10 requests per minute per client address, then `429` with
  `Retry-After`.
- **No password change or reset.** If the administrator password is lost, stop the server and delete the rows of
  the `users` table in `wiretune-server.db`; the setup screen is offered again (with the setup code). Accounts are
  new after that, so the favourites and playlists of the old ones are no longer reachable. Other users can be
  deleted and created again by an administrator, which also starts them empty.

## Running as a service

A systemd unit for a published build:

```ini
# /etc/systemd/system/wiretune.service
[Unit]
Description=Wiretune server
After=network-online.target

[Service]
User=wiretune
WorkingDirectory=/opt/wiretune
ExecStart=/usr/bin/dotnet /opt/wiretune/Wiretune.Server.dll
Environment=Wiretune__LibraryPath=/srv/music
Environment=WIRETUNE_DATA_DIR=/var/lib/wiretune
StateDirectory=wiretune
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`StateDirectory=wiretune` makes systemd create `/var/lib/wiretune` for the service account, and the server keeps
its files in `/var/lib/wiretune/Server`. The `wiretune` user needs read access to the music folder and nothing
else.

## Reverse proxy and TLS

The server does not terminate TLS. Put a reverse proxy that does (Caddy, nginx, …) in front of it, or use a VPN
such as WireGuard or Tailscale. Players accept `https://` addresses.

Behind a proxy set `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`, otherwise every player appears with the proxy's
address and shares one sign-in limit. That setting makes the server trust `X-Forwarded-*` from any sender, so also
make the server reachable only through the proxy (listen on loopback with `ASPNETCORE_URLS`, or firewall the port).

## Troubleshooting

| Symptom | Cause and remedy |
|---|---|
| Log says the library folder does not exist | `Wiretune:LibraryPath` (or the saved folder) is wrong or the drive is not mounted. The server falls back to the user's Music folder when it can; check the first lines of `wiretune-server.log`. |
| Library is empty although the folder has music | Check extensions, hidden (dot) folders and the service account's permissions; the log reports unreadable files. |
| *Library folder is empty (unmounted share?)* | The folder the index came from is now empty. Mount the share again. |
| Player says the address is not a Wiretune server | The address answered, but not like a Wiretune server (wrong port, or a proxy error page). |
| `429 Too many attempts` | More than 10 sign-in/setup requests in a minute from one address. Wait a minute; behind a proxy see above. |
| A user has to sign in again | The account was re-created, the token expired, or the database (and with it the signing key) was replaced. |
| The setup screen appears again, or favourites are gone after a restart | The server is using a different or empty data directory (a container without a volume, a changed path). Compare the data directory named at the top of the log with the one you expect. |
| *The setup code is missing or wrong* | Enter the code from the server's log (`No administrator account exists yet…`), or the value of `Wiretune:SetupCode`. |
