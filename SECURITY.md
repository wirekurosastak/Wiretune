# Security policy

## Reporting a vulnerability

Please do not report security problems in public issues.

- If private vulnerability reporting is enabled for this repository, use it (Security tab → *Report a
  vulnerability*).
- Otherwise open an issue that only asks for a private way to reach the maintainers, without describing the
  problem, and send the details there.

Include the affected version or commit, a description, and steps to reproduce. The maintainers will try to
acknowledge the report and coordinate the fix with you before it is disclosed. Only the latest release (or the
default branch, before the first release) receives security fixes.

## What Wiretune is designed for

A self-hosted player for a home or otherwise private network: one administrator and a handful of people allowed to
listen. It is not hardened for the open internet. This page is the one place that lists what it does and does not do
about security; running the server is described in [docs/server.md](docs/server.md).

## Server

- **No TLS.** The server speaks plain HTTP, so passwords and tokens cross the network unencrypted unless you use a
  TLS-terminating reverse proxy or a VPN. Do not expose the port directly to the internet. Proxy setup, including
  the forwarded-headers setting and its risk, is in [docs/server.md](docs/server.md#reverse-proxy-and-tls).
- **First account.** Creating the administrator needs the **setup code** the server prints in its log at every start
  while no account exists (or the one you set with `Wiretune:SetupCode`). Without it, whoever reached a server with an
  empty data directory first (an unmounted volume, a wrong data path) would own it. The code is read from the log by
  whoever runs the server; it protects only the very first account.
- **Sign-in.** Setup and sign-in share a limit of 10 requests per minute per client address. Passwords are bcrypt
  hashes (work factor 12). There is no lockout besides that limit, no two-factor authentication, and no password
  change or reset.
- **Tokens.** JWTs signed with HMAC-SHA256, valid 24 hours or 90 days. There is no per-token revocation; deleting
  the user ends their access immediately.
- **Tokens in URLs.** Audio and cover requests may carry a token as `?token=` for players that cannot send headers
  (libmpv, the TV's media player, the desktop's `ffmpeg` for the spectrum); the server accepts it only on `/api/stream`
  and `/api/cover`. The players put a
  **stream token** there, not the sign-in token: it is issued by `POST /api/auth/stream-token`, valid 8 hours, and
  opens the audio and cover routes and nothing else, so a leaked stream URL cannot read or change your account. The URL
  still ends up in the process list of a desktop that runs the spectrum analyser (on `ffmpeg`'s command line) and in the
  access logs of your reverse proxy, so keep those private. The server itself never logs a query string.
- **Signing key.** It lives in the server's database in its data directory. Whoever can read `wiretune-server.db` can
  mint valid tokens and read the password hashes, so restrict the directory to the service account. A directory the
  server creates itself is private to its user on Linux; an existing one keeps its permissions.
- **Roles.** Administrator and user. Every signed-in user can read the whole library; there are no per-user
  libraries or permissions. Favourites, play counts and playlists are per account: the server reads them only for the
  account in the token, and an administrator has no route that reads another account's.
- **File paths stay on the server.** The library routes send a placeholder (`server:{id}`) as `filePath`, never the
  real path. The server's own data (favourites and playlists included) is in the database in its data directory, so
  the same read-protection as for the signing key applies.
- **File access.** The server only reads the music folder. Streaming and cover requests serve only files inside the
  library folder (or the server's cover cache), and request bodies are limited to 64 KiB (4 MiB for a playlist,
  32 MiB for the one-time import, both only after authorisation).

## Clients

- **The access token is stored in plain text** in the player's local database (`wiretune.db`) when *Keep me signed
  in* is ticked (the account created on a server's first run is always remembered). Anyone who can read that file
  can use the token until it expires, up to 90 days. Signing out clears it. The token is sent only to the server
  address it was issued for.
- **Cleartext HTTP is allowed to every destination** on Android (network security configuration), iOS and macOS (App
  Transport Security). Servers are usually addressed by LAN IP, which those settings cannot match. Use an `https://`
  address whenever the server is not on a network you trust.
- **Artist pictures.** The player looks them up through Deezer's public API, which sends artist names from
  your library to `api.deezer.com`; results are cached in `artist_pictures.json`. Set
  `WIRETUNE_NO_ARTIST_PICTURES=1` to disable it.
- **Lyrics.** For a track whose file has no lyrics, the player looks them up on LRCLIB (`lrclib.net`, a free,
  public lyrics database) when you open the queue panel. The request carries the track's title, artist, album and
  length, plus a `Wiretune/1.0` user agent, and comes from the player, not from the server, so a server
  library's tags go to LRCLIB from every device that plays it. Answers are cached in the `lyrics` folder of the
  player's data directory (named by a hash, so no tag text appears in a file name). It is on by default; switch it
  off in Settings, or for the whole process with `WIRETUNE_NO_ONLINE_LYRICS=1`. Nothing else leaves your network.
- **Log files.** `WiretuneLog` replaces the value of every `token=` parameter with `***` before a line is written, so
  stream URLs in the log do not carry the access token. The logs still contain file paths, server addresses and
  device names: read `wiretune.log` before attaching it to a public issue.
- **UI automation endpoint.** Only **debug builds** of the player contain it (a release build has none), and only with
  `WIRETUNE_UI_AUTOMATION=1` does it open an unauthenticated control interface on `127.0.0.1:5201`. It is
  loopback-only and protected against requests from web pages, but it can control the player and takes credentials in
  query parameters. Do not enable it on a machine you do not fully control
  ([docs/development.md](docs/development.md#ui-automation-desktop-development-only)).
