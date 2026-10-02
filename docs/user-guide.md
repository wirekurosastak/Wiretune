# User guide

How to use the Wiretune client. Where the desktop and the Android phone layout differ, it says so. Button and
section names are the English interface texts.

## First start

The client opens on a sign-in screen with a server address field (`http://server-ip:5200` is the usual form).

- **Use a server.** Enter its address and press **Connect**. If the server has no accounts yet, the screen shows
  *First run*: choose an administrator name and a password (at least 8 characters) and press **Create admin
  account and sign in**. Otherwise sign in with your account; tick **Keep me signed in** to stay signed in for
  90 days instead of 24 hours. Setting up a server is described in [server.md](server.md).
- **Use local music (desktop only).** Press **Continue without a server (local music)**, open **Settings**,
  type the folder into *Local music folder* (there is no folder picker) and press **Scan**.
- **Use both.** A server library and a local folder can be active at the same time; see
  [Server and local music together](#server-and-local-music-together).

The interface starts in English; choose another language in [Settings](#language-and-theme). The client does not
read the operating system's language.

When the server is unreachable at start-up, the cached library is shown and a banner offers **Reconnect**. Local
music plays without a server.

## The desktop window

- **Top bar**: search box, quick switches for *Exclusive* and *Bit-perfect* mode (hidden in narrow windows), the
  account button (sign in / out), the language button, the dark/light theme switch and the window buttons. The
  window has its own title bar.
- **Sidebar**: *Artists*, *Albums*, *Tracks* (library), *Favorites*, *Playlists* and *Settings*. In windows
  narrower than 1000 pixels the sidebar shows icons only. The accent colour changes with the section.
- **Player bar** at the bottom: cover, title and artist, quality badge, transport buttons, position slider,
  volume, queue button and the spectrum analyser.
- **Status line**: output mode, device and driver on the left (for example *Exclusive • ALSA: SMSL USB AUDIO
  [ALSA Direct]*); artist, album and track counts, and how many tracks are local or on the server, on the right.

## Browsing the library

- **Artists** lists album artists, A–Z or Z–A (button at the top). An artist's page shows their albums and
  tracks. Artists who only appear as a guest on other people's albums are not listed here; their tracks still
  appear under *Tracks* and in search.
- **Albums** can be sorted by name or by year (press the active sort button again to reverse it; albums without
  a year always come last). An album's page has **Play** and **Shuffle**.
- **Tracks** (called *Songs* on the phone) lists the whole library, ordered by artist, album, disc and track
  number, with a quality column.
- On every page, **Play** starts the list from the top and **Shuffle** starts it in random order.

**How albums are formed.** Tracks are grouped by album title and album artist (the track artist when no album
artist is tagged). Tracks in the same folder with the same album title and no clashing track numbers are put on
one album even if their artist tags differ: the album artist tag is used if any of them has one, otherwise the
artist of more than half of the tracks, otherwise *Various Artists*. Files without tags appear under *Unknown
artist* / *Unknown album*.

**Quality badges** show codec, bit depth and sample rate for lossless files (for example `FLAC / 24bit / 96kHz`)
and codec and bitrate for lossy ones (`MP3 / 320kbps`). An album whose tracks differ in format shows
`MIXED HQ`. A lossless file counts as hi-res above 16 bit or above 48 kHz.

**Covers** come from the file's embedded picture or from a folder image (`cover`, `folder` or `front` as
`.jpg`/`.jpeg`/`.png`, `albumart.jpg`, `artwork.jpg`). **Artist pictures** are looked up online (see
[Privacy](#privacy)); until one is found, the artist's first album cover is used.

## Search

Type in the search box (on the phone: the magnifier in a page header). Results show up to 25 tracks and 12
albums and 12 artists matching title, artist, album, album artist or genre, with a *Best match* on top. Opening
an album or artist from the results gives a back button that returns to the same search.

## Playing music

Clicking a track plays it and makes the list it came from (an album, an artist, a playlist, favourites, or the
whole library) the queue.

| Control | Behaviour |
|---|---|
| Play / pause | Pauses and resumes. When nothing is playing it starts the queue, or the whole library when the queue is empty. |
| Next / previous | *Previous* restarts the current track when more than 3 seconds in, otherwise goes back one track. At the end of the queue, playback stops (with repeat *all* it wraps around). |
| Position slider | Dragging seeks once you let go. |
| Shuffle | Reorders the rest of the queue without interrupting the current track; switching it off restores the original order after the current track. |
| Repeat | Cycles *off → all → one track*. |
| Volume, mute | Disabled while *Bit-perfect* mode is on (the volume is fixed at 100 %). See [audio.md](audio.md#volume). |
| Heart | Marks the current track as a favourite. |

**Queue.** The queue button opens the queue panel: click an entry to jump to it, drag entries (or use the up and
down buttons) to reorder them, remove single entries, or **Clear queue** (the current track stays). On the phone
the queue and the lyrics are tabs of the full-screen player, which opens when you tap the mini player.

**Lyrics** are shown next to the queue (phone: *Lyrics* tab) when the file's tag contains them. They are plain
text, not time-synchronised; there is no online lookup.

**Errors.** If a track cannot be played (missing player, unreachable server, expired sign-in, unsupported
format), the message appears in the player and playback does not skip ahead to the next track. Dismiss it with
its close button.

## Favourites and playlists

- **Favourites**: the heart next to a track toggles it; the *Favorites* page lists them with Play and Shuffle.
- **Playlists**: create one with **New playlist**, then use the **+** button next to a track to add it (the dialog
  lists your playlists and lets you create one on the spot). Click a playlist's name to rename it; tracks can be
  removed individually; deleting a playlist asks for confirmation.

Favourites, play counts and playlists are stored in the client's own database on that device. They are not stored
on the server and do not follow you to another device or account. They refer to tracks by ID, which changes when
a server file is moved or renamed (see [server.md](server.md#library-and-scanning)).

## Server and local music together

On the desktop a server and a local folder can both feed the library (*Settings* shows which sources are active).
Tracks that exist in both are shown once and the **local copy is preferred**, so they play without the network.
Two tracks count as the same song when their title and artist match after ignoring case, punctuation and trailing
notes such as *(2011 Remaster)*, *(Deluxe Edition)* or *(Radio Edit)*, and their lengths are within 5 seconds (3.5
seconds when the album names do not match). *Live*, *Acoustic* or *Demo* versions are treated as different songs.
Favourites, play counts and playlist entries of the server copy are merged into the local copy. Signing out of
the server removes the server tracks from the library and keeps the local ones.

## Settings

- **Server & library**: account status, **Sign out**, server address and **Connect**, local folder and
  **Scan**. Administrators (desktop only) also see **Reindex**, *Server music folder (admin)* with **Save
  folder**, and the **Users** panel (list, add with password confirmation, delete).
- **Appearance**: language and theme.
- **Audio output & audiophile settings** (desktop): the *Exclusive* and *Bit-perfect* switches, the *Output
  device* list with **Refresh**, and the signal path of the current track. The switches may be greyed out when
  no detected device supports them. What each mode does on each platform is explained in [audio.md](audio.md).

Scanning a local folder is incremental: files that did not change since the last scan are not read again.
Reindexing asks the server to rescan its folder; the client waits for it and then downloads the new library.

### Language and theme

Hungarian, English and German are built in. The language changes immediately, without a restart, from
*Settings → Appearance* or the language button in the desktop top bar. The theme (dark or light) is switched in
the same place or with the theme button. Both choices are remembered.

### Privacy

The client looks up artist pictures through Deezer's public API, which sends artist names from your library to
`api.deezer.com`; results are cached locally in `artist_pictures.json`. Set the environment variable
`WIRETUNE_NO_ARTIST_PICTURES=1` before starting the client to turn this off. Nothing else leaves your network.
The access token is stored in the client's local database in plain text when you tick **Keep me signed in** (the
account created on a server's first run is always remembered); signing out clears it.

## Phone layout (Android)

The Android app uses the same engine and data but its own layout:

- A bottom navigation bar with *Artists*, *Albums*, *Songs*, *Favorites* and *Playlists*; *Settings* is
  opened from the page headers.
- A mini player above the navigation bar; tapping it opens the full-screen player with *Player*, *Queue* and
  *Lyrics* tabs.
- A search page opened from the header, and bottom sheets for playlist actions.
- The system back gesture closes the innermost open layer (dialog, full-screen player, sign-in screen, search,
  album/artist/playlist page) and then walks back through the tabs you visited; only then does it leave the app.
- Settings contain the server connection, language, theme and a *Performance statistics* switch that draws frame
  graphs and counters over the app for tuning; it is off by default. The statistics panel also has chips to
  choose the renderer (applied on the next start) and the refresh rate.

The phone layout has no local-folder scan, no exclusive or bit-perfect mode, no output-device selection and none
of the administrator tools (users, reindex, server folder). Use the desktop client for those. Android plays
server streams through the system media player; see [audio.md](audio.md#android).

## Troubleshooting

| Message or symptom | Cause |
|---|---|
| *ffplay was not found. Install FFmpeg and make sure it is on your PATH.* | Linux client without FFmpeg. Install `ffmpeg`. |
| *Direct ALSA playback cannot start (ffmpeg or aplay is missing)* | Exclusive or bit-perfect mode on Linux needs `ffmpeg` and `aplay`. |
| *None of the output devices supports exclusive mode / bit-perfect playback on this system* | No ALSA hardware device (Linux) was found, or none is usable. Check `aplay -l` and press **Refresh**. |
| The server banner says it is offline | The address is wrong, the server is not running, or the network is down. Press **Reconnect**. |
| *Your session has expired. Please sign in again.* | The token ran out or the account was deleted. Sign in again. |
| Some files are in the library but fail on Windows | Windows decodes through Media Foundation, which does not support every indexed format. |
| Nothing plays and no message appears | Look in `wiretune.log` in the client's data directory (Linux `~/.config/Wiretune`, Windows `%APPDATA%\Wiretune`; Android: the app's private files folder). |
