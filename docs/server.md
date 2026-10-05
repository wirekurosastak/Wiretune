# Running the server

One program, one music folder (read, never written), its own SQLite database, and the HTTP API in [api.md](api.md).
Going anywhere near a network you don't fully trust? Read [SECURITY.md](../SECURITY.md) first.

## Start it

```bash
cd server
dart run bin/wiretune_server.dart --library /srv/music
```

It listens on port 5200 on every IPv4 interface, scans the folder, and waits for the first account. Until someone
creates it, every start logs a line like this, and the player will ask for that code:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

For a server that stays up, build the standalone executable with `dart tool/build.dart server`
([building.md](building.md#server)) and run `dist/server/bin/wiretune_server` with the same options.

## Options

`--help` lists them. Every option can also be set in the environment, which suits services and containers: `--port
8080` is `WIRETUNE_PORT=8080`, `--trust-proxy` is `WIRETUNE_TRUST_PROXY=true`. The command line wins.

| Option | Default | |
|---|---|---|
| `--library <folder>` | your Music folder | The music folder, absolute or relative to the working directory. A folder an administrator picks in the player is saved, and wins after a restart as long as it exists. |
| `--data-dir <folder>` | [see below](#data-directory) | Where the database, cover cache and log live. |
| `--host <address>` | `0.0.0.0` | Where to listen: `0.0.0.0` for every IPv4 interface, `::` for every interface, `127.0.0.1` for this machine only. |
| `--port <number>` | `5200` | |
| `--scan-interval <minutes>` | `30` | Background rescans; `0` turns them off. |
| `--setup-code <code>` | random | The code that creates the first account; without it, a new one at every start. Case, spaces and dashes don't matter. |
| `--trust-proxy` | off | Take each client's address from `X-Forwarded-For`; only behind a reverse proxy ([below](#reverse-proxy-and-tls)). |
| `--log-level <level>` | `info` | `trace`, `debug`, `info`, `warn` or `error`. |

The server speaks plain HTTP; TLS is a proxy's job.

## Data directory

`~/.config/Wiretune/Server` on Linux, `%APPDATA%\Wiretune\Server` on Windows,
`~/Library/Application Support/Wiretune/Server` on macOS, unless `--data-dir` says otherwise. The first lines of the
log name it.

- `wiretune-server.db`, with its `-wal` and `-shm`: the index, the accounts, everyone's favourites, play counts and
  playlists, and the token-signing key.
- `Covers/`: art pulled out of tags. Any scan rebuilds it.
- `wiretune-server.log`: moved to `.1` at 10 MiB.

Every change is on disk the moment it's made, so a restart loses nothing. A *different* data directory loses
everything: a container without a volume or a changed `--data-dir`, and the server starts fresh and asks for a setup
code again. Keep it on persistent storage.

**Back up the database.** A scan rebuilds the index, but nothing rebuilds the accounts, the signing key and
everybody's playlists. Stop the server first, or copy the `.db` together with its `-wal` and `-shm` files.

The database records its schema version, and a server only opens its own: anything else is refused with a message
rather than misread. A release that changes the schema upgrades the database in place on its first start, and after
that an older server won't open it, so keep a backup from before an upgrade.

## Scanning

At start-up, every `--scan-interval` minutes, on **Reindex** and whenever the music folder changes. Scans are
incremental: files with the same path, size and modification time aren't read again, vanished files drop out, and
hidden and unreadable ones are skipped. A music folder that doesn't exist (yet) is reported by every scan until it
appears, so a share that mounts late is picked up by the next one.

The extension decides what's indexed: FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis and
Opus. A file whose extension lies is recognised by its content. Missing tags fall back to the file name,
`Unknown artist` and `Unknown album`. Whether a file also *plays* depends on the player ([audio.md](audio.md)).

If the folder the index came from suddenly looks empty, the scan is skipped with *Library folder is empty (unmounted
share?)*: an unmounted NAS shouldn't wipe your library. Pointing the server at a new, empty folder on purpose does
clear it.

**Track IDs** come from each file's full path. Moving or renaming a file gives it a new ID, and the favourites and
playlist entries of the old one point at nothing.

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
ExecStart=/opt/wiretune/bin/wiretune_server --library /srv/music --data-dir /var/lib/wiretune
StateDirectory=wiretune
StateDirectoryMode=0700
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

systemd creates `/var/lib/wiretune` for the service account, readable by nobody else: the database in it holds the
password hashes and the key that signs tokens. The `wiretune` user needs nothing but read access to the music.
`systemctl stop` shuts it down cleanly; a scan that's running is dropped and runs again at the next start.

## Reverse proxy and TLS

Put a proxy in front of the server that does TLS, or reach it over a VPN such as WireGuard or Tailscale; the players
take `https://` addresses. With [Caddy](https://caddyserver.com), which fetches the certificate by itself, the whole
proxy is:

```
music.example.com {
    reverse_proxy 127.0.0.1:5200
}
```

Then run the server with `--host 127.0.0.1`, so nothing reaches it except through the proxy, and `--trust-proxy`, so
each player gets its own sign-in limit instead of everyone sharing the proxy's.

Remote control between the players is a WebSocket (`/api/remote`). Caddy passes WebSockets on by itself; nginx needs
`proxy_http_version 1.1;`, `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";` in
its `location`. Both ends ping every 25 seconds, so idle timeouts of a minute or more don't cut it.

`--trust-proxy` makes the server believe `X-Forwarded-For` from anyone who can reach it, which is exactly why the port
mustn't be reachable directly. It uses the last address in the header, the one your proxy added; anything a client
wrote there itself is ignored. Behind two proxies in a row, that's the outer proxy's address, unless the inner one is
told to put the client's there (nginx's `real_ip` module, for example).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The log says the music folder doesn't exist | `--library` (or the folder picked in the player) is wrong, or the drive isn't mounted yet. The next scan after it appears picks it up. |
| The library is empty, but the folder has music | Check the extensions, hidden (dot) folders and the service account's permissions; the log lists unreadable files. |
| *Library folder is empty (unmounted share?)* | The folder the index came from is empty now. Mount the share again. |
| *… was made by another version of Wiretune* | The data directory holds a database this version doesn't read. Restore the matching version, or move the file away to start afresh. |
| *Cannot listen on …: Address already in use* | Something else (another Wiretune?) holds the port. Stop it, or pick another `--port`. |
| The player says it isn't a Wiretune server | Something answered, but not Wiretune: a wrong port, or a proxy's error page. |
| `429 Too many attempts` | More than 10 sign-ins, setups or password changes in a minute from one address. Wait a minute, or see [above](#reverse-proxy-and-tls) if there's a proxy. |
| Someone has to sign in again | The account was re-created, the token expired, or the database (and with it the signing key) was replaced. |
| The setup screen is back, or favourites vanished after a restart | The server is using a different data directory. Compare the one named at the top of the log with the one you expect. |
| `Failed to load dynamic library … sqlite3` | The executable was copied without the `lib/` folder of its bundle. Copy the whole bundle. |
