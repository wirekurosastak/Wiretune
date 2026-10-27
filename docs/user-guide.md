# User guide

What the player doesn't explain itself, and where it keeps its files.

## First start

- **With a server**: enter its address (`http://<server-ip>:5200`) and press **Connect**. A new server asks you to create
  the administrator account with the **setup code** from its log; an existing one asks for a sign-in. *Keep me signed
  in* extends a sign-in from 24 hours to 90 days. Server setup: [server.md](server.md).
- **Without a server** (computers, Android phones): **Continue without a server**, pick your music folder in *Settings →
  Library* and press **Scan**.
- **Both** works too ([below](#server-and-local-music-together)).

The interface always starts in English. Hungarian and German are in *Settings → Appearance*.

## Library updates

- **Server**: rescans about ten seconds after files stop changing; connected players update at once. Network shares
  don't report changes from other machines, so they're rescanned every 30 minutes, or press **Reindex** (*Settings →
  Library*).
- **Local folder**: read at start; computers also watch it while running, phones rescan when the app comes to the front.
- If the server is unreachable, the player reconnects by itself.

## The library

- **Albums** are tracks sharing album title and album artist. A folder of tracks with one album title is one album even
  if the artist tags differ.
- **Compilation folders**: a folder of one artist's songs from several albums becomes one album named after the folder
  (*ACDC Essentials*), unless it's a complete album or holds several artists. Files are never changed.
- **Featured artists**: if a file has one `ARTIST` field per artist (or `ARTISTS`), the song shows all of them, each
  linked. Names are never split at `&`, `,` or `/`, so *Simon & Garfunkel* stays one artist.
- **Quality tags**: **gold** is hi-res (lossless above 16 bit or 48 kHz), **silver** is CD-quality lossless, **bronze**
  is lossy. Albums and playlists show their weakest track's tier, or *MIXED*.
- **Covers**: the embedded picture, else `cover`, `folder` or `front` (`.jpg`, `.jpeg`, `.png`), `albumart.jpg` or
  `artwork.jpg` next to the files.
- **Artist pictures** come from the internet ([SECURITY.md](../SECURITY.md#players)). To use your own, put an
  `artist.jpg` in a folder named after the artist (`Miles Davis/artist.jpg`), or in a top-level folder holding only the
  picture. With a server, put it in the server's music folder.
- **Sorting** lasts until the app closes. Pressing the active sort reverses it.
- **Hidden** artists, albums and tracks are restored in *Settings → Hidden content*.

## Playing music

- Clicking a track plays the list it's in. **Play next** and **Add to queue** are in every *⋮* menu.
- The queue survives a restart.
- **Sleep timer** (the moon): 15, 30, 45 or 60 minutes, or end of track.
- **Lyrics**: the file's own first (timed lyrics follow the song; tap a line to jump), otherwise
  [LRCLIB](https://lrclib.net). *Settings → Lyrics from the internet* turns that off.
- A track that can't play stops the queue and shows why.
- **Gapless** works between tracks of the same format ([audio.md](audio.md#gapless-playback)).
- **Keyboard** (⌘ instead of Ctrl on a Mac): Space play/pause, Ctrl+→/← skip, Shift+→/← seek 10 s, Ctrl+↑/↓ volume,
  Ctrl+F search, Escape back.

## Favorites and playlists

For server music they belong to **your account on the server** and are the same on every device. Offline they're
read-only until you reconnect. Local music keeps its favorites and playlists on the device; a playlist created while
signed in is a server playlist.

- Moving or renaming a file on the server gives the track a new ID, so its favorite and playlist entries stop matching.
- **Most played** and **Recently played** are generated from your plays (50 tracks each).
- Reorder a playlist by dragging tracks (long-press first on a phone).

## Downloads

A track, album, artist, playlist or all favorites can be kept on the device and played without the server: the download
button next to *Play*, or *⋮ → Download to this device*. With *Sync downloads* on (default), downloads follow changes on
the server; off, each download fetches its contents once. Files go to a `Wiretune` folder in your music folder (the
app's own storage on iOS and Tizen), named `Album artist/Album/01 - Title.flac`. Signing out deletes them.

## Remote control

Every player signed in to the same account sees the others. Pick a device with the cast button and this player becomes
its remote; *This device* brings playback back. Control returns after 15 seconds if the other device drops off. It
runs through the server, so a reverse proxy must pass WebSockets ([server.md](server.md#reverse-proxy-and-tls)).
*Settings → Remote control* turns it off or renames the device.

## Server and local music together

A song in both places shows once, and the **local copy wins** (it plays without the network). Songs match on title and
artist (ignoring case, punctuation and tails like *(2011 Remaster)*) with similar length. *Live*, *Acoustic* and *Demo*
versions count as different songs. Downloads never count as local music.

## Phones, TVs and the car

- **Android phone**: can play a local folder; the first **Scan** asks for permission to read music. From Android 13 that
  covers audio files only, so a `cover.jpg` beside them isn't seen (embedded pictures are).
- **Phones** stay upright; tablets rotate.
- **Gestures**: swipe the mini player to skip; pull a list down past the top to search; long-press an album, artist or
  playlist for a preview menu; pinch to resize tiles on tablets and touchpads.
- **TVs** (Android TV, Tizen): arrows move, center plays, Back goes back. Some formats may not play on Tizen
  ([audio.md](audio.md#tizen)).
- **Android Auto** lists albums, artists, playlists and favorites once the phone is signed in, with voice search.

## Where things are

| What | Where |
|---|---|
| Player data: library, settings, sign-in (`wiretune.db`), log (`wiretune.log`), online lyrics and artist pictures | `~/.config/Wiretune` (Linux), `%APPDATA%\Wiretune` (Windows), `~/Library/Application Support/Wiretune` (macOS), app-private storage (phones, TVs) |
| Server covers, up to 300 MB | `ServerCovers` in the system cache folder (`~/.cache/com.wiretune.player` on Linux) |
| Downloads | `Wiretune` in your music folder (computers, Android), app-private storage (iOS, Tizen) |
| Server data: database, covers from files, log (`wiretune-server.log`) | `~/.config/Wiretune/Server` (Linux), `%APPDATA%\Wiretune\Server` (Windows), `~/Library/Application Support/Wiretune/Server` (macOS), or `--data-dir` ([server.md](server.md#data-directory)) |

| Variable | |
|---|---|
| `WIRETUNE_DATA_DIR` | Custom data folder: for the player (e.g. a throw-away one for testing) or the server's `--data-dir` |
| `WIRETUNE_LOG_LEVEL` | `debug`, `info` (default), `warn`, `error`; player and server. `debug` logs paths and device names |
| `WIRETUNE_NO_ARTIST_PICTURES=1` | No artist pictures from the internet |
| `WIRETUNE_NO_ONLINE_LYRICS=1` | No online lyrics, regardless of the setting |
| `WIRETUNE_UI_AUTOMATION=1` | Debug builds only: remote control for scripts ([development.md](development.md#ui-automation)) |
| `WIRETUNE_<OPTION>` | Any server option: `WIRETUNE_PORT=8080` is `--port 8080` ([server.md](server.md#options)) |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| *None of the output devices supports exclusive mode…* | No device can do it. On Linux there's no ALSA hardware device (check `aplay -l`); press **Refresh** once there is. |
| Exclusive playback on Linux fails with *device busy* | Another player on the same `hw:` device, or a sound server without device reservation, holds the card. Close it or pick another output. |
| No spectrum on the desktop | `ffmpeg` isn't on the `PATH`. |
| Linux player won't start, missing `libmpv` | Install it: `libmpv2` (Debian, Ubuntu), `mpv-libs` (Fedora), `mpv` (Arch). |
| Favorites or playlists empty after signing in | They belong to the account you used before, or the server started with a fresh data folder. |
| iPhone can't reach a server on the LAN | Allow *Local Network* for Wiretune in *Settings → Privacy & Security*. |
| No cast button | *Settings → Remote control* says why. If it keeps connecting, the proxy may not pass WebSockets. |
| Nothing plays and nothing says why | Read `wiretune.log` in the player's data folder ([above](#where-things-are)). |
