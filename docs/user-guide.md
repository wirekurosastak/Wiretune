# User guide

The player explains most things itself. This page has what it doesn't say out loud, and where it keeps its files.

## First start

- **With a server**: enter its address (`http://<server-ip>:5200`) and press **Connect**. A new server asks for the
  administrator account and the **setup code** from its log; any other one for a sign-in. *Keep me signed in* makes a
  sign-in last 90 days instead of 24 hours. Setting up a server: [server.md](server.md).
- **Without a server** (computers and Android phones): **Continue without a server**, then choose your music folder in
  *Settings → Library* and press **Scan**.
- **Both at once** works too ([below](#server-and-local-music-together)).

The interface starts in English and never reads the system language; Hungarian and German are in *Settings →
Appearance*.

## New music shows up by itself

No restart, no rescan:

- The server reads its folder about ten seconds after files stop changing there, and the players that are on show the
  new music at once. A network share doesn't report changes made on other machines: the server reads it every 30
  minutes, or press **Reindex** (*Settings → Library*).
- A player reads its own folder at start; a computer also while it runs, a phone whenever it comes to the front.
- A cover put next to an album later (`cover.jpg` …), or a new picture in the files, shows the same way.
- While the server is out of reach, the player keeps asking, and comes back by itself.

## The library

- **Albums** are tracks with the same album title and album artist. A folder of tracks with one album title is one
  album, even when their artist tags disagree.
- **A folder of one artist's songs from several albums** (a best-of you put together, each file keeping the album it
  came from) is one album too, named after the folder (*ACDC Essentials*, or *Eminem Essentials* when the folder is
  named after the artist), its songs in title order. When the folder is named like one of the albums in it (*The Best
  of Hooverphonic*), the odd tracks join that album instead. Loose files, folders of several artists and complete
  albums stay as their tags say. The files aren't changed.
- **Featured artists**: when a file names each artist (one `ARTIST` field each, as TIDAL downloads do, or `ARTISTS`),
  the song shows them all (*Future, Lil Durk*), each name a link, and is on each one's page. Names are never split at
  `&`, `,` or `/`, so *Simon & Garfunkel* stays one artist. **Artists** lists album artists; a guest gets a page through
  the song's link or a search. An album of two acts (one `ALBUMARTIST` field each) shows them both and is on both
  pages; hiding either artist hides it.
- **Quality tags**: **gold** is hi-res (lossless above 16 bit or 48 kHz), **silver** lossless at CD resolution,
  **bronze** lossy. An album or playlist wears its weakest track's tier, and *MIXED* when its formats differ. Hover or
  long-press a tag for the details.
- **Covers** are the picture in the file, else a `cover`, `folder` or `front` image (`.jpg`, `.jpeg`, `.png`),
  `albumart.jpg` or `artwork.jpg` beside it.
- **Artist pictures** come from the internet ([SECURITY.md](../SECURITY.md#players)); until one turns up, an album cover
  stands in. When it shows someone else (several artists share a name), use your own: an `artist.jpg` (or `.jpeg`,
  `.png`) in a folder named after the artist, the one that holds their albums (`Miles Davis/artist.jpg` beside
  `Miles Davis/Kind of Blue/`) or, for an artist without one, a new folder at the top of the music folder holding
  just the picture. With a server, it goes in the server's music folder and every player shows it.
- **Sorting**: the lists start A→Z, the favorites with the newest. Pressing the active sort again turns it round, and
  what has no year or date goes last. A choice lasts until the app closes.
- **Tabs keep their place**: an album, artist or playlist you opened is still open when you come back to its tab.
  Pressing the tab you're on returns to its list, and pressing it again goes to the list's top.
- **Hidden** artists, albums and tracks come back from *Settings → Hidden content*.

## Playing music

- Clicking a track plays the list it's in, in the order shown. **Play next** and **Add to queue** are in every *⋮* menu.
- *Previous* restarts the track once you're 3 seconds in. *Shuffle* never interrupts the track that plays, and switching
  it off brings the order back.
- Tracks follow each other **without a gap** when they share a format (rate, bit depth, channels); a change of format
  leaves a short pause ([audio.md](audio.md#gapless-playback)).
- The queue comes back after a restart, paused where it was.
- The **sleep timer** (the moon) pauses after 15, 30, 45 or 60 minutes, or at the end of the track.
- **Lyrics** load only while they're shown: the file's own first, and timed ones follow the song (tap a line to jump
  there). Otherwise [LRCLIB](https://lrclib.net) is asked; *Settings → Lyrics from the internet* turns that off.
- A track that can't play stops the queue and says why, instead of skipping through everything after it.
- **Keyboard** (⌘ for Ctrl on a Mac): Space plays and pauses, Ctrl+→ and Ctrl+← skip, Shift+→ and Shift+← seek 10
  seconds, Ctrl+↑ and Ctrl+↓ set the volume, Ctrl+F searches, Escape goes back.

## Favorites and playlists

For a server's music they belong to **your account on the server**, the same on every device. Offline you can browse
them, but they're read-only until you reconnect. Local music keeps its favorites and playlists on the device; a
playlist made while signed in is a server playlist.

- Moving or renaming a file on the server gives its track a new ID, and its favorite and playlist entries stop matching.
- **Most played** and **Recently played** make themselves from your plays, 50 tracks each.
- A playlist in its own order is rearranged by dragging its tracks (after a long press on a phone).

## Downloads

A track, an album, an artist, a playlist or all your favorites can stay on the device, to play without the server: the
download button beside *Play*, or *⋮ → Download to this device*. With *Sync downloads* on (the default) they keep in
step with the server; off, a download fetches what it covers once. The copies go to a `Wiretune` folder in your music
folder (on iOS and Tizen, the app's own storage), named `Album artist/Album/01 - Title.flac`. Signing out deletes them.

## Playing on another device

Every player signed in to the same account sees the others. Pick one with the cast button and this player becomes its
remote: what you start, pause or skip happens there, and *This device* brings the music back. If the other device drops
off the network, control comes back after 15 seconds. It runs through the server, so a reverse proxy has to pass
WebSockets on ([server.md](server.md#reverse-proxy-and-tls)). *Settings → Remote control* turns it off or names the
device.

## Server and local music together

A song in both places shows once, and the **local copy wins**, so it plays without the network. Two tracks are the same
song when title and artist match (ignoring case, punctuation and tails like *(2011 Remaster)*) and their lengths are
within 5 seconds, or 3.5 across albums. *Live*, *Acoustic* and *Demo* versions are different songs. The player's own
downloads never count as local music.

## Phones, TVs and the car

- **An Android phone** plays a folder of its own too; the first **Scan** asks for the permission to read music. From
  Android 13 on that covers audio files only, so a `cover.jpg` beside them isn't seen (pictures inside the files are).
- **A phone stays upright**, as in TIDAL and Spotify; a tablet turns.
- **Gestures**: swipe the mini player left or right to skip (a screen reader offers *Next* and *Previous* instead);
  pull a tab's list down past its top to search; long-press an album, artist or playlist for a preview with its menu
  (slide the finger onto an entry and let go to choose it), and tap its cover to open it. On a tablet or a computer's
  touchpad, pinch the tiles to make them larger or smaller.
- **In the full-screen player** a swipe left or right changes the track or switches between *Track*, *Queue* and
  *Lyrics*: the first swipe asks which, and *Settings* changes it later.
- **TVs** (Android TV, Samsung Tizen) are steered with the remote: the arrows move, the center button plays, Back goes
  back. Some formats may not play on Tizen ([audio.md](audio.md#tizen)).
- **Android Auto** lists Wiretune once the phone is signed in: albums, artists, playlists, favorites, voice search.

## Where things are

| What | Where |
|---|---|
| The player's data: the library, settings and sign-in (`wiretune.db`), the log (`wiretune.log`), lyrics and artist pictures found online | `~/.config/Wiretune` (Linux), `%APPDATA%\Wiretune` (Windows), `~/Library/Application Support/Wiretune` (macOS), the app's private storage (phones, TVs) |
| Covers from the server, up to 300 MB | `ServerCovers` in the system's cache folder (`~/.cache/com.wiretune.player` on Linux) |
| Downloads | `Wiretune` in your music folder (computers, Android), the app's private storage (iOS, Tizen) |
| The server's data: the database, covers from the files, the log (`wiretune-server.log`) | `~/.config/Wiretune/Server` (Linux), `%APPDATA%\Wiretune\Server` (Windows), `~/Library/Application Support/Wiretune/Server` (macOS), or `--data-dir` ([server.md](server.md#data-directory)) |

| Variable | |
|---|---|
| `WIRETUNE_DATA_DIR` | A data folder of its own: for the player (a throw-away one, for trying things), or the server's `--data-dir` |
| `WIRETUNE_LOG_LEVEL` | `debug`, `info` (the default), `warn` or `error`, for the player and the server. `debug` logs paths and device names |
| `WIRETUNE_NO_ARTIST_PICTURES=1` | No artist pictures from the internet |
| `WIRETUNE_NO_ONLINE_LYRICS=1` | No lyrics from the internet, whatever the setting says |
| `WIRETUNE_UI_AUTOMATION=1` | Debug builds only: a remote control for scripts ([development.md](development.md#ui-automation)) |
| `WIRETUNE_<OPTION>` | Any of the server's options: `WIRETUNE_PORT=8080` is `--port 8080` ([server.md](server.md#options)) |

## Troubleshooting

| Symptom | What's going on |
|---|---|
| *None of the output devices supports exclusive mode…* | No device can do it. On Linux there's no ALSA hardware device (check `aplay -l`); press **Refresh** once there is. |
| Exclusive playback on Linux fails with *device busy* | Something holds the card and won't hand it over: another player on the same `hw:` device, or a sound server without device reservation. Close it, or pick another output. |
| No spectrum on the desktop | `ffmpeg` isn't on the `PATH`. |
| The Linux player won't start, missing `libmpv` | Install it: `libmpv2` on Debian and Ubuntu, `mpv-libs` on Fedora, `mpv` on Arch. |
| Favorites or playlists are empty after signing in | They belong to the account you used before, or the server started with a fresh data folder. |
| An iPhone can't reach a server on the LAN | Allow *Local Network* for Wiretune under *Settings → Privacy & Security*. |
| No cast button | *Settings → Remote control* says why. If it keeps connecting, a proxy may not pass WebSockets on. |
| Nothing plays, and nothing says why | Read `wiretune.log` in the player's data folder ([above](#where-things-are)). |
