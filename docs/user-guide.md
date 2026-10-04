# User guide

The interface is meant to be self-explanatory; this page covers the things that are not obvious from it. Button
names are the English texts.

## First start

The player opens on a sign-in screen.

- **With a server**: enter its address (`http://server-ip:5200`) and press **Connect**. If the server has no
  accounts yet, you are asked to create the administrator account, which needs the **setup code** from the server's
  log (whoever runs the server can read it there); otherwise sign in. **Keep me signed in** keeps you signed in for
  90 days instead of 24 hours. Setting up a server: [server.md](server.md).
- **Without a server** (desktop only): choose **Continue without a server**, open *Settings*, type the folder into
  *Local music folder* or pick it with **Browse…**, and press **Scan**.
- **Both**: a server and a local folder can be active together, see
  [Server and local music together](#server-and-local-music-together).

The interface starts in English and does not read the system language. Hungarian, English and German are
switched in *Settings → Appearance* (or the language button in the header) without a restart. If the server is
unreachable at start-up, the cached library is shown with a **Reconnect** banner; local music never needs a
server.

## The layouts

- **Desktop, tablet and TV**: the header (search, the *Bit-perfect* and *Exclusive* switches, your account, language,
  theme), the sections on the left, the player at the bottom, and the queue with the lyrics in place of the page when
  you open it. Below 1000 pixels the sections shrink to icons.
- **Phone** (or a window narrower than 720 pixels): the sections at the bottom, a mini player above them, and search
  and settings at the top. Tapping the mini player opens the full-screen player, whose *Queue* and *Lyrics* tabs take
  the place of the desktop's queue panel. The back gesture closes what is open, then returns to the section you came
  from, and only then leaves the app (the music keeps playing).

## How the library is organised

- **Albums** are tracks grouped by album title and album artist (the track artist when no album artist is tagged).
  Tracks in the same folder with the same album title and no clashing track numbers are put on one album even if
  their artist tags differ: the album artist tag if any track has one, otherwise the artist of more than half of
  the tracks, otherwise *Various Artists*. Files without tags land under *Unknown artist* / *Unknown album*.
- **Artists** lists album artists only. Someone who is just a guest on other people's albums has no page of their
  own; their tracks still appear under *Tracks* and in search.
- **Quality tags** put every track in one of three tiers and show its format after the tier:
  **gold** (`GOLD · FLAC 24bit/96kHz`) is hi-res, meaning lossless above 16 bit or above 48 kHz;
  **silver** (`SILVER · FLAC 16bit/44.1kHz`) is lossless at CD resolution;
  **bronze** (`BRONZE · MP3 320kbps`) is everything that is not lossless (MP3, AAC, Ogg Vorbis, Opus).
  Hover (or long-press) a tag for the definition. An album or playlist is shown in its *lowest* tier, so a gold tag
  means every track is hi-res; when its tracks are not all in the same format the tag ends in `MIXED` instead of a
  format (`SILVER · MIXED`). Tiles in the album grid and the queue show only the file format (`GOLD · FLAC`). The tier
  names follow the interface language (Hungarian: ARANY, EZÜST, BRONZ; German: GOLD, SILBER, BRONZE). Sorting the
  track list by quality sorts by tier.
- **Covers** come from the file's embedded picture or from an image in the folder named `cover`, `folder` or
  `front` (`.jpg`/`.jpeg`/`.png`), or `albumart.jpg` / `artwork.jpg`. **Artist pictures** are looked up online
  (see [SECURITY.md](../SECURITY.md#clients)); until one is found the artist's first album cover is shown.
- **Search** covers title, artist, album, album artist and genre, and shows at most 25 tracks, 12 albums and 12
  artists, with the best match on top.

## Playing music

- Clicking a track plays it and makes the list it came from (album, artist, playlist, favourites, the whole
  library) the queue.
- *Previous* restarts the current track when you are more than 3 seconds in. *Repeat* cycles off → all → one.
- *Shuffle* reorders the rest of the queue without interrupting the current track; switching it off restores the
  original order after the current track.
- The **queue panel** lets you jump to an entry, reorder entries (drag the handle, or use the arrows on a desktop or a
  TV), remove them or clear the queue. The lyrics of the current track sit in the right half of the same panel.
- **Lyrics** are looked for when you open the queue panel or the *Lyrics* tab (not before, so nothing is fetched for
  a track you never look at) and follow the track while it stays open. The file's own lyrics tag comes first; when it
  carries timestamps (LRC), the current line is highlighted as the song plays and tapping a line jumps there. When the
  track has none, the player asks [LRCLIB](https://lrclib.net), a free, open lyrics database: it sends the track's
  title, artist, album and length, and nothing else. The panel says where the text came from. Lyrics from LRCLIB are
  plain text (when it only has a synchronised version, the timestamps are dropped). What was found is kept in the
  `lyrics` folder of the player's data directory (found lyrics for good, "nothing found" for a week), so a track is
  looked up once and works offline afterwards; the folder can be deleted at any time. If LRCLIB cannot be reached the
  panel says so, and opening it again tries again. Tracks without a usable title and artist tag are not looked up.
  The lookup works the same for local files and server tracks, because the *player* asks LRCLIB, not the server. Turn
  it off with **Settings → Lyrics from the internet**; the environment variable `WIRETUNE_NO_ONLINE_LYRICS=1` switches
  it off for the whole process, whatever the setting says.
- Volume and mute are disabled in bit-perfect mode (the volume is fixed at 100 %); see [audio.md](audio.md). Phones,
  tablets and TVs have no volume slider: their own volume keys set the volume.
- If a track cannot be played (unreachable server, expired sign-in, unsupported format), the reason is shown in the
  player and playback stops there instead of skipping to the next track.
- **Keyboard and remote**: the media keys (play/pause, next, previous, stop) work while Wiretune has the focus, and
  Escape goes back. On a phone, a tablet, a Mac or a Linux desktop the system's media controls (notification, lock
  screen, Control Center, the desktop's media widget) control Wiretune from anywhere.

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

- **Server & library**: account, server address, local folder (desktop) and **Scan** (incremental: unchanged files
  are not read again). Administrators also get **Reindex** (the server rescans its folder), the server music folder,
  and the **Users** panel.
- **Audio** (desktop): the *Exclusive* and *Bit-perfect* switches and the *Output device* list. The switches are
  greyed out when no detected device supports them. What they do per platform is in [audio.md](audio.md).
- **Appearance**: language, light or dark theme, and *Performance statistics* (Flutter's frame graphs).

## Phones, TVs and the car

- **Android and iPhone** connect to a server and play its tracks; there is no local-folder scan and no exclusive or
  bit-perfect mode. Music keeps playing with the screen off; the notification and the lock screen control it.
- **Android TV and Samsung (Tizen) TVs** get the wide layout, steered with the remote: the arrows move the highlight,
  the centre button opens or plays, Back goes back, and the media keys control playback. Typing the server address
  and password uses the TV's on-screen keyboard. On a Tizen TV some formats may not play ([audio.md](audio.md#tizen)).
- **Android Auto**: with Wiretune on the phone and signed in to a server, the car's screen shows Wiretune among the
  media apps, with albums, artists, playlists and favourites to browse; voice search plays from the library. The
  library is the phone's: sign in on the phone first.

## Troubleshooting

| Message or symptom | Cause |
|---|---|
| *None of the output devices supports exclusive mode / bit-perfect playback…* | No usable device for the mode: on Linux no ALSA hardware device (check `aplay -l`), then press **Refresh**. |
| Exclusive playback on Linux fails with *device busy* | PipeWire holds the card. Install `pw-reserve` (part of PipeWire's tools) so Wiretune can ask for it. |
| No spectrum on the desktop | `ffmpeg` is not on the `PATH`. Install it. |
| The Linux player does not start, saying `libmpv` is missing | Install libmpv (`libmpv2` on Debian and Ubuntu, `mpv-libs` on Fedora). |
| Server banner says offline | Wrong address, server not running, or the network is down. Press **Reconnect**. |
| *Your session has expired. Please sign in again.* | The token ran out or the account was deleted. |
| Favourites or playlists look empty after signing in | The data belongs to the account you used before: sign in with that one. If the server was restarted with a fresh data directory it is gone, see [server.md](server.md#data-directory). |
| An iPhone cannot reach a server on the LAN | Allow *Local Network* for Wiretune in the iPhone's settings (*Privacy & Security → Local Network*). |
| A format plays everywhere but on the Tizen TV | The TV's player cannot decode it ([audio.md](audio.md#tizen)). |
| Nothing plays and no message | Read `wiretune.log` in the client's data directory ([development.md](development.md#debugging)). |
