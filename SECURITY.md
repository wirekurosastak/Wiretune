# Security

## Reporting a problem

Please don't put it in a public issue. Use private vulnerability reporting (Security tab → *Report a vulnerability*)
if it's enabled; otherwise open an issue that only asks for a private way to reach us, and send the details there.
Include the version or commit, what happens, and how to reproduce it. We'll acknowledge it and agree on the fix with
you before anything is disclosed. Fixes go to the latest release, or to the default branch until there is one.

## What Wiretune is built for

A home network: one administrator and a handful of people who are allowed to listen. It is not hardened for the open
internet. This page is the honest list of what it does and doesn't do about that.

## Server

- **Plain HTTP.** Passwords and tokens cross the network unencrypted. Keep the port on your LAN, or put a TLS proxy or
  a VPN in front ([server.md](docs/server.md#reverse-proxy-and-tls)). Never expose the port itself to the internet.
- **The first account** needs the setup code that the server prints in its log at every start until an account exists.
  Otherwise whoever reached a server with an empty data directory first (a wrong path, an unmounted volume) would own
  it. The code protects that first account and nothing else.
- **Passwords** are bcrypt hashes (cost 12). Setup, sign-in and password changes share a limit of 10 requests a minute
  per client address. No lockout beyond that, no two-factor, no reset. An account can change its own password if it
  knows the current one (`POST /api/auth/change-password`; the players have no screen for it yet).
- **Tokens** are HMAC-SHA256 JWTs, valid 24 hours, or 90 days with *Keep me signed in*. There's no revocation: a
  password change leaves earlier tokens valid until they expire. Deleting the user locks them out at once.
- **Tokens in URLs.** libmpv, TVs and `ffmpeg` can't send headers, so audio and cover URLs carry `?token=`, and the
  server takes only a **stream token** there: 8 hours, audio and covers only, useless for anything else. It reads
  `?token=` on `/api/stream` and `/api/cover` and nowhere else, and never logs a query string. Those URLs still end up
  in your proxy's access log and, on a desktop running the spectrum analyser, in the process list.
- **The database is the crown jewels.** `wiretune-server.db` holds the token-signing key and the password hashes:
  whoever can read it can mint tokens. A data directory the server creates itself is private to its user on Linux; one
  you created keeps the permissions you gave it.
- **Roles**: administrator and user. Every user can read the whole library. Favourites, play counts and playlists are
  per account, and no route, not even an administrator's, reads somebody else's.
- **Files.** The server reads only the music folder and serves only files inside it (or its cover cache). Clients
  never see a server path. Request bodies are capped at 64 KiB, 4 MiB for a playlist.
- **Remote control** (`/api/remote`) passes messages between the players of one account and nowhere else, takes the
  account from the sign-in token in the header (never a stream token, never the URL), turns away requests from web
  pages, and ends a connection when its token expires or the account is deleted. Whoever holds an account's token can
  control that account's players. A message is read whole before its 64 K limit is checked, so a signed-in account can
  make the server hold one large message in memory: another reason the server is for people you trust.

## Players

- **The sign-in token is stored in plain text** in the player's `wiretune.db` when *Keep me signed in* is ticked (the
  account created on a server's first run is always kept). Anyone who can read that file can use it for up to 90
  days. Signing out clears it, and a token is only ever sent to the server that issued it.
- **Downloads** are plain copies of the server's files in the `Downloads` folder of the player's data directory,
  readable by whoever can read that folder. Their names are hashes, never a server's IDs or paths. Signing out deletes
  them. On iOS they're kept out of iCloud and computer backups.
- **Cleartext HTTP is allowed to every address** on Android, iOS and macOS, because home servers are reached by IP,
  which those platforms' allow-lists can't express. Use an `https://` address whenever the network isn't yours.
- **Artist pictures** come from Deezer's public API, which therefore sees the artist names in your library. They're
  cached in `artist_pictures.json`. `WIRETUNE_NO_ARTIST_PICTURES=1` turns the lookup off.
- **Lyrics** for a track without any are looked up on LRCLIB when you open the queue panel: title, artist, album and
  length, sent by the player (not the server) with a `Wiretune/<version>` user agent. Answers are cached in the `lyrics`
  folder under hashed names. Turn it off in Settings, or for the whole process with `WIRETUNE_NO_ONLINE_LYRICS=1`.
- **Logs** have every `token=` value blanked, but they do contain file paths, server addresses and device names. Read
  `wiretune.log` before you attach it to a public issue.
- **UI automation** is a debug-build-only remote control on `127.0.0.1:5201`, off unless `WIRETUNE_UI_AUTOMATION=1`.
  It's loopback-only and turns away requests from web pages, but it has no authentication, controls the player and
  takes credentials in the query string. Don't switch it on on a machine you don't fully control
  ([development.md](docs/development.md#ui-automation)).

Nothing else leaves your network.
