# Running the server

The server is a single program that indexes one music folder, which it never writes to, keeps its own SQLite database,
and serves the players over the [HTTP API](api.md). It speaks plain HTTP, so keep it on your LAN or
[put a TLS proxy or VPN in front of it](#reverse-proxy-and-tls), and read [SECURITY.md](../SECURITY.md) before exposing
it to a network you don't fully trust.

## Start it

Build it ([building.md](building.md#server)), copy `dist/server` to the machine that will run it, and start it:

```bash
dist/server/bin/wiretune_server --library /srv/music
```

It listens on port 5200 on every IPv4 interface and scans the folder. Until the first account exists, every start logs
a setup code:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

Enter it in the player to create the first account, which becomes the administrator. After that the code is never used
again.

## Docker

The image runs the server as an unprivileged user, with the music at `/music` and the data at `/data`. Build it from the
repository root, since it needs the core package too:

```bash
docker build -f server/Dockerfile -t wiretune-server .
docker run -d --name wiretune -p 5200:5200 -v /srv/music:/music:ro -v wiretune-data:/data wiretune-server
docker logs wiretune        # the setup code, on the first start
```

Once a release is published, the image is also at `ghcr.io/<owner>/wiretune-server`. Pass other options as `WIRETUNE_*`
variables (`-e WIRETUNE_SCAN_INTERVAL=0`), and keep `/data` on a volume: without one, every new container starts with an
empty database.

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

The `wiretune` user needs only read access to the music. systemd keeps the data directory private to it, which matters
because the database holds the password hashes and the token-signing key.

## Reverse proxy and TLS

To reach the server from outside your LAN, put a TLS-terminating proxy in front of it, or use a VPN such as WireGuard or
Tailscale; the players accept `https://` addresses. With [Caddy](https://caddyserver.com), which obtains the certificate
itself, this is the whole configuration:

```
music.example.com {
    reverse_proxy 127.0.0.1:5200
}
```

Then start the server with `--host 127.0.0.1` and `--trust-proxy`. `--trust-proxy` gives each player its own sign-in
rate limit instead of all of them sharing the proxy's, but it believes `X-Forwarded-For` from anyone who can reach the
port, so it's only safe while `--host 127.0.0.1` keeps the port behind the proxy.

Remote control runs over a WebSocket (`/api/remote`). Caddy passes WebSockets through on its own; nginx needs
`proxy_http_version 1.1;`, `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";` in its
`location` block.

## Accounts

The administrator adds and removes everyone else in *Settings → Account & connection*. Those accounts are regular users
and can't be promoted, and the administrator can't delete their own account. Names can be up to 64 characters and must
be unique, ignoring case. Passwords need at least 8 characters and at most 72 bytes, because bcrypt ignores anything
longer.

Each account's favorites, play counts, playlists and hidden items live on the server, so they're the same on every
device and are deleted with the account ([limits](api.md#your-data)).

Changing your own password in the player doesn't ask for the current one, and it signs out the account's other devices.
When the administrator resets another account's password (*Settings → Account & connection*), that account is signed
out everywhere, which is how you cut off a lost phone. Sign-in and token details are in
[SECURITY.md](../SECURITY.md#server).

**Lost the administrator password?** There's no reset. Stop the server, delete the rows of the `users` table in
`wiretune-server.db`, and start it again to set it up from scratch. Everyone starts over, and the old accounts'
favorites and playlists become unreachable.

## Data directory

By default the server keeps its data in `~/.config/Wiretune/Server` (Linux), `%APPDATA%\Wiretune\Server` (Windows) or
`~/Library/Application Support/Wiretune/Server` (macOS); `--data-dir` moves it, and the first lines of the log name it.
It holds:

- `wiretune-server.db`, with its `-wal` and `-shm` files: the index, the accounts, everyone's favorites, play counts and
  playlists, and the token-signing key.
- `Covers/`: pictures taken from the files. It's safe to delete; the next scan writes them again.
- `wiretune-server.log`, moved to `.1` at 10 MiB.

Every change is written immediately, so a restart loses nothing, but a *different* data directory starts the server from
scratch, asking for a setup code again. Keep it on persistent storage.

**Back up the database.** A scan rebuilds the index, but nothing rebuilds the accounts, the signing key or the
playlists. Stop the server first, or copy the `.db` together with its `-wal` and `-shm` files. A newer server upgrades
the database in place on its first start, after which older versions can't open it, so take the backup before
upgrading. A database from a newer version is refused rather than misread.

## Scanning

The server scans its music folder at start-up and about ten seconds after files in it stop changing. Network shares
don't report changes made from other machines, so it also rescans every `--scan-interval` minutes. Scans are
incremental, and players that are online pick up the changes at once.

An administrator can start a scan with **Reindex** in the player (*Settings → Library*), or switch the server to another
folder there. That choice is saved and overrides `--library` from then on, even while the folder is missing, such as a
share that mounts late.

The server indexes FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis and Opus; whether a file
also plays depends on the player ([audio.md](audio.md)). Missing tags fall back to the file name, `Unknown artist` and
`Unknown album`. If the folder suddenly looks empty, the server skips the scan and reports *Library folder is empty
(unmounted share?)*, so an unmounted NAS doesn't wipe your library.

A track's ID comes from its file's full path, so moving or renaming a file gives it a new ID, and the favorites and
playlist entries of the old one point at nothing.

## Options

`--help` lists the options. Each can also be set as an environment variable, which suits services and containers:
`--port 8080` is `WIRETUNE_PORT=8080`, and `--trust-proxy` is `WIRETUNE_TRUST_PROXY=true`. The command line wins.

| Option | Default | |
|---|---|---|
| `--library <folder>` | your Music folder | The music folder, absolute or relative to the working directory, until an administrator picks another one ([Scanning](#scanning)). |
| `--data-dir <folder>` | [see above](#data-directory) | Where the database, cover cache and log live. |
| `--host <address>` | `0.0.0.0` | Where to listen: `0.0.0.0` for every IPv4 interface, `::` for every interface, `127.0.0.1` for this machine only. |
| `--port <number>` | `5200` | |
| `--scan-interval <minutes>` | `30` | Background rescans; `0` turns them off. |
| `--setup-code <code>` | random | The code that creates the first account; without it, a new one at every start. Case, spaces and dashes don't matter. |
| `--trust-proxy` | off | Take each client's address from `X-Forwarded-For`; only behind a reverse proxy ([above](#reverse-proxy-and-tls)). |
| `--log-level <level>` | `info` | `debug`, `info`, `warn` or `error`. |

## Troubleshooting

| Problem | What to do |
|---|---|
| The library is empty, but the folder has music | Check the file extensions, hidden (dot) folders and the service account's permissions; the log lists unreadable files. |
| *… was made by another version of Wiretune* | The data directory holds a database this version can't read. Run the matching version, or move the file away to start afresh. |
| *Cannot listen on …: Address already in use* | Something else, perhaps another Wiretune, holds the port. Stop it, or pick another `--port`. |
| The player says it isn't a Wiretune server | Something else answered: check the port, and whether a proxy is showing an error page. |
| *Too many attempts* for everyone behind a proxy | Run the server with `--trust-proxy` ([above](#reverse-proxy-and-tls)). |
| Every player had to sign in again after a restart | The database, and with it the token-signing key, was replaced. Restore it from a backup, or sign in again. |
| The setup screen is back, or favorites vanished after a restart | The server is using a different data directory. Compare the one named at the top of the log with the one you expect. |
| `Failed to load dynamic library … sqlite3` | The executable was copied without its bundle's `lib/` folder. Copy the whole bundle. |
