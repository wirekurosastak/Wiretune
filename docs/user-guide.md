# User guide

The player is meant to explain itself. This page is for the things it doesn't say out loud.

## First start

- **With a server**: enter its address (`http://server-ip:5200`) and press **Connect**. A brand-new server asks you to
  create the administrator account, with the **setup code** from its log; any other just wants you to sign in. *Keep
  me signed in* stretches a sign-in from 24 hours to 90 days. Setting up a server: [server.md](server.md).
- **Without a server** (desktop only): **Continue without a server**, then pick your music folder in *Settings* and
  press **Scan**.
- **Both at once** works too ([below](#server-and-local-music-together)).

The interface starts in English and never reads the system language; Hungarian and German are one click away in the
header or in *Settings → Appearance*. If the server can't be reached at start-up, you get the cached library and a
**Reconnect** banner.

## Layouts

- **Desktop, tablet and TV**: the header on top, the sections on the left, the player at the bottom; the queue and the
  lyrics open in place of the page. Below 1000 pixels the sections shrink to icons.
- **Phone**, or a window under 720 pixels: the sections at the bottom under a mini player, and the albums and the
  artists as lists. Tap the mini player for the full-screen player and its *Queue* and *Lyrics* tabs. Back closes what's
  open, then retraces your sections, and only then leaves the app. The music keeps playing.

## The library

- **Albums** are tracks with the same album title and album artist. Tracks in one folder that share an album title
  (and have no clashing track numbers) become one album even when their artist tags disagree, credited to the album
  artist tag, the artist of most of the tracks, or *Various Artists*.
- **Artists** lists album artists only. A guest on other people's albums gets no page, but their tracks are still in
  *Tracks* and in search.
- **Quality tags**: **gold** is hi-res (lossless above 16 bit or 48 kHz), **silver** is lossless at CD resolution,
  **bronze** is lossy. An album or playlist wears its lowest tier, and `MIXED` when its formats differ. The whole tag
  (`FLAC 24bit/96kHz`) sits on the cover of the full-screen player, of an album and of a playlist, and in the track
  lists and the player bar of a wide screen; the album and playlist tiles, a phone's album list and the queue show the
  resolution (`24bit/96kHz`, `320kbps`), and a narrow queue leaves it out. Hover or long-press a tag for the details.
- **Sorting and filtering**: albums sort by title, year or quality (best first, an album counting as its weakest
  track). When the files carry genre tags, a genre filter narrows the albums and the artists to those with a track of
  that genre.
- **Covers** are the file's embedded picture, else a `cover`, `folder` or `front` image (`.jpg`, `.jpeg`, `.png`),
  `albumart.jpg` or `artwork.jpg` in its folder. **Artist pictures** are looked up online
  ([SECURITY.md](../SECURITY.md#players)); until one turns up, the artist's first album cover stands in.
- **Search** covers title, artist, album, album artist and genre, best match first.

## Playing music

- Clicking a track makes the list it's in (an album, an artist, a playlist, your favourites, everything) the queue.
- *Previous* restarts the track once you're 3 seconds in. *Repeat* cycles off → all → one. *Shuffle* reorders what's
  left without interrupting the current track, and switching it off brings the order back.
- The **queue panel** reorders (drag the handle, or the arrows on a desktop or a TV), removes and clears.
- **Lyrics** load only while the queue or the *Lyrics* tab is open. The file's own come first, and timed (LRC) ones
  follow the song: tap a line to jump there. Otherwise the player asks [LRCLIB](https://lrclib.net), a free, open
  lyrics database, with the title, artist, album and length, and caches the answer in the `lyrics` folder of its data
  directory. Switch that off in **Settings → Lyrics from the internet**.
- Bit-perfect mode pins the volume at 100 % ([audio.md](audio.md)). Phones, tablets and TVs use their own volume keys.
- A track that can't play (the server is unreachable, the sign-in expired, the format isn't supported) stops the queue
  and says why, instead of skipping through everything after it.
- The media keys work while Wiretune has the focus, and Escape goes back. On phones, tablets, Macs and Linux desktops
  the system's media controls work from anywhere.

## Favourites and playlists

For music from a server they belong to **your account on the server**: the same on every device, through sign-outs and
server restarts. Other accounts have their own.

- **Offline** you can browse all of it, but server tracks and playlists are read-only until you reconnect. A change the
  server turns down is undone (a favourite star snaps back) or dropped.
- **Local music** keeps its favourites, play counts and playlists on the device. A playlist made while signed in to a
  server is a server playlist; one made without a server stays local.
- Moving or renaming a file on the server gives its track a new ID, and its old favourite and playlist entries stop
  matching ([server.md](server.md#scanning)).

## Downloads

Music from a server can stay on the device, to play without the server or the network: a single track (its download
button in a track list, or *⋮ → Download to this device* on a phone), an album, a playlist or all your favourites (the
button beside *Play* and *Shuffle*).

- What you marked stays in step: a track added to a downloaded playlist, or a new favourite, is downloaded; one taken
  off is deleted. A file that changed on the server (new tags) is fetched again, and the old copy plays until then.
- Downloads run one track at a time while you're signed in and the app is running (in the background too, as long as
  the system lets it run); one that was cut short continues where it stopped. A track shows the arrow in progress
  while it waits or arrives and a tick once it's here; a list's button fills its ring as its tracks arrive.
- A track kept because its album, a playlist or the favourites are can only be let go with them.
- **Settings → Downloads** shows how much room they take and removes them all. Signing out removes them too.
- There's no "Wi-Fi only" switch yet: downloads use whatever network the device is on, mobile data included.

## Playing on another device

Every player signed in to the same account on the same server sees the others. The cast button (in the player bar,
the mini player, the full-screen player and a phone's page headers) lists them with what each one plays; it lights up
when another device plays while this one is idle. Pick one, and this player becomes its remote: you see what plays
there, and play, pause, skip, seek, shuffle, repeat, the volume and whatever you start from your library go there.
Music that was playing here moves along, and stops here; picking *This device* again brings what plays there back.

- Its queue is shown as far as your library knows the tracks, and isn't edited from here. Its exclusive and
  bit-perfect modes are its own.
- A call or unplugged headphones pause the phone's own sound, never the other device's. The notification and the lock
  screen control the device being controlled.
- If the other device drops off the network, this one waits 15 seconds for it, then takes control back and says so.
- **Settings → Remote control** turns it off (the other devices then don't see this one) or gives the device a name.
- It runs through the server: both need this version, and a reverse proxy has to pass WebSockets on
  ([server.md](server.md#reverse-proxy-and-tls)).

## Server and local music together

A song that's in both places shows up once, and the **local copy wins**, so it plays without the network. Two tracks
are the same song when title and artist match (ignoring case, punctuation and tails like *(2011 Remaster)* or *(Radio
Edit)*) and their lengths are within 5 seconds, or 3.5 when the albums differ. *Live*, *Acoustic* and *Demo* versions
count as different songs. Signing out takes the server's tracks and playlists off the player; they come back when you
sign in again.

## Settings

- **Server & library**: your account, the server's address, **Downloads**, **Remote control**, the local folder and
  **Scan** (desktop). Administrators also get **Reindex**, the server's music folder and **Users**.
- **Audio** (desktop): *Exclusive*, *Bit-perfect* and *Output device*. The switches stay grey when no device can do
  them.
- **Appearance**: language, theme, and *Performance statistics* (Flutter's frame graphs).

## Phones, TVs and the car

- **Android and iPhone** play from a server, also with the screen off; the notification and the lock screen control
  it.
- **TVs** (Android TV and Samsung's Tizen) get the wide layout and the remote: the arrows move, the centre button opens
  or plays, Back goes back. Some formats may not play on Tizen ([audio.md](audio.md#tizen)).
- **Android Auto** lists Wiretune among the car's media apps once the phone is signed in, with albums, artists,
  playlists, favourites and voice search.

## Troubleshooting

| Symptom | What's going on |
|---|---|
| *None of the output devices supports exclusive mode…* | No device can do it. On Linux there's no ALSA hardware device (check `aplay -l`); press **Refresh** once there is. |
| Exclusive playback on Linux fails with *device busy* | Something holds the card that doesn't hand it over on request: another player on the same `hw:` device, or a sound server without device reservation. Close it, or pick another output. |
| No spectrum on the desktop | `ffmpeg` isn't on the `PATH`. |
| The Linux player won't start, missing `libmpv` | Install it: `libmpv2` on Debian and Ubuntu, `mpv-libs` on Fedora. |
| The banner says the server is offline | Wrong address, server not running, or no network. Press **Reconnect**. |
| *Your session has expired* | The token ran out, or the account was deleted. Sign in again. |
| Favourites or playlists are empty after signing in | They belong to the account you used before. Or the server started with a fresh data directory ([server.md](server.md#data-directory)). |
| An iPhone can't reach a server on the LAN | Allow *Local Network* for Wiretune under *Settings → Privacy & Security*. |
| A format plays everywhere but on the Tizen TV | The TV's player can't decode it ([audio.md](audio.md#tizen)). |
| No cast button | You aren't signed in, remote control is off in *Settings*, the server is older than the player, or a proxy doesn't pass WebSockets on ([server.md](server.md#reverse-proxy-and-tls)). |
| Another device doesn't show up | It's signed in to another account or another server, or its remote control is off. |
| Downloads wait and wait | They only run while you're signed in to the server; *Settings → Downloads* says what they're doing. |
| Nothing plays, and nothing says why | Read `wiretune.log` in the player's data directory ([development.md](development.md#debugging)). |
