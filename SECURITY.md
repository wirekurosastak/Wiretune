# Security policy

## Reporting a vulnerability

Please do not report security problems in public issues.

- If private vulnerability reporting is enabled for this repository, use it (Security tab → *Report a
  vulnerability*).
- Otherwise open an issue that only asks for a private way to reach the maintainers, without describing the
  problem, and send the details there.

Include the affected version or commit, a description, and steps to reproduce. The maintainers will try to
acknowledge the report and to coordinate the fix with you before it is disclosed.

## Supported versions

Only the latest release (or the default branch, before the first release) receives security fixes.

## What Wiretune is designed for

Wiretune is a self-hosted player for a home or otherwise private network: one administrator and a handful of
people who are allowed to listen. It is not hardened for exposure to the open internet. The sections below list
what it does and does not do, so you can decide how to deploy it. How to run the server is described in
[docs/server.md](docs/server.md).

## Server

- **No TLS.** The server speaks plain HTTP. Passwords and access tokens cross the network unencrypted unless you
  put a TLS-terminating reverse proxy in front of it or use a VPN (WireGuard, Tailscale, …). Do not expose the
  port directly to the internet.
- **Reverse proxies and client addresses.** Behind a proxy, set `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` so the
  sign-in limit sees real client addresses. This makes the server trust `X-Forwarded-*` headers from any sender,
  so also make the server reachable only through the proxy (listen on loopback, or firewall the port). Without
  that, a client can forge its address and avoid the limit.
- **Sign-in protection.** Setup and sign-in requests share a limit of 10 per minute per client address.
  Passwords are stored as bcrypt hashes (work factor 12), at least 8 characters and at most 72 bytes. There is
  no account lockout besides that limit, no two-factor authentication, and no password change or reset (see
  [docs/server.md](docs/server.md#accounts) for recovery).
- **Tokens.** Access tokens are JWTs signed with HMAC-SHA256, valid for 24 hours or, with *Keep me signed in*, 90
  days (the first administrator always gets 90 days). There is no per-token revocation: deleting a user ends that
  user's access immediately, which is the way to cut someone off.
- **Tokens in URLs.** Audio and cover requests may carry the token as `?token=` for players that cannot send
  headers (`ffplay`, the Android player). The server accepts it only on `/api/stream` and `/api/cover`. Such URLs
  end up in the access logs of your reverse proxy: keep those logs private. With the shipped `appsettings.json` the server's own
  console logging does not log request URLs.
- **Signing key.** The key for access tokens is stored in the server's database in its data directory. Whoever can
  read `wiretune-server.db` can mint valid tokens and read the password hashes, so restrict the directory to the
  service account. A data directory that the server creates itself is private to its user on Linux; an existing
  directory keeps whatever permissions it has.
- **Roles.** There are two: administrator and user. Every signed-in user can read the whole library; there are no
  per-user libraries or permissions.
- **File paths are exposed.** `GET /api/tracks` returns each track's absolute path on the server (`filePath`) to
  every signed-in user.
- **File access.** The server only reads the music folder and never writes to it. Streaming and cover requests
  serve only files that lie inside the library folder (or the server's own cover cache), and request bodies are
  limited to 64 KiB.

## Clients

- **The access token is stored in plain text** in the client's local database (`wiretune.db`) when the user
  chooses *Keep me signed in* (the account created on a server's first run is always remembered). Anyone who can
  read that file can use the token until it expires, up to 90 days. Signing out clears it. The token is sent only
  to the server address it was issued for.
- **Android allows cleartext HTTP to every destination.** Servers are usually addressed by LAN IP, which Android's
  network security configuration cannot match, so the app permits plain HTTP everywhere. Use an `https://` address
  whenever the server is not on a network you trust.
- **Artist pictures.** The desktop client looks them up through Deezer's public API, which sends artist names from
  your library to `api.deezer.com`. Set `WIRETUNE_NO_ARTIST_PICTURES=1` to disable it. Nothing else leaves your
  network.
- **Logs can contain credentials on Windows.** The Linux audio driver replaces `token=…` with `token=***` in its
  log lines. The Windows driver does not: when playing a server track fails, its log line contains the stream URL
  including the token. Treat `wiretune.log` as sensitive, and do not attach it to a public issue without removing
  `token=` values.
- **UI automation endpoint.** The desktop client can open an unauthenticated control interface on
  `127.0.0.1:5201` if the environment variable `WIRETUNE_UI_AUTOMATION=1` is set. It is a development aid, off by
  default, loopback-only and protected against requests from web pages, but it can control the player and
  accepts credentials in query parameters. Do not enable it on a machine you do not fully control. See
  [docs/development.md](docs/development.md#ui-automation-endpoint-desktop-development-only).
