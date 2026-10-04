# Running the server

One program, one music folder (read, never written), its own SQLite database, and the HTTP API in [api.md](api.md).
Going anywhere near a network you don't fully trust? Read [SECURITY.md](../SECURITY.md) first.

## Start it

```bash
cd server
dart run bin/wiretune_server.dart --Wiretune:LibraryPath=/srv/music
```

It listens on port 5200 on every IPv4 interface, scans the folder, and waits for the first account. Until someone
creates it, every start logs a line like this, and the player will ask for that code:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

For a server that stays up, build the standalone executable ([building.md](building.md#server)) and run
`build/bundle/bin/wiretune_server` with the same options. `--help` lists them.

Coming from the C# server? Point the new one at the same data directory: accounts, favourites, playlists and even the
old tokens carry over, so nobody has to sign in again.

## Configuration

Settings come from `appsettings.json` (section `Wiretune`, in the working directory or next to the executable), then
environment variables (`Wiretune__Port=8080`), then the command line (`--Wiretune:Port=8080`), and the last one wins.
The names are the C# server's, so an old configuration still works.

| Setting | Default | |
|---|---|---|
| `Wiretune:LibraryPath` | your Music folder | The music folder. Empty or missing, your Music folder is used, with a warning. A folder an administrator picks in the player is saved, and wins after a restart as long as it still exists. |
| `Wiretune:DataDirectory` | [see below](#data-directory) | Database, cover cache and log. |
| `Wiretune:Port` | `5200` | Ignored when `WIRETUNE_URLS` is set. |
| `Wiretune:ScanIntervalMinutes` | `30` | Background rescans; `0` turns them off. |
| `Wiretune:SetupCode` | random | The first account's code. Unset, it's a new one at every start. Case, spaces and dashes don't matter. |

| Environment variable | |
|---|---|
| `WIRETUNE_DATA_DIR` | Root of Wiretune's data; the server uses its `Server` subfolder, so it never shares a database with a player. `Wiretune:DataDirectory` wins. |
| `WIRETUNE_URLS` (or `ASPNETCORE_URLS`, `--urls=`) | Listen addresses, separated by `;`: `http://127.0.0.1:5200` for loopback only, `http://[::]:5200` for every interface, IPv6 included. No HTTPS; that's the proxy's job. |
| `WIRETUNE_FORWARDED_HEADERS` (or `ASPNETCORE_FORWARDEDHEADERS_ENABLED`) | `true` behind a reverse proxy ([below](#reverse-proxy-and-tls)). |
| `WIRETUNE_LOG_LEVEL` | `trace`, `debug`, `info` (default), `warn` or `error`. |

## Data directory

`~/.config/Wiretune/Server` on Linux, `%APPDATA%\Wiretune\Server` on Windows,
`~/Library/Application Support/Wiretune/Server` on macOS, unless you moved it. The first lines of the log name it.

- `wiretune-server.db`, with its `-wal` and `-shm`: the index, the accounts, everyone's favourites, play counts and
  playlists, and the token-signing key.
- `Covers/`: art pulled out of tags. Any scan rebuilds it.
- `wiretune-server.log`: moved to `.1` at 10 MiB.

Every change is on disk the moment it's made, so a restart loses nothing. A *different* data directory loses
everything: a container without a volume or a changed `WIRETUNE_DATA_DIR`, and the server starts fresh and asks for a
setup code again. Keep it on persistent storage.

**Back up the database.** A scan rebuilds the index, but nothing rebuilds the accounts, the signing key and
everybody's playlists. Stop the server first, or copy the `.db` together with its `-wal` and `-shm` files.

Upgrades take care of themselves: an older database is migrated in place on the first start. Back it up anyway, and
once a newer server has opened it, don't go back to an older one.

## Scanning

At start-up, every `ScanIntervalMinutes`, on **Reindex** and whenever the music folder changes. Scans are incremental:
files with the same path, size and modification time aren't read again, vanished files drop out, and hidden and
unreadable ones are skipped.

The extension decides what's indexed: FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis and
Opus. A file whose extension lies is recognised by its content. Missing tags fall back to the file name,
`Unknown artist` and `Unknown album`. Whether a file also *plays* depends on the player ([audio.md](audio.md)).

If the folder the index came from suddenly looks empty, the scan is skipped with *Library folder is empty (unmounted
share?)*: an unmounted NAS shouldn't wipe your library. Pointing the server at a new, empty folder on purpose does
clear it.

**Track IDs** come from each file's full path, lower-cased, exactly as the C# server made them. Moving or renaming a
file gives it a new ID, and the favourites and playlist entries of the old one point at nothing. Two files in one
folder whose names differ only in case share an ID, so only one of them shows up.

## Accounts

- **The first account** is made from the player's sign-in screen with the setup code, and it's the administrator.
  After that, the code is never used again.
- **Everyone else** is added and removed by the administrator (*Settings → Users*). They're regular users: nobody gets
  promoted, and the administrator can't delete their own account.
- **Rules**: names up to 64 characters, unique ignoring case; passwords from 8 characters up to 72 bytes. bcrypt would
  quietly ignore anything longer, so longer ones are refused.
- **Tokens** last 24 hours, or 90 days with *Keep me signed in*. Audio URLs carry a separate 8-hour stream token that
  the players renew themselves. Deleting a user locks them out at once.
- **Per-account data**: favourites, play counts and playlists live on the server, are the same on every device, and go
  when the account goes. Limits: 100,000 favourites, 100,000 tracks with play counts, 500 playlists.
- **Rate limit**: setup, sign-in and password changes share 10 requests a minute per address, then `429`.
- **Changing a password**: `POST /api/auth/change-password` with the current one; the players have no screen for it
  yet. Earlier tokens keep working until they expire, so to cut a device off right now, delete the account.
- **Lost the admin password?** There's no reset. Stop the server, delete the rows of the `users` table in
  `wiretune-server.db`, start it again and set it up afresh. Everyone starts over, and the old accounts' favourites and
  playlists become unreachable.

## Running it as a service

A systemd unit for a bundle copied to `/opt/wiretune`:

```ini
# /etc/systemd/system/wiretune.service
[Unit]
Description=Wiretune server
After=network-online.target

[Service]
User=wiretune
WorkingDirectory=/opt/wiretune
ExecStart=/opt/wiretune/bin/wiretune_server
Environment=Wiretune__LibraryPath=/srv/music
Environment=WIRETUNE_DATA_DIR=/var/lib/wiretune
StateDirectory=wiretune
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin wiretune
sudo systemctl daemon-reload
sudo systemctl enable --now wiretune
journalctl -u wiretune -f        # the setup code shows up here on the first start
```

The server keeps its files in `/var/lib/wiretune/Server`, and the `wiretune` user needs nothing but read access to the
music. `systemctl stop` shuts it down cleanly; a scan that's running is dropped and runs again at the next start.

## Reverse proxy and TLS

The server doesn't do TLS. Put a proxy in front of it that does, or reach it over a VPN such as WireGuard or
Tailscale; the players take `https://` addresses. With [Caddy](https://caddyserver.com), which fetches the certificate
by itself, the whole proxy is:

```
music.example.com {
    reverse_proxy 127.0.0.1:5200
}
```

Then run the server with `WIRETUNE_URLS=http://127.0.0.1:5200`, so nothing reaches it except through the proxy, and
`WIRETUNE_FORWARDED_HEADERS=true`, so each player gets its own sign-in limit instead of everyone sharing the proxy's.

That second setting makes the server believe `X-Forwarded-For` from anyone who can reach it, which is exactly why the
port mustn't be reachable directly. It uses the last address in the header, the one your proxy added; anything a client
wrote there itself is ignored. Behind two proxies in a row, that's the outer proxy's address, unless the inner one is
told to put the client's there (nginx's `real_ip` module, for example).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The log says the music folder doesn't exist | `Wiretune:LibraryPath` (or the folder picked in the player) is wrong, or the drive isn't mounted. |
| The library is empty, but the folder has music | Check the extensions, hidden (dot) folders and the service account's permissions; the log lists unreadable files. |
| *Library folder is empty (unmounted share?)* | The folder the index came from is empty now. Mount the share again. |
| The player says it isn't a Wiretune server | Something answered, but not Wiretune: a wrong port, or a proxy's error page. |
| `429 Too many attempts` | More than 10 sign-ins, setups or password changes in a minute from one address. Wait a minute, or see [above](#reverse-proxy-and-tls) if there's a proxy. |
| Someone has to sign in again | The account was re-created, the token expired, or the database (and with it the signing key) was replaced. |
| The setup screen is back, or favourites vanished after a restart | The server is using a different data directory. Compare the one named at the top of the log with the one you expect. |
| `Failed to load dynamic library … sqlite3` | The executable was copied without the `lib/` folder of its bundle. Copy the whole bundle. |
