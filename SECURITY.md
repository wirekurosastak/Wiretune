# Security

Wiretune is built for a home network with one administrator and a few people they trust. It is not hardened for the open
internet.

## Reporting a problem

Please don't put it in a public issue. Use private vulnerability reporting (Security tab → *Report a vulnerability*)
if it's enabled; otherwise open an issue that only asks for a private way to reach us, and send the details there.
Include the version or commit, what happens, and how to reproduce it. We'll acknowledge it and agree on the fix with
you before anything is disclosed. Fixes go to the latest release, or to the default branch until there is one.

## What leaves your network

The players fetch two things from the internet, and nothing else leaves your network:

- **Artist pictures** come from Deezer's public API, which sees the artist names in your library and the titles of up to
  two albums for each, used to tell apart artists who share a name. An artist with a picture of their own (`artist.jpg`)
  isn't looked up, and `WIRETUNE_NO_ARTIST_PICTURES=1` turns the lookup off.
- **Lyrics** for a track without any are looked up on LRCLIB when you open the queue or the lyrics. The player, not the
  server, sends the title, artist, album and length, with a `Wiretune/<version>` user agent. Turn it off in Settings, or
  for the whole process with `WIRETUNE_NO_ONLINE_LYRICS=1`.

Both are cached in the player's data folder.

## Server

- **Plain HTTP.** Passwords and tokens cross the network unencrypted. Keep the port on your LAN, or put a TLS proxy or a
  VPN in front ([server.md](docs/server.md#reverse-proxy-and-tls)). Never expose the port itself to the internet.
- **The database** (`wiretune-server.db`) holds the token-signing key and the password hashes, so whoever can read it
  can mint tokens. A data directory the server creates itself is private to its user on Linux; one you created keeps the
  permissions you gave it.
- **Passwords** are stored as bcrypt hashes (cost 12). Setup, sign-in and password changes share a limit of 10 requests
  a minute per client address; beyond that there's no lockout and no two-factor authentication. A signed-in account can
  change its own password without giving the current one, so anyone who picks up a signed-in device can change it too
  ([what a change does](docs/server.md#accounts)).
- **Tokens** are HMAC-SHA256 JWTs, valid for 24 hours, or 90 days with *Keep me signed in*. Every request checks its
  token against the account, so deleting a user locks them out at once, and a password change or an administrator's
  reset ends every earlier session, stream tokens included.
- **Tokens in URLs.** libmpv, the TVs' player and `ffmpeg` can't send headers, so audio and cover URLs carry `?token=`.
  The server accepts only a **stream token** there: valid for 8 hours, good for audio and covers only, and never logged.
  Those URLs can still end up in a proxy's access log and, on a desktop running the spectrum analyzer, in the process
  list.
- **The setup code** ([how it's used](docs/server.md#start-it)) keeps whoever first reaches a server with an empty data
  directory, after a wrong path or an unmounted volume, from taking it over. It protects the first account and nothing
  else.
- **Roles** are administrator and user. Every user can read the whole library. Favorites, play counts and playlists are
  per account, and no route, not even an administrator's, reads somebody else's.
- **Remote control** (`/api/remote`) connects only the players of one account. It accepts only the sign-in token in the
  request header, refuses requests from web pages, and closes as soon as that sign-in stops being valid. Whoever holds an
  account's token can control that account's players, and a signed-in account can make the server hold one oversized
  message in memory: another reason the server is for people you trust.
- **Files.** The server reads only the music folder and serves only files inside it or its cover cache. Clients never
  see a server path, except that an administrator sees the music folder and why a scan failed. An administrator can
  switch to another folder, but not to a whole disk, a system folder such as `/proc` or `/dev`, or one that overlaps the
  server's data, wherever symbolic links lead. Request bodies and tag reading are capped, so a damaged or hostile file
  or request can't exhaust the server's memory.

## Players

- **The sign-in token is stored in plain text** in the player's `wiretune.db` when *Keep me signed in* is ticked (the
  account created on a server's first run is always kept signed in). Anyone who can read that file can use the token
  until it expires. Signing out clears it, and a token is only ever sent to the server that issued it.
- **Downloads** are plain copies of the server's files, readable by anyone who can read their folder
  ([where](docs/user-guide.md#where-things-are)). On Android 11 and later that's the shared *Music* folder, where other
  apps can see them; before Android 11 it's the app's own folder on the shared storage. Neither the server nor a file's
  tags can make a download land outside that folder, and Wiretune only overwrites or deletes files it recorded as its
  own copies. Signing out deletes them; on iOS they're kept out of iCloud and computer backups. The player asks for no
  storage permission anywhere.
- **Covers from the server** are cached in the system's cache folder, readable by anyone who can read it. They're
  fetched with the sign-in token in a header, never in the address.
- **Cleartext HTTP is allowed to every address** on Android, iOS and macOS, because home servers are reached by IP,
  which those platforms' allow-lists can't express. Use an `https://` address whenever the network isn't yours.
- **Logs** have every `token=` value blanked, but they do contain file paths, server addresses and device names. Read
  `wiretune.log` before you attach it to a public issue.
- **UI automation** is a debug-build-only remote control on `127.0.0.1:5201`, off unless `WIRETUNE_UI_AUTOMATION=1`.
  It's loopback-only and refuses requests from web pages, but it has no authentication, controls the player and takes
  credentials in the query string. Don't switch it on on a machine you don't fully control
  ([development.md](docs/development.md#ui-automation)).
