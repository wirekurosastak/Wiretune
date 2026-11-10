# Security

Wiretune runs on your home network and doesn't open itself to the internet: it opens no ports on your router and has
no relay. To reach it away from home, use Tailscale or HTTPS through Caddy ([how](docs/server.md#away-from-home)).

## Reporting a problem

Don't open a public issue. Use private vulnerability reporting (Security tab → *Report a vulnerability*). If that's
off, open an issue that only asks for a private contact, and send the details there.

Include the version or commit, what happens and how to reproduce it. We'll agree on the fix with you before anything is
made public.

## What leaves your network

The players make three kinds of internet requests, and the server two. Nothing else leaves your network.

- **Artist pictures** from Deezer: the artist's name and up to two of its album titles. Not for artists with their own
  `artist.jpg`. Off: `WIRETUNE_NO_ARTIST_PICTURES=1`.
- **Lyrics** from LRCLIB, for tracks without them: title, artist, album and length. Off: *Settings → Appearance*, or
  `WIRETUNE_NO_ONLINE_LYRICS=1`.
- **Updates** from GitHub, at start and once a day: GitHub sees your IP address and version. The file is downloaded
  only when you press **Update**, and installed only if it matches the release's `SHA256SUMS.txt` (and, on Android,
  the app's signature). The checksum catches a damaged download, not a release replaced by someone who took over the
  GitHub account. Off: *Settings → About*, or `WIRETUNE_NO_UPDATE_CHECK=1`.
- **Album genres and labels** (server), from Deezer, once per album after a scan: the barcode or a track's ISRC, else
  the album's title and artist.
- **Track credits** (server), from MusicBrainz, when someone first opens a track's *Credits*: its MusicBrainz recording
  ID or ISRC.

The last two are off with *Settings → Library → Look up music online*. None of these requests says anything about the
accounts; they carry a `Wiretune/<version>` user agent. Answers are cached: pictures and lyrics in the player, genres,
labels and credits in the server's database.

## Server

- **Plain HTTP unless you give the server a certificate** (`--tls-cert`, `--tls-key`), so passwords and tokens travel
  unencrypted. Keep that port on your LAN; from outside, use Tailscale or HTTPS ([how](docs/server.md#away-from-home)).
- **The database** (`wiretune-server.db`) holds the token-signing key and the password hashes. Whoever can read it can
  create tokens. On Linux, a data folder the server creates itself is private to its user. A folder you created keeps
  your permissions.
- **Passwords** are bcrypt hashes (cost 12). Setup, sign-in and password changes are limited to 10 requests a minute
  per client address. No lockout, no two-factor authentication. A signed-in account can change its password without
  the current one, so anyone holding a signed-in device can too ([what a change does](docs/server.md#accounts)).
- **Tokens** are HMAC-SHA256 JWTs, valid 24 hours, or 90 days with *Keep me signed in*. Every request checks the token
  against the account: a deleted user is locked out at once. A password change or an administrator's reset ends every
  earlier session, stream tokens included.
- **Tokens in URLs.** libmpv and the TV player can't send headers, so audio and cover URLs carry `?token=`. Only a
  **stream token** is accepted there: valid 8 hours, audio and covers only, never logged. These URLs can still end up in
  a proxy's access log, and a streamer (UPnP/DLNA) you play on gets them too. The spectrum analyzer's `ffmpeg` doesn't
  get the URL: the player downloads the track and hands it over on standard input.
- **The setup code** ([how it's used](docs/server.md#start-it)) stops strangers from creating the first account on a
  server with an empty data folder, such as after a wrong path or an unmounted disk.
- **Sign-in codes:** *Connect a phone*'s *Sign in as …* QR code signs whoever scans it in to your account, once, within
  5 minutes, and not after a password change. Don't show it to anyone you wouldn't give your password.
- **Roles**: administrator and user. Every user can read the whole library. Favorites, plays (with when, for *Your
  listening*) and playlists are per account. Other accounts see only what the account shares (below). No route, not
  even an administrator's, reads the rest.
- **Friends.** Every account sees the others' usernames, to recommend music to them and listen together. What is
  shared, and with whom:
  - A recommendation: only the account it was sent to.
  - Listening together: only invited accounts join. They hear the host's queue and position and can skip, seek and
    queue.
  - A Blend: both accounts see a mix of each one's most played and favorite tracks, without what either hides.
  - A shared playlist: its members see its tracks and can add, remove and reorder them. Only its owner renames or
    deletes it.
  - A player that lets others play on it (*Settings → Remote control*; on by default, off on phones): the other
    accounts' players on the same network see it and what it plays, and can play on it and control it. The server
    tells the network by the address a player connects from: its own side (LAN, Tailscale) is one network, each public
    address another.

  Blocking an account stops its recommendations and invitations reaching you, and ends the Blend, the shared
  playlists and the shared players between the two of you.
- **Remote control** (`/api/remote`) connects the players of one account, the players other accounts let it play on,
  and the players of one group listening together.
  It accepts only the sign-in token in the header, refuses requests from web pages, and closes when the sign-in stops
  being valid. Whoever has an account's token can control its players. A signed-in account can also make the server
  hold one oversized message in memory.
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
  ([where](docs/user-guide.md#where-things-are)); on Android 11 and later that's the shared *Music* folder. Neither the
  server nor a file's tags can put a download outside it, and Wiretune only overwrites or deletes files it recorded as
  its own. Signing out deletes them. On iOS they're left out of backups.
- **Cached tracks** are plain copies too, in `Music/Wiretune/Cache` (iOS: the app's storage, left out of backups). The
  player streams through a relay on `127.0.0.1` for them, at an address other programs can't guess.
- **Covers from the server** are cached in the system cache folder, readable by anyone who can read it. They're fetched
  with the token in a header, never in the URL.
- **Plain HTTP is allowed to every address** on Android, iOS and macOS, because home servers are reached by IP. Use an
  `https://` address on networks that aren't yours.
- **Logs** blank every `token=` value but contain file paths, server addresses and device names. Check `wiretune.log`
  before attaching it to a public issue.
- **UI automation** is a debug-build-only remote control on `127.0.0.1:5201`, off unless `WIRETUNE_UI_AUTOMATION=1`.
  It refuses web pages but has no authentication and takes credentials in the query string. Only turn it on on a
  machine you fully control ([development.md](docs/development.md#ui-automation)).
