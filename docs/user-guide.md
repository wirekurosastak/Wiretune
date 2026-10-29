# User guide

## First start

**With a server:** enter its address (`http://<server-ip>:5200`) and press **Connect**. A new server asks you to create
the administrator account with its setup code ([server.md](server.md#start-it)). Otherwise you sign in. A sign-in lasts
24 hours, or 90 days with *Keep me signed in*. If the server goes offline, the player reconnects by itself.

**With your own files** (computers and Android phones, with or without a server): choose **Continue without a server**
if you have none, pick your music folder in *Settings → Library* and press **Scan**. On Android the first scan asks for
permission to read your music.

The interface starts in English. Hungarian and German are in *Settings → Appearance*.

## The library

Your files are never changed.

- **Albums:** tracks with the same album title and album artist. A folder of tracks with one album title is one album
  even if the artist tags differ. A folder of one artist's songs from several albums becomes one album named after the
  folder (*ACDC Essentials*), unless it holds a complete album or several artists.
- **Several artists:** if a file has one `ARTIST` field per artist, or an `ARTISTS` field, every artist is listed with
  a link. Names are never split at `&`, `,` or `/`: *Simon & Garfunkel* stays one artist.
- **Quality badges:** **gold** for hi-res (lossless above 16 bit or 48 kHz), **silver** for CD-quality lossless,
  **bronze** for lossy. An album or playlist shows its weakest track's badge, or *MIXED* when formats differ.
- **Covers:** the picture embedded in the file, or a `cover`, `folder` or `front` image (`.jpg`, `.jpeg`, `.png`),
  `albumart.jpg` or `artwork.jpg` next to it. On Android 13 and later the player can only read audio files in a local
  folder, so covers there must be embedded.
- **Artist pictures** come from the internet ([what's sent](../SECURITY.md#what-leaves-your-network)). To use your own,
  put an `artist.jpg` (or `.jpeg`, `.png`) in a folder named after the artist, such as `Miles Davis/artist.jpg`. For an
  artist without a folder, create one at the top of the music folder with just the picture. With a server, it goes in
  the server's music folder.
- **Duplicates:** a song both on the server and in your local folder shows once, and the local copy plays. Two tracks
  are the same song when title and artist match (ignoring case, punctuation and tails such as *(2011 Remaster)*) and
  the lengths are close. *Live*, *Acoustic* and *Demo* versions stay separate. Downloads never count as local music.
- **New music** appears by itself. A computer watches its local folder while the player runs, a phone checks it when
  you return to the app, and the server watches its own folder ([server.md](server.md#scanning)). An administrator can
  force a server rescan with **Reindex** in *Settings → Library*.
- **Sorting** lasts until the app closes. Press the active sort again to reverse it.
- **Hidden** artists, albums and tracks come back from *Settings → Hidden content*.

## Playing music

Clicking a track plays the list it's in. Every *⋮* menu has **Play next** and **Add to queue**. The queue survives a
restart. The sleep timer (the moon) pauses after 15, 30, 45 or 60 minutes, or at the end of the track.

Lyrics come from the file if it has them. Timed lyrics follow the song: tap a line to jump there. For other tracks the
player asks [LRCLIB](https://lrclib.net), unless *Settings → Appearance → Lyrics from the internet* is off.

Tracks of the same format play without a gap ([audio.md](audio.md#gapless-playback)). A track that can't play stops the
queue and shows why, instead of skipping.

| Key (⌘ instead of Ctrl on a Mac) | Action |
|---|---|
| Space | Play or pause |
| Ctrl+→, Ctrl+← | Next or previous track |
| Shift+→, Shift+← | Seek 10 seconds forward or back |
| Ctrl+↑, Ctrl+↓ | Volume up or down |
| Ctrl+F | Search |
| Escape | Back |

## Favorites and playlists

For server music, favorites and playlists belong to your account, so every device shows the same ones. They're
read-only while the player is offline. For local music they're stored on the device, but a playlist created while
signed in is a server playlist.

The server identifies a track by its file path, so moving or renaming a file drops it from favorites and playlists.
**Most played** and **Recently played** are built from your plays and hold 50 tracks each. To reorder a playlist, drag
its tracks (on a phone, long-press first).

## Downloads

You can download a track, album, artist, playlist or all favorites to play without the server: use the download button
next to *Play*, or *⋮ → Download to this device*. With *Sync downloads* on (the default), downloads follow changes on
the server. With it off, each download is fetched once. Files are saved in the [downloads folder](#where-things-are) as
`Album artist/Album/01 - Title.flac`. Signing out deletes them.

Away from the server, turn on *Settings → Account & connection → Offline mode*. The library then shows only downloads
and local music, and the player stops looking for the server (no banner, no reconnecting). Turn it off, or connect to
a server, to get everything back.

## Remote control

Players signed in to the same account see each other. Pick a device with the cast button to control it. *This device*
brings playback back; so does the other device dropping off the network. *Settings → Remote control* turns the feature
off or renames this device.

## Updates

When a new version is out, a banner says so. **Update** downloads and installs it; × hides the banner until the next
check. Nothing installs unless you press **Update**.

| Installed from | What **Update** does |
|---|---|
| The Linux folder, or its `install.sh` | Replaces the folder and starts the new version |
| The `.deb` or `.rpm` | Asks for your password, installs the new package with apt or dnf, and starts it |
| The Windows installer | Closes the player, runs the new installer silently, and starts it again |
| The macOS disk image | Opens the new disk image: drag Wiretune into *Applications* over the old one |
| An Android APK | Hands the new APK to Android, which asks before installing |

Copies on iPhone and iPad, Tizen TVs and the portable Windows folder don't check for updates.

The player checks at start and once a day, never in offline mode. *Settings → About → Look for updates* turns it off
([what's sent](../SECURITY.md#what-leaves-your-network)). The server doesn't update with the player: update it too and
keep both on the same version ([back up first](server.md#data-directory)).

## Phones, TVs and the car

Phones stay in portrait; tablets rotate. On a touch screen:

- swipe the mini player to skip
- pull a list down past its top to search
- long-press an album, artist or playlist for a preview with its menu
- pinch to resize tiles (tablets and touchpads)

On a TV (Android TV or Tizen), the arrows move, the center button plays and Back goes back. Some formats may not play on
Tizen ([audio.md](audio.md#tizen)).

Android Auto shows your albums, artists, playlists and favorites once the phone is signed in, and supports voice search.

## Where things are

| What | Where |
|---|---|
| Player data: library, settings, sign-in (`wiretune.db`), log (`wiretune.log`), lyrics and artist pictures from the internet | `~/.config/Wiretune` (Linux), `%APPDATA%\Wiretune` (Windows), `~/Library/Application Support/Wiretune` (macOS), the app's private storage (phones, TVs) |
| Cover cache for server music, up to 300 MB | `ServerCovers` in the system cache folder (`~/.cache/com.wiretune.player` on Linux) |
| Downloads | `Wiretune` in your music folder (computers, Android), the app's private storage (iOS, Tizen) |

The server's data: [server.md](server.md#data-directory).

## Environment variables

| Variable | Effect |
|---|---|
| `WIRETUNE_DATA_DIR` | Use another data folder, such as a throw-away one for testing. The server reads it too (as `--data-dir`), so a server and a player on one machine need different ones, or they delete each other's cached covers |
| `WIRETUNE_LOG_LEVEL` | `debug`, `info` (default), `warn` or `error`. `debug` also logs paths and device names |
| `WIRETUNE_NO_ARTIST_PICTURES=1` | Don't fetch artist pictures |
| `WIRETUNE_NO_ONLINE_LYRICS=1` | Don't fetch lyrics, whatever the setting says |
| `WIRETUNE_NO_UPDATE_CHECK=1` | Don't check for updates, whatever the setting says |

## Troubleshooting

| Problem | Fix |
|---|---|
| *None of the output devices supports exclusive mode…* | No device supports it. On Linux there's no ALSA hardware device (check `aplay -l`). Press **Refresh** once there is. |
| Exclusive playback on Linux fails with *device busy* | Another player on the same `hw:` device, or a sound server without device reservation, holds the card. Close it, or pick another output. |
| No spectrum on the desktop | Install `ffmpeg` and make sure it's on the `PATH`. |
| The Linux player won't start: missing `libmpv` | Install `libmpv2` (Debian, Ubuntu), `mpv-libs` (Fedora) or `mpv` (Arch). |
| Favorites or playlists are empty after signing in | Check it's the same account as before. If it is, the server may have started with a fresh data folder ([server.md](server.md#troubleshooting)). |
| An iPhone can't reach a server on the LAN | Allow *Local Network* for Wiretune in *Settings → Privacy & Security*. |
| No cast button | *Settings → Remote control* says why. If it keeps connecting, the proxy may not pass WebSockets ([server.md](server.md#away-from-home)). |
| Nothing plays, and no error | Read `wiretune.log` in the player's data folder ([above](#where-things-are)). |
