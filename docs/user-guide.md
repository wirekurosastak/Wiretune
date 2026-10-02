# User guide

The interface is meant to be self-explanatory; this page covers the things that are not obvious from it. Button
names are the English texts.

## First start

The player opens on a sign-in screen.

- **With a server**: enter its address (`http://server-ip:5200`) and press **Connect**. If the server has no
  accounts yet, you are asked to create the administrator account, which needs the **setup code** from the server's
  log (whoever runs the server can read it there); otherwise sign in. **Keep me signed in** keeps you signed in for
  90 days instead of 24 hours. Setting up a server: [server.md](server.md).
- **Without a server** (desktop only): choose **Continue without a server**, open *Settings*, type the folder
  into *Local music folder* (there is no folder picker) and press **Scan**.
- **Both**: a server and a local folder can be active together, see
  [Server and local music together](#server-and-local-music-together).

The interface starts in English and does not read the system language. Hungarian, English and German are
switched in *Settings → Appearance* (or the language button on the desktop) without a restart. If the server is
unreachable at start-up, the cached library is shown with a **Reconnect** banner; local music never needs a
server.

## How the library is organised

- **Albums** are tracks grouped by album title and album artist (the track artist when no album artist is tagged).
  Tracks in the same folder with the same album title and no clashing track numbers are put on one album even if
  their artist tags differ: the album artist tag if any track has one, otherwise the artist of more than half of
  the tracks, otherwise *Various Artists*. Files without tags land under *Unknown artist* / *Unknown album*.
- **Artists** lists album artists only. Someone who is just a guest on other people's albums has no page of their
  own; their tracks still appear under *Tracks* and in search.
- **Quality badges** show codec, bit depth and sample rate for lossless files (`FLAC / 24bit / 96kHz`) and codec
  and bitrate for lossy ones (`MP3 / 320kbps`). An album with mixed formats shows `MIXED HQ`. Lossless counts as
  hi-res above 16 bit or above 48 kHz.
- **Covers** come from the file's embedded picture or from an image in the folder named `cover`, `folder` or
  `front` (`.jpg`/`.jpeg`/`.png`), or `albumart.jpg` / `artwork.jpg`. **Artist pictures** are looked up online
  (see [SECURITY.md](../SECURITY.md#clients)); until one is found the artist's first album cover is shown.
- **Search** covers title, artist, album, album artist and genre, and shows at most 25 tracks, 12 albums and 12
  artists.

## Playing music

- Clicking a track plays it and makes the list it came from (album, artist, playlist, favourites, the whole
  library) the queue.
- *Previous* restarts the current track when you are more than 3 seconds in. *Repeat* cycles off → all → one.
- *Shuffle* reorders the rest of the queue without interrupting the current track; switching it off restores the
  original order after the current track.
- The **queue panel** lets you jump to an entry, drag entries to reorder them, remove them or clear the queue.
- **Lyrics** appear next to the queue when the file's tag has them. They are plain text, not time-synchronised,
  and there is no online lookup.
- Volume and mute are disabled in bit-perfect mode (the volume is fixed at 100 %); see [audio.md](audio.md).
- If a track cannot be played (missing player, unreachable server, expired sign-in, unsupported format), the
  reason is shown in the player and playback stops there instead of skipping to the next track.

## Favourites and playlists

For music from a server, favourites, play counts and playlists belong to **your account on the server**. They are
stored there, not on the device, so they are the same on every device you sign in on, they survive signing out and
in, and they survive a restart of the server. Another account on the same server has its own.

- **Offline.** Without a connection the library is shown from the cache and you can still browse and read your
  favourites and playlists, but server tracks and the playlists of the account cannot be changed until you are
  connected again. If the server refuses a change while you are connected (it is down for a moment, or an account
  limit is reached), a favourite star goes back to its real state; a play count or playlist edit that did not reach the
  server is dropped and the next refresh shows what the server holds.
- **Local music** (a folder on this computer) is not known to the server, so its favourites, play counts and
  playlists stay on this device. A playlist is kept where it was created: a playlist made while signed in to a
  server is a server playlist; one made without a server is a local playlist and stays on the device.
- **Moving data from before.** The first account that signs in on a device that already holds favourites or playlists
  for server tracks from before the server stored them receives them, once. Nothing on the server is removed or
  lowered by it, and an account that signs in later on the same device does not get them.
- **An older server** that does not store per-account data keeps working: favourites and playlists then stay on the
  device, as before.
- They refer to tracks by ID, which changes when a server file is moved or renamed (see
  [server.md](server.md#library-and-scanning)); entries for the old IDs then no longer match anything.

## Server and local music together

Tracks that exist in both places are shown once, and the **local copy is preferred** so it plays without the
network. Two tracks count as the same song when title and artist match after ignoring case, punctuation and
trailing notes such as *(2011 Remaster)*, *(Deluxe Edition)* or *(Radio Edit)*, and their lengths are within 5
seconds (3.5 seconds when the album names differ). *Live*, *Acoustic* and *Demo* versions are different songs.
The favourite flag, play count and playlist entries of the server copy move to the local copy. Signing out removes
the server tracks and your server playlists from the player and keeps the local music; your server data is still on
the server and comes back when you sign in.

## Settings

- **Server & library**: account, server address, local folder and **Scan** (incremental: unchanged files are not
  read again). Administrators on the desktop also get **Reindex** (the server rescans its folder), the server
  music folder, and the **Users** panel.
- **Audio** (desktop): the *Exclusive* and *Bit-perfect* switches and the *Output device* list. The switches are
  greyed out when no detected device supports them. What they do per platform is in [audio.md](audio.md).

## Android

The phone app has its own layout (bottom navigation, mini player, full-screen player with queue and lyrics) over
the same library. It connects to a server and plays its tracks through the system media player, but it has no
local-folder scan, no exclusive or bit-perfect mode, no output-device selection and none of the administrator
tools. Use the desktop player for those.

## Troubleshooting

| Message or symptom | Cause |
|---|---|
| *ffplay was not found…* | Linux player without FFmpeg. Install `ffmpeg`. |
| *Direct ALSA playback cannot start (ffmpeg or aplay is missing)* | Exclusive and bit-perfect mode on Linux need `ffmpeg` and `aplay`. |
| *None of the output devices supports exclusive mode / bit-perfect playback…* | No usable ALSA hardware device on Linux. Check `aplay -l`, then press **Refresh**. |
| Server banner says offline | Wrong address, server not running, or the network is down. Press **Reconnect**. |
| *Your session has expired. Please sign in again.* | The token ran out or the account was deleted. |
| Favourites or playlists look empty after signing in | The data belongs to the account you used before: sign in with that one. If the server was restarted with a fresh data directory it is gone, see [server.md](server.md#data-directory). |
| Some files are indexed but fail on Windows | Windows decodes through Media Foundation, which does not cover every format ([audio.md](audio.md#windows)). |
| Nothing plays and no message | Read `wiretune.log` in the client's data directory ([development.md](development.md#debugging)). |
