# Running the server

One program, one music folder (read-only), its own SQLite database, and the HTTP API in [api.md](api.md). Read
[SECURITY.md](../SECURITY.md) before exposing it to a network you don't fully trust.

## Start it

Build it ([building.md](building.md#server)), copy `dist/server` to the host, and run:

```bash
dist/server/bin/wiretune_server --library /srv/music
```

It listens on port 5200 on all IPv4 interfaces, scans the folder, and waits for the first account. Until that account
exists, every start logs the setup code the player asks for:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

[Docker](#docker) and [systemd](#running-it-as-a-service) are below.

## Options

`--help` lists them. Each can also be set in the environment (handy for services and containers): `--port 8080` is
`WIRETUNE_PORT=8080`, `--trust-proxy` is `WIRETUNE_TRUST_PROXY=true`. The command line wins.

| Option | Default | |
|---|---|---|
| `--library <folder>` | your Music folder | Music folder, absolute or relative to the working directory. A folder an administrator picks in the player is saved and takes precedence after a restart, even while missing (a share that mounts late), so the index isn't replaced by another folder's. |
| `--data-dir <folder>` | [see below](#data-directory) | Database, cover cache and log. |
| `--host <address>` | `0.0.0.0` | Listen address: `0.0.0.0` all IPv4, `::` all interfaces, `127.0.0.1` this machine only. |
| `--port <number>` | `5200` | |
| `--scan-interval <minutes>` | `30` | Background rescans; `0` disables them. |
| `--setup-code <code>` | random | Code that creates the first account; without it, a new one each start. Case, spaces and dashes are ignored. |
| `--trust-proxy` | off | Take the client address from `X-Forwarded-For`. Only behind a reverse proxy ([below](#reverse-proxy-and-tls)). |
| `--log-level <level>` | `info` | `debug`, `info`, `warn`, `error`. |

The server speaks plain HTTP; TLS is a proxy's job.

## Data directory

Location: [the table of folders](user-guide.md#where-things-are), or `--data-dir`. The first log lines name it. It holds:

- `wiretune-server.db` (plus `-wal` and `-shm`): the index, accounts, everyone's favorites, play counts and playlists,
  and the token-signing key.
- `Covers/`: pictures extracted from the files. Safe to delete; the next scan recreates them.
- `wiretune-server.log`: rotated to `.1` at 10 MiB.

Changes are written immediately, so a restart loses nothing. A *different* data directory loses everything (a container
without a volume, a changed `--data-dir`): the server starts fresh and asks for a setup code. Keep it on persistent
storage.

**Back up the database.** A scan rebuilds the index, but nothing rebuilds accounts, the signing key and playlists. Stop
the server first, or copy the `.db` together with its `-wal` and `-shm` files.

The database stores its schema version. A server upgrades an older database in place on first start and refuses a newer
one with a message. After an upgrade an older server can't open it, so back up before upgrading.

## Scanning

A scan runs at start-up, about ten seconds after files stop changing, every `--scan-interval` minutes (network shares
don't report changes from other machines), on **Reindex**, and when an administrator picks another folder. Scans are
incremental, and online players pick up changes at once.

An administrator can change the music folder in the player (*Settings → Server folder*).

Indexed: FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis, Opus. Missing tags fall back to the
file name, `Unknown artist` and `Unknown album`. Whether a file also *plays* depends on the player
([audio.md](audio.md)).

If the folder suddenly looks empty, the scan is skipped (*Library folder is empty (unmounted share?)*), so an unmounted
NAS doesn't wipe your library.

**Track IDs** come from each file's full path. Moving or renaming a file gives it a new ID, and favorites and playlist
entries for the old ID point at nothing.

## Accounts

- **First account**: created from the player's sign-in screen with the setup code; it's the administrator. The code is
  never used again.
- **Other accounts**: added and removed by the administrator (*Settings → Users*). They're regular users; nobody gets
  promoted, and the administrator can't delete their own account.
- **Rules**: names up to 64 characters, unique ignoring case. Passwords 8 characters to 72 bytes (bcrypt ignores
  anything longer, so longer ones are refused).
- **Per-account data**: favorites, play counts, playlists and hidden artists, albums and tracks live on the server, are
  the same on every device, and go when the account goes. Limits: 100,000 favorites, 100,000 tracks with play counts, 500
  playlists, 50,000 hidden items.
- **Password changes**: changing your own (in the player, without the current one) signs out the account's other
  devices. An administrator's reset of another account (*Settings → Users*) signs it out everywhere, which is how you cut
  off a lost phone. Sign-in and token details: [SECURITY.md](../SECURITY.md#server).
- **Lost the admin password?** There's no reset. Stop the server, delete the rows of the `users` table in
  `wiretune-server.db`, start it, and set up again. Everyone starts over, and the old accounts' favorites and playlists
  become unreachable.

## Docker

The image (`server/Dockerfile`, built from the repository root because it needs the core package) runs the server as an
unprivileged user, music at `/music`, data at `/data`:

```bash
docker build -f server/Dockerfile -t wiretune-server .
docker run -d --name wiretune -p 5200:5200 -v /srv/music:/music:ro -v wiretune-data:/data wiretune-server
docker logs wiretune        # the setup code, on the first start
```

Releases publish it as `ghcr.io/<owner>/wiretune-server`. Other options are `WIRETUNE_*` variables (`-e
WIRETUNE_SCAN_INTERVAL=0`). Keep `/data` on a volume: without one, every new container starts with an empty database.

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

The `wiretune` user only needs read access to the music. The data directory is private to it because the database holds
password hashes and the token-signing key.

## Reverse proxy and TLS

Put a TLS-terminating proxy in front of the server, or use a VPN (WireGuard, Tailscale). Players accept `https://`
addresses. With [Caddy](https://caddyserver.com), which gets the certificate itself, the whole config is:

```
music.example.com {
    reverse_proxy 127.0.0.1:5200
}
```

Then run the server with `--host 127.0.0.1` so it's reachable only through the proxy, and `--trust-proxy` so each player
gets its own sign-in rate limit instead of all sharing the proxy's.

Remote control needs WebSockets (`/api/remote`). Caddy passes them automatically; nginx needs
`proxy_http_version 1.1;`, `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";` in its
`location`.

`--trust-proxy` trusts `X-Forwarded-For` from anyone who can reach the server, so the port must not be reachable
directly.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Library is empty but the folder has music | Check extensions, hidden (dot) folders and the service account's permissions; the log lists unreadable files. |
| *… was made by another version of Wiretune* | The data directory holds a database this version can't read. Restore the matching version, or move the file away to start fresh. |
| *Cannot listen on …: Address already in use* | Something else (another Wiretune?) holds the port. Stop it or pick another `--port`. |
| Player says it isn't a Wiretune server | Something answered that isn't Wiretune: wrong port, or a proxy error page. |
| Everyone shares one sign-in limit behind a proxy | Run the server with `--trust-proxy` ([above](#reverse-proxy-and-tls)). |
| Every player had to sign in again after a restart | The database, and with it the token-signing key, was replaced. |
| Setup screen is back, or favorites vanished after a restart | The server is using a different data directory. Compare the one named at the top of the log with the one you expect. |
| `Failed to load dynamic library … sqlite3` | The executable was copied without the `lib/` folder of its bundle. Copy the whole bundle. |
