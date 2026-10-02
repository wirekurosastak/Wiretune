# Running the server

`Wiretune.Server` indexes one music folder and serves it to Wiretune clients. It is an ordinary ASP.NET Core
application: it reads the music folder (it never writes to it), keeps its own SQLite database, and speaks HTTP.
The HTTP API is documented in [api.md](api.md); security considerations are collected in
[../SECURITY.md](../SECURITY.md).

## Starting it

```bash
dotnet run --project Wiretune.Server -- --Wiretune:LibraryPath=/srv/music
```

By default it listens on `http://0.0.0.0:5200` (all interfaces). On the first start the music folder is scanned
and the server waits for the first client to create the administrator account (see [Accounts](#accounts)).

For a deployment, publish it first:

```bash
dotnet publish Wiretune.Server -c Release -o /opt/wiretune
dotnet /opt/wiretune/Wiretune.Server.dll
```

Use `-r <runtime-id> --self-contained` on `dotnet publish` for a build that needs no installed .NET runtime
(use the runtime identifier of the target machine).

## Configuration

Settings live in `Wiretune.Server/appsettings.json` under the `Wiretune` section and can be overridden the
usual ASP.NET Core way: command line (`--Wiretune:Port=8080`) or environment variable (`Wiretune__Port=8080`).

| Key | Default | Meaning |
|---|---|---|
| `Wiretune:LibraryPath` | empty | Music folder, absolute or relative to the server's content root (the working directory it was started in). If empty, or if the folder does not exist, the server tries the user's Music folder instead and logs a warning. A folder chosen by an administrator through the API or the client is stored in the database and takes precedence over this setting after a restart (as long as it still exists). |
| `Wiretune:DataDirectory` | empty | Folder for the server's database, cover cache and log. Empty: `<user application data>/Wiretune/Server` (on Linux `~/.config/Wiretune/Server`, on Windows `%APPDATA%\Wiretune\Server`). |
| `Wiretune:ScanIntervalMinutes` | `30` | Interval of the background rescan. `0` disables it; the start-up scan and requested scans still run. |
| `Wiretune:Port` | `5200` | HTTP port. Ignored when `--urls` or `ASPNETCORE_URLS` is set. |

Other environment variables:

| Variable | Meaning |
|---|---|
| `WIRETUNE_DATA_DIR` | Root of Wiretune's data. The server uses its `Server` subfolder; a desktop client on the same machine uses the root itself, so the two never share a database. `Wiretune:DataDirectory`, when set, wins and is used as is. |
| `ASPNETCORE_URLS` | Standard ASP.NET Core listen addresses, e.g. `http://127.0.0.1:5200` to listen on loopback only (useful behind a reverse proxy). |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | Set to `true` behind a reverse proxy so client addresses come from `X-Forwarded-For` (see [Reverse proxy](#reverse-proxy-and-tls)). |

The server also limits request bodies to 64 KiB (it never accepts uploads) and compresses JSON responses.

## Data directory

| File | Content |
|---|---|
| `wiretune-server.db` (+ `-wal`, `-shm`) | SQLite database: the track index, user accounts (bcrypt hashes), the token-signing key (`jwt_secret`) and the library folder chosen through the API (`library_path`). |
| `Covers/` | Cover images extracted from embedded tags (`cover_<hash>.jpg` / `.png`). Rebuilt by scanning. |
| `wiretune-server.log` | Log. When it passes 10 MiB it is moved to `wiretune-server.log.1` (one backup is kept). |

A data directory created by the server is private to the current user on Linux (`rwx------`). An existing
directory is left as the administrator set it up. The database holds the signing key for access tokens, so
anyone who can read it can issue valid tokens: keep the directory readable only by the service account.

To back the server up, copy `wiretune-server.db` while the server is stopped. The index and covers can be
rebuilt by scanning, but accounts and the signing key cannot; without them every user has to be created again
and every client has to sign in again.

## Library and scanning

The server scans the music folder recursively:

- at start-up,
- every `ScanIntervalMinutes` minutes (default 30),
- when an administrator requests it (**Reindex** in the desktop client, `POST /api/library/scan`),
- after an administrator changes the library folder.

Only one scan runs at a time. Scans are incremental: a file whose path, size and modification time match the
previous index is not read again (unless its cached cover image has disappeared). Files that no longer exist drop
out of the index. Hidden and system files and folders are skipped (on Linux that means names starting with a
dot). Files that cannot be read are skipped, and the log says how many.

What is indexed is determined by the file extension; see the table in [README.md](../README.md#platform-support).
Tags are read with TagLibSharp. Missing tags are handled like this: no title uses the file name; no artist uses
the album artist, then `Unknown artist`; no album uses `Unknown album`. These two placeholder names are stored in
the library and are not translated.

**Cover art** is taken from the first embedded picture of a file (cached under `Covers/`, one image per
album-artist/album pair), otherwise from an image in the file's folder named `cover`, `folder` or `front` with
extension `.jpg`, `.jpeg` or `.png`, or named `albumart.jpg` or `artwork.jpg`.

**Lyrics** are read on request from the file's own lyrics tag (plain text, at most 100,000 characters). There is no
lookup service.

**Safety checks.** Streaming and cover requests only serve files that lie inside the library folder. If the
index is not empty and the library folder (the one the index was built from) is suddenly empty, the scan is
skipped with the message *Library folder is empty (unmounted share?)* and the existing index is kept, so an
unmounted network share does not wipe the library. Pointing the server at a different, empty folder is
deliberate and does clear the index.

**Track identity.** A track's ID is derived from its full file path (lower-cased). Moving or renaming a file, or
changing the library folder, gives its tracks new IDs. Clients keep favourites, play counts and playlist entries
by track ID, so those are lost for tracks whose IDs changed.

## Accounts

- A fresh server has no accounts. The first call to `POST /api/auth/setup` (made by the client's sign-in screen)
  creates the administrator and works exactly once; afterwards it answers `409`.
- Only the administrator can create or delete users (desktop client: **Settings → Users**). Every account
  created that way is a regular user. There is no way to promote a user to administrator.
- Rules: user names are at most 64 characters without control characters and are unique regardless of case;
  passwords are at least 8 characters and at most 72 bytes (the limit of bcrypt, which silently ignores
  anything beyond it, so longer passwords are rejected instead).
- Access tokens (JWT, HMAC-SHA256) are valid for 24 hours, or 90 days when the user ticks *Keep me signed in*.
  The administrator created by the setup call receives a 90-day token. Deleting a user ends that user's access
  immediately, even if the token has not expired. An administrator cannot delete their own account.
- Sign-in and setup requests are limited to 10 per minute per client address (counted together). Excess requests
  get `429` with a `Retry-After` header.
- There is no password change or reset. To recover access when the administrator password is lost, stop the
  server and delete the rows of the `users` table in `wiretune-server.db`; once it is empty the setup screen is
  offered again. Other users can simply be deleted and created again by an administrator.

## Running as a service

On Linux, a systemd unit for a published build:

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

`StateDirectory=wiretune` makes systemd create `/var/lib/wiretune` for the service account; with
`WIRETUNE_DATA_DIR` set as above the server keeps its files in `/var/lib/wiretune/Server`. The `wiretune` user
needs read access to the music folder and nothing else.

## Reverse proxy and TLS

The server does not terminate TLS. To use it outside a trusted network, put a reverse proxy that does (Caddy,
nginx, …) in front of it, or reach it through a VPN such as WireGuard or Tailscale. Clients accept `https://`
addresses.

Behind a proxy, set `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`; otherwise every client appears with the proxy's
address and the sign-in limit applies to all of them together. Enabling it makes the server believe the
`X-Forwarded-*` headers from any sender, so combine it with listening on loopback only (`ASPNETCORE_URLS`) or a
firewall that lets only the proxy reach the port; otherwise a client can forge its address and sidestep the
sign-in limit.

Players that cannot send headers (`ffplay`, the Android player) pass the token as `?token=` on stream and cover
URLs. Keep the proxy's access logs private, because those URLs contain a credential. See
[../SECURITY.md](../SECURITY.md).

## Troubleshooting

| Symptom | Cause and remedy |
|---|---|
| The log says the library folder does not exist | `Wiretune:LibraryPath` (or the folder saved by an administrator) is wrong or the drive is not mounted. The server falls back to the user's Music folder when it can; check the first lines of `wiretune-server.log`. |
| Library is empty although the folder has music | Check the file extensions against the supported list, hidden folders (dot-names), and the permissions of the service account. The log reports files that could not be read. |
| *Library folder is empty (unmounted share?)* | The index was built from this folder and it is now empty; the existing index is kept. Mount the share again. |
| Client says the address is not a Wiretune server | The address answered, but not with a Wiretune response (wrong port, or a proxy error page). |
| `429 Too many attempts` | More than 10 sign-in/setup requests in a minute from one address. Wait a minute. Behind a proxy, see above. |
| A user suddenly has to sign in again | Their account was deleted and re-created, the token expired, or the server's database (and with it the signing key) was replaced. |
