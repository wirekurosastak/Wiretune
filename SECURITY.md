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
- **Sign-in.** Setup and sign-in share a limit of 10 requests per minute per client address. Passwords are bcrypt
  hashes (work factor 12). There is no lockout besides that limit, no two-factor authentication, and no password
  change or reset.
- **Tokens.** JWTs signed with HMAC-SHA256, valid 24 hours or 90 days. There is no per-token revocation; deleting
  the user ends their access immediately.
- **Tokens in URLs.** Audio and cover requests may carry the token as `?token=` for players that cannot send headers
  (`ffplay`, the Android player); the server accepts it only on `/api/stream` and `/api/cover`. Such URLs end up in
  the access logs of your reverse proxy, so keep those private. With the shipped `appsettings.json` the server's own
  console logging does not log request URLs.
- **Signing key.** It lives in the server's database in its data directory. Whoever can read `wiretune-server.db` can
  mint valid tokens and read the password hashes, so restrict the directory to the service account. A directory the
  server creates itself is private to its user on Linux; an existing one keeps its permissions.
- **Roles.** Administrator and user. Every signed-in user can read the whole library; there are no per-user
  libraries or permissions.
- **File paths are exposed.** `GET /api/tracks` returns each track's absolute server path (`filePath`) to every
  signed-in user.
- **File access.** The server only reads the music folder. Streaming and cover requests serve only files inside the
  library folder (or the server's cover cache), and request bodies are limited to 64 KiB.

## Clients

- **The access token is stored in plain text** in the player's local database (`wiretune.db`) when *Keep me signed
  in* is ticked (the account created on a server's first run is always remembered). Anyone who can read that file
  can use the token until it expires, up to 90 days. Signing out clears it. The token is sent only to the server
  address it was issued for.
- **Android allows cleartext HTTP to every destination.** Servers are usually addressed by LAN IP, which Android's
  network security configuration cannot match. Use an `https://` address whenever the server is not on a network you
  trust.
- **Artist pictures.** The desktop player looks them up through Deezer's public API, which sends artist names from
  your library to `api.deezer.com`; results are cached in `artist_pictures.json`. Set
  `WIRETUNE_NO_ARTIST_PICTURES=1` to disable it. Nothing else leaves your network.
- **Logs can contain credentials on Windows.** The Linux audio driver replaces `token=…` with `token=***` in its log
  lines; the Windows driver does not, so when playing a server track fails, its log line contains the stream URL
  with the token. Treat `wiretune.log` as sensitive and strip `token=` values before attaching it to an issue.
- **UI automation endpoint.** With `WIRETUNE_UI_AUTOMATION=1` the desktop player opens an unauthenticated control
  interface on `127.0.0.1:5201`. It is a development aid, off by default, loopback-only and protected against
  requests from web pages, but it can control the player and takes credentials in query parameters. Do not enable it
  on a machine you do not fully control ([docs/development.md](docs/development.md#ui-automation-desktop-development-only)).
