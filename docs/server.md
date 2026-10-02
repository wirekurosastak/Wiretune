# Running the server

`Wiretune.Server` indexes one music folder and serves it to Wiretune players. It is an ordinary ASP.NET Core
application: it only reads the music folder, keeps its own SQLite database, and speaks HTTP ([api.md](api.md)).
Read [SECURITY.md](../SECURITY.md) before putting it on a network you do not fully trust.

## Starting it

```bash
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/srv/music
```

It listens on `http://0.0.0.0:5200`, scans the folder, and waits for the first player to create the
administrator account. For a deployment, publish it:

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

Environment variables:

| Variable | Meaning |
|---|---|
| `WIRETUNE_DATA_DIR` | Root of Wiretune's data. The server uses its `Server` subfolder (a desktop player on the same machine uses the root, so they never share a database). `Wiretune:DataDirectory` wins when set. |
| `ASPNETCORE_URLS` | Standard listen addresses, e.g. `http://127.0.0.1:5200` for loopback only. |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | `true` behind a reverse proxy, see [below](#reverse-proxy-and-tls). |

## Data directory

| File | Content |
|---|---|
| `wiretune-server.db` | SQLite database: track index, accounts, the token-signing key, and the library folder chosen through the API |
| `Covers/` | Cover images extracted from tags; rebuilt by scanning |
| `wiretune-server.log` | Log; moved to `.1` at 10 MiB (one backup) |

Back up `wiretune-server.db` while the server is stopped. The index and covers can be rebuilt, but accounts and
the signing key cannot: without them every user has to be created again and every player has to sign in again.

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
Lyrics are read on request from the file's tag; there is no lookup service.

If the index is not empty and the folder it was built from suddenly contains nothing, the scan is skipped with
*Library folder is empty (unmounted share?)* and the old index is kept. Pointing the server at a different, empty
folder is deliberate and does clear the index.

**Track IDs** are derived from the file's full path (lower-cased). Moving or renaming a file, or changing the
library folder, gives its tracks new IDs, and players lose the favourites, play counts and playlist entries
attached to the old ones.

## Accounts

- A fresh server has no accounts. The first call to `POST /api/auth/setup` (the player's sign-in screen makes it)
  creates the administrator, works once, and answers `409` afterwards.
- Only the administrator creates or deletes users (desktop player: *Settings → Users*), and every account created
  that way is a regular user. There is no way to promote one. An administrator cannot delete their own account.
- **Rules**: user names up to 64 characters, no control characters, unique ignoring case; passwords at least 8
  characters and at most 72 bytes (bcrypt silently ignores the rest, so longer ones are rejected).
- **Tokens** (JWT) last 24 hours, or 90 days with *Keep me signed in*; the setup call returns a 90-day token.
  Deleting a user cuts off access immediately.
- **Rate limit**: setup and sign-in together, 10 requests per minute per client address, then `429` with
  `Retry-After`.
- **No password change or reset.** If the administrator password is lost, stop the server and delete the rows of
  the `users` table in `wiretune-server.db`; the setup screen is offered again. Other users can be deleted and
  created again by an administrator.

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
