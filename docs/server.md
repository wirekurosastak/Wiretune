# Running the server

The server is one program. It indexes one music folder (read-only), keeps its own SQLite database, and serves the
players over the [HTTP API](api.md). For access away from home: [Tailscale or HTTPS](#away-from-home).

## Start it

Download `wiretune-server-…` for your system from the
[latest release](https://github.com/wirekurosastak/Wiretune/releases/latest), unpack it, and start it with your music
folder:

```bash
tar -xzf wiretune-server-*-linux-x64.tar.gz
wiretune-server-*/bin/wiretune_server --library /srv/music
```

- Keep `bin/` and `lib/` together: the program loads SQLite from `lib/`.
- Linux: needs glibc 2.34 or later (Debian 12, Ubuntu 22.04, Fedora 35).
- Windows: `bin\wiretune_server.exe --library D:\Music`.
- macOS: Apple silicon only. A download from a browser is quarantined; `xattr -dr com.apple.quarantine <folder>` lifts
  that (untried).

Or [build it](building.md#server) and start `dist/server/bin/wiretune_server`.

It listens on port 5200 and scans the folder. Until the first account exists, every start logs a setup code:

```
No administrator account exists yet. Create it in the player with the setup code K7QP-2WXM
```

Enter it in the player to create the administrator account.

## Docker

The image runs the server as an unprivileged user, with the music at `/music` and the data at `/data`. Build it from
the repository root:

```bash
docker build -f server/Dockerfile -t wiretune-server .
docker run -d --name wiretune -p 5200:5200 -v /srv/music:/music:ro -v wiretune-data:/data wiretune-server
docker logs wiretune        # the setup code, on the first start
```

Released images: `ghcr.io/wirekurosastak/wiretune-server`, and `…:ffmpeg` with [ffmpeg](#streaming-on-a-slow-connection).
Set [options](#options) as `WIRETUNE_*` variables (`-e WIRETUNE_SCAN_INTERVAL=0`). Keep `/data` on a volume, or each new
container starts with an empty database.

Docker Compose: set the music folder in [`docker-compose.yml`](../docker-compose.yml), then `docker compose up -d`
(`--build` builds from the checkout) and `docker compose logs` for the setup code.

### Streaming on a slow connection

With `ffmpeg` on the machine (or the `:ffmpeg` image; build one with `--build-arg WITH_FFMPEG=true`), the server
converts a track to Opus or MP3 when a player's *Streaming quality* asks for it ([audio.md](audio.md#streaming-quality)).

- The first play of a track waits for the conversion: a second or two on a desktop CPU, longer on a NAS.
- Converted files are kept in `Transcodes/` in the [data directory](#data-directory), up to 2 GB. Safe to delete.
- Without `ffmpeg`, or when the file is already smaller, the server sends the original. The players' *Streaming
  quality* setting says when the server has no `ffmpeg`.

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

The `wiretune` user only needs read access to the music. systemd keeps the data folder (password hashes, signing key)
private to it.

Windows and macOS (neither tried): on Windows, a Task Scheduler task with the trigger *At log on* that starts
`bin\wiretune_server.exe --library D:\Music`; on macOS, a launchd agent in `~/Library/LaunchAgents` whose
`ProgramArguments` are the same command, with `RunAtLoad` and `KeepAlive`.

## Updating

Back up the database ([Data directory](#data-directory)), stop the server, put the new download in place of the old
folder (with Docker: pull the image and start a new container on the same `/data` volume), and start it. The data
folder stays, and the server upgrades its database. Keep the players on the same version: a player says in *Settings →
About* when the server is older than it.

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

`--trust-proxy` gives each player its own sign-in rate limit instead of sharing the proxy's, and lets the server tell
which players are on the same network (only those can play on another account's player). It trusts
`X-Forwarded-For` from anyone who can reach the port, so only use it while `--host 127.0.0.1` keeps the port behind the
proxy.

Remote control uses a WebSocket (`/api/remote`). Caddy passes it through by default. nginx needs
`proxy_http_version 1.1;`, `proxy_set_header Upgrade $http_upgrade;` and `proxy_set_header Connection "upgrade";` in
its `location` block.

### HTTPS without a proxy

With a certificate and its key as PEM files (from Let's Encrypt, for example), the server serves HTTPS itself:

```bash
wiretune_server --library /srv/music --tls-cert /etc/ssl/fullchain.pem --tls-key /etc/ssl/privkey.pem
```

Use the full chain (`fullchain.pem`) and restart the server after a renewal. Self-signed certificates are refused.

## Accounts

In *Settings → Account & connection* the administrator:

- adds and removes accounts (regular users; there is one administrator),
- renames them, and with *Members can change their name* lets them rename themselves,
- resets a password, which signs that account out everywhere: use it to cut off a lost phone.

Names: up to 64 characters, unique ignoring case. Passwords: 8 characters to 72 bytes. Changing your own password
doesn't ask for the current one and signs out your other devices.

Each account's favorites, plays, playlists and hidden items are kept on the server and deleted with the account
([limits](api.md#your-data)).

**Lost the administrator password?** Stop the server and run it once with `--reset-password` and the account's name
(and the `--data-dir` it runs with). It prints a new password and signs the account's devices out; change it in the
player afterwards.

```bash
wiretune_server --reset-password owner --data-dir /var/lib/wiretune
docker run --rm -v wiretune-data:/data ghcr.io/wirekurosastak/wiretune-server --reset-password owner
```

## Data directory

Default location: `~/.config/Wiretune/Server` (Linux), `%APPDATA%\Wiretune\Server` (Windows),
`~/Library/Application Support/Wiretune/Server` (macOS). `--data-dir` changes it. The first log lines show which one is
used. It contains:

- `wiretune-server.db` (with `-wal` and `-shm`): the index, the accounts, everyone's favorites, play counts and
  playlists, and the token-signing key.
- `Covers/`: pictures taken from the files. Safe to delete; the next scan recreates them.
- `wiretune-server.log`, rotated to `.1` at 10 MiB.

A different data folder starts the server from scratch, with a new setup code. Keep it on persistent storage.

**Back up the database.** A scan rebuilds the index, but not the accounts, the signing key or the playlists. Stop the
server first, or copy the `.db` with its `-wal` and `-shm` files. A newer server upgrades the database, after which
older versions can't open it, so back up before upgrading.

## Scanning

The server scans the music folder at startup, about ten seconds after files stop changing, and every
`--scan-interval` minutes (network shares don't report changes made elsewhere). Players pick up the changes at once.

In *Settings → Library* an administrator can **Reindex**, or switch to another folder; that choice overrides
`--library` from then on.

After a scan the server looks up on Deezer the genre and label of albums whose files don't name them; a track's
*Credits* come from MusicBrainz when first opened ([what is sent](../SECURITY.md#what-leaves-your-network)). Both are
off with *Settings → Library → Look up music online*.

Indexed formats: FLAC, WAV, AIFF, WavPack, APE, DSF, M4A (ALAC or AAC), AAC, MP3, Ogg Vorbis, Opus
([what plays where](audio.md)). Missing tags fall back to the file name, `Unknown artist` and `Unknown album`. A folder
that suddenly looks empty isn't scanned (*Library folder is empty (unmounted share?)*), so an unmounted NAS doesn't wipe
the library.

A moved or renamed file keeps its favorites, plays and playlist entries when the scan can tell which file it was: the
only one of that size and length, or of that title, artist, album and length.

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
| `--tls-cert <file>`, `--tls-key <file>` | off | Serve HTTPS with this certificate chain and private key (PEM). Both or neither ([HTTPS](#https-without-a-proxy)). |
| `--log-level <level>` | `info` | `debug`, `info`, `warn` or `error`. |
| `--reset-password <account>` | | Gives the account a new random password, prints it, and exits ([Accounts](#accounts)). Command line only. |

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
