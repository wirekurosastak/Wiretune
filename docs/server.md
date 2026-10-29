# Running the server

The server is one program. It indexes one music folder (read-only), keeps its own SQLite database, and serves the
players over the [HTTP API](api.md). It speaks plain HTTP: for access away from home, use
[Tailscale or HTTPS](#away-from-home). Read [SECURITY.md](../SECURITY.md) before exposing it to a network you don't
fully trust.

## Start it

Build it ([building.md](building.md#server)), copy `dist/server` to the machine that will run it, and start it:

```bash
dist/server/bin/wiretune_server --library /srv/music
```

It listens on port 5200 on all IPv4 interfaces and scans the folder. Until the first account exists, every start logs a
setup code:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

Enter it in the player to create the first account, which becomes the administrator. The code isn't used after that.

## Docker

The image runs the server as an unprivileged user, with the music at `/music` and the data at `/data`. Build it from
the repository root (it needs the core package too):

```bash
docker build -f server/Dockerfile -t wiretune-server .
docker run -d --name wiretune -p 5200:5200 -v /srv/music:/music:ro -v wiretune-data:/data wiretune-server
docker logs wiretune        # the setup code, on the first start
```

Once a release is published, the image is also at `ghcr.io/<owner>/wiretune-server`. Set other options as `WIRETUNE_*`
variables (`-e WIRETUNE_SCAN_INTERVAL=0`). Keep `/data` on a volume, or every new container starts with an empty
database.

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
journalctl -u wiretune -f        # the setup code appears here on the first start
```

The `wiretune` user only needs read access to the music. systemd keeps the data folder private to it, which matters
because the database holds the password hashes and the token-signing key.

## Away from home

Never forward port 5200 on your router: passwords and tokens would cross the internet unencrypted. Use one of these
instead.

### Tailscale

[Tailscale](https://tailscale.com) is the simplest option. It connects your devices in a private, encrypted network.
No ports to open, and it works even if your provider shares one public IP among customers.

1. Install Tailscale on the server machine and on every phone and computer that should reach it.
2. Sign them all in to the same account.
3. In the players, connect to the server's Tailscale name, such as `http://nas:5200`.

The server needs no changes. Samsung TVs can't run Tailscale, but at home they reach the server over your LAN anyway.

### HTTPS with No-IP and Caddy

For an `https://` address that works on any device without an extra app:

1. Get a free hostname from [No-IP](https://www.noip.com), such as `yourname.ddns.net`. Keep it pointing at your home
   with your router's dynamic DNS setting (most support No-IP), or with No-IP's update client on the server. Free
   hostnames must be confirmed every 30 days.
2. On the router, forward ports 80 and 443 to the server machine.
3. Install [Caddy](https://caddyserver.com) there. It gets the certificate itself, so this is the whole configuration:

   ```
   yourname.ddns.net {
       reverse_proxy 127.0.0.1:5200
   }
   ```

4. Start the server with `--host 127.0.0.1 --trust-proxy`, and connect the players to `https://yourname.ddns.net`.

`--trust-proxy` gives each player its own sign-in rate limit instead of sharing the proxy's. It trusts
`X-Forwarded-For` from anyone who can reach the port, so only use it while `--host 127.0.0.1` keeps the port behind the
proxy.

Remote control uses a WebSocket (`/api/remote`). Caddy passes it through by default. nginx needs
`proxy_http_version 1.1;`, `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";` in
its `location` block.

## Accounts

The administrator adds and removes other accounts in *Settings → Account & connection*. Those are regular users and
can't be promoted. The administrator can't delete their own account. Names: up to 64 characters, unique ignoring case.
Passwords: at least 8 characters and at most 72 bytes (bcrypt ignores the rest).

Each account's favorites, play counts, playlists and hidden items are stored on the server, so they're the same on every
device, and they're deleted with the account ([limits](api.md#your-data)).

Changing your own password doesn't ask for the current one, and it signs out the account's other devices. When the
administrator resets another account's password (*Settings → Account & connection*), that account is signed out
everywhere. Use this to cut off a lost phone. Sign-in and token details: [SECURITY.md](../SECURITY.md#server).

**Lost the administrator password?** There's no reset. Stop the server, delete the rows of the `users` table in
`wiretune-server.db`, and start it again to set it up from scratch:

```bash
sqlite3 wiretune-server.db 'DELETE FROM users;'     # with Docker: on the /data volume (the image has no sqlite3)
```

Everyone starts over, and the old accounts' favorites and playlists are lost.

## Data directory

Default location: `~/.config/Wiretune/Server` (Linux), `%APPDATA%\Wiretune\Server` (Windows),
`~/Library/Application Support/Wiretune/Server` (macOS). `--data-dir` changes it. The first log lines show which one is
used. It contains:

- `wiretune-server.db` (with `-wal` and `-shm`): the index, the accounts, everyone's favorites, play counts and
  playlists, and the token-signing key.
- `Covers/`: pictures taken from the files. Safe to delete; the next scan recreates them.
- `wiretune-server.log`, rotated to `.1` at 10 MiB.

Changes are written immediately, so a restart loses nothing. A *different* data folder starts the server from scratch
and asks for a setup code again. Keep it on persistent storage.

**Back up the database.** A scan rebuilds the index, but nothing rebuilds the accounts, the signing key or the
playlists. Stop the server first, or copy the `.db` together with its `-wal` and `-shm` files. A newer server upgrades
the database on its first start, and older versions can't open it after that, so back up before upgrading. A database
from a newer version is refused, not misread.

## Scanning

The server scans the music folder at startup and about ten seconds after files stop changing. Network shares don't
report changes made from other machines, so it also rescans every `--scan-interval` minutes. Scans are incremental, and
online players pick up the changes at once.

An administrator can start a scan with **Reindex** in the player (*Settings → Library*), or switch to another folder
there. That choice is saved and overrides `--library` from then on, even while the folder is missing (such as a share
that mounts late).

Indexed formats: FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis, Opus. Whether a file also
plays depends on the player ([audio.md](audio.md)). Missing tags fall back to the file name, `Unknown artist` and
`Unknown album`. If the folder suddenly looks empty, the server skips the scan and reports *Library folder is empty
(unmounted share?)*, so an unmounted NAS doesn't wipe your library.

A track's ID comes from its full file path. Moving or renaming a file gives it a new ID, and its favorites and playlist
entries are lost.

## Options

`--help` lists the options. Each one can also be set as an environment variable: `--port 8080` is
`WIRETUNE_PORT=8080`, `--trust-proxy` is `WIRETUNE_TRUST_PROXY=true`. The command line wins.

| Option | Default | |
|---|---|---|
| `--library <folder>` | your Music folder | The music folder (absolute, or relative to the working directory), until an administrator picks another one ([Scanning](#scanning)). |
| `--data-dir <folder>` | [see above](#data-directory) | Where the database, cover cache and log live. |
| `--host <address>` | `0.0.0.0` | `0.0.0.0`: all IPv4 interfaces. `::`: all interfaces. `127.0.0.1`: this machine only. |
| `--port <number>` | `5200` | |
| `--scan-interval <minutes>` | `30` | Background rescans. `0` turns them off. |
| `--setup-code <code>` | random | The code for creating the first account. Without it, a new one each start. Case, spaces and dashes are ignored. |
| `--trust-proxy` | off | Take the client address from `X-Forwarded-For`. Only behind a reverse proxy ([above](#https-with-no-ip-and-caddy)). |
| `--log-level <level>` | `info` | `debug`, `info`, `warn` or `error`. |

## Troubleshooting

| Problem | Fix |
|---|---|
| The library is empty, but the folder has music | Check the file extensions, hidden (dot) folders and the service user's permissions. The log lists unreadable files. |
| *… was made by another version of Wiretune* | The data folder holds a database this version can't read. Run the matching version, or move the file away to start fresh. |
| *Cannot listen on …: Address already in use* | Something else (maybe another Wiretune) uses the port. Stop it, or pick another `--port`. |
| The player says it isn't a Wiretune server | Something else answered. Check the port, and whether a proxy is showing an error page. |
| *Too many attempts* for everyone behind a proxy | Start the server with `--trust-proxy` ([above](#https-with-no-ip-and-caddy)). |
| Every player had to sign in again after a restart | The database (and its token-signing key) was replaced. Restore it from a backup, or sign in again. |
| The setup screen is back, or favorites vanished after a restart | The server uses a different data folder. Compare the one at the top of the log with the one you expect. |
| `Failed to load dynamic library … sqlite3` | The program was copied without the bundle's `lib/` folder. Copy the whole bundle. |
