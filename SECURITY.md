# Security

Wiretune is made for a home network with one administrator and a few trusted people. It is not hardened for the open
internet.

## Reporting a problem

Don't open a public issue. Use private vulnerability reporting (Security tab → *Report a vulnerability*). If that's
off, open an issue that only asks for a private contact, and send the details there.

Include the version or commit, what happens and how to reproduce it. We'll agree on the fix with you before anything is
made public. Fixes go to the latest release, or to the default branch until there is one.

## What leaves your network

The players make three kinds of internet requests. Nothing else leaves your network.

- **Artist pictures** from Deezer's public API. Deezer sees the artist names and up to two album titles per artist
  (to tell apart artists with the same name). Artists with their own `artist.jpg` aren't looked up.
  Off: `WIRETUNE_NO_ARTIST_PICTURES=1`.
- **Lyrics** from LRCLIB, for tracks without lyrics, when you open the queue or the lyrics. The player sends title,
  artist, album and length, with a `Wiretune/<version>` user agent. Off: in Settings, or `WIRETUNE_NO_ONLINE_LYRICS=1`.
- **Updates**: release builds ask GitHub for the latest release at start and once a day. GitHub sees your IP address
  and version. Only after you press **Update** does the player download the file for your system and the release's
  `SHA256SUMS.txt`. A file with a wrong checksum isn't installed. This catches a damaged download, not a release
  replaced by someone who took over the GitHub account. Android also requires the same signature.
  Off: *Settings → About*, or `WIRETUNE_NO_UPDATE_CHECK=1`.

Pictures and lyrics are cached in the player's data folder.

## Server

- **Plain HTTP.** Passwords and tokens are sent unencrypted. Keep the port on your LAN. From outside, use Tailscale or
  an HTTPS proxy ([how](docs/server.md#away-from-home)). Never expose the port to the internet.
- **The database** (`wiretune-server.db`) holds the token-signing key and the password hashes. Whoever can read it can
  create tokens. On Linux, a data folder the server creates itself is private to its user. A folder you created keeps
  your permissions.
- **Passwords** are bcrypt hashes (cost 12). Setup, sign-in and password changes are limited to 10 requests a minute
  per client address. No lockout, no two-factor authentication. A signed-in account can change its password without
  the current one, so anyone holding a signed-in device can too ([what a change does](docs/server.md#accounts)).
- **Tokens** are HMAC-SHA256 JWTs, valid 24 hours, or 90 days with *Keep me signed in*. Every request checks the token
  against the account: a deleted user is locked out at once. A password change or an administrator's reset ends every
  earlier session, stream tokens included.
- **Tokens in URLs.** libmpv, the TV player and `ffmpeg` can't send headers, so audio and cover URLs carry `?token=`.
  Only a **stream token** is accepted there: valid 8 hours, audio and covers only, never logged. These URLs can still
  end up in a proxy's access log and, on a desktop with the spectrum analyzer, in the process list.
- **The setup code** ([how it's used](docs/server.md#start-it)) stops strangers from creating the first account on a
  server with an empty data folder, such as after a wrong path or an unmounted disk. It protects the first account
  only.
- **Roles**: administrator and user. Every user can read the whole library. Favorites, play counts and playlists are
  per account. No route, not even an administrator's, reads another account's data.
- **Remote control** (`/api/remote`) connects only the players of one account. It accepts only the sign-in token in the
  header, refuses requests from web pages, and closes when the sign-in stops being valid. Whoever has an account's
  token can control its players. A signed-in account can also make the server hold one oversized message in memory.
- **Files.** The server reads only the music folder and serves only files inside it or its cover cache. Clients never
  see server paths, except that an administrator sees the music folder and scan errors. An administrator can switch
  folders, but not to a whole disk, a system folder such as `/proc` or `/dev`, or a folder overlapping the server's
  data, following symbolic links. Request bodies and tag reading are size-limited, so a broken or hostile file or
  request can't use up the server's memory.

## Players

- **The sign-in token is stored in plain text** in the player's `wiretune.db` when *Keep me signed in* is on (the
  account created on a server's first run is always kept signed in). Anyone who can read that file can use the token
  until it expires. Signing out removes it. A token is only sent to the server that issued it.
- **Downloads** are plain copies of the server's files, readable by anyone who can read their folder
  ([where](docs/user-guide.md#where-things-are)). On Android 11 and later that's the shared *Music* folder, visible to
  other apps; before Android 11 it's the app's own folder on shared storage. Neither the server nor a file's tags can
  put a download outside that folder. Wiretune only overwrites or deletes files it recorded as its own. Signing out
  deletes them. On iOS they're excluded from iCloud and computer backups. The player needs no storage permission.
- **Covers from the server** are cached in the system cache folder, readable by anyone who can read it. They're fetched
  with the token in a header, never in the URL.
- **Plain HTTP is allowed to every address** on Android, iOS and macOS, because home servers are reached by IP, which
  those platforms' allow-lists can't express. Use an `https://` address on networks that aren't yours.
- **Logs** blank every `token=` value but contain file paths, server addresses and device names. Check `wiretune.log`
  before attaching it to a public issue.
- **UI automation** is a debug-build-only remote control on `127.0.0.1:5201`, off unless `WIRETUNE_UI_AUTOMATION=1`.
  It's loopback-only and refuses web pages, but has no authentication, controls the player and takes credentials in
  the query string. Only turn it on on a machine you fully control
  ([development.md](docs/development.md#ui-automation)).
