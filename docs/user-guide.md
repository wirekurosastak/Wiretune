# User guide

## First start

To use a server, enter its address (`http://<server-ip>:5200`) and press **Connect**. A new server first asks you to
create the administrator account with its setup code ([server.md](server.md#start-it)); any other server asks you to
sign in. A sign-in lasts 24 hours, or 90 days with *Keep me signed in*. If the server becomes unreachable, the player
keeps trying and reconnects by itself.

On a computer or an Android phone you can also play your own files, with or without a server: choose **Continue without
a server** if you don't have one, then pick your music folder in *Settings → Library* and press **Scan**. On Android the
first scan asks for permission to read your music.

The interface always starts in English; Hungarian and German are in *Settings → Appearance*.

## The library

Tracks with the same album title and album artist form an album, and a folder of tracks with one album title is one
album even when their artist tags disagree. A folder of one artist's songs from several albums becomes a single album
named after the folder (*ACDC Essentials*), unless it holds a complete album or several artists. Your files are never
changed.

When a file has one `ARTIST` field per artist, or an `ARTISTS` field, the song lists every artist, each with a link.
Names are never split at `&`, `,` or `/`, so *Simon & Garfunkel* stays one artist.

Every album and track carries a quality badge: **gold** for hi-res (lossless above 16 bit or 48 kHz), **silver** for
CD-quality lossless and **bronze** for lossy. An album or playlist shows its weakest track's badge, or *MIXED* when the
formats differ.

Covers come from the picture embedded in the file, or else from a `cover`, `folder` or `front` image (`.jpg`, `.jpeg`
or `.png`), `albumart.jpg` or `artwork.jpg` next to it. From Android 13 on, the player may read only audio files in a
local folder, so covers there have to be embedded.

Artist pictures come from the internet ([what's sent](../SECURITY.md#what-leaves-your-network)). To use your own, put an
`artist.jpg` (or `.jpeg`, `.png`) in a folder named after the artist, such as `Miles Davis/artist.jpg`; for an artist
without a folder of their own, create one at the top of the music folder holding just the picture. With a server, it
goes in the server's music folder.

A song that is both on the server and in your local folder shows once, and the local copy wins because it plays without
the network. Two tracks count as the same song when their titles and artists match, ignoring case, punctuation and
tails such as *(2011 Remaster)*, and their lengths are close; *Live*, *Acoustic* and *Demo* versions stay separate. The
player's own downloads never count as local music.

New music shows up by itself. A computer watches its local folder while the player runs, a phone checks it again
whenever you return to the app, and the server watches its own folder ([server.md](server.md#scanning)). An
administrator can force a server rescan with **Reindex** in *Settings → Library*.

A sort order lasts until the app closes, and pressing the active sort again reverses it. Hidden artists, albums and
tracks come back from *Settings → Hidden content*.

## Playing music

Clicking a track plays the list it's in, and every *⋮* menu has **Play next** and **Add to queue**. The queue survives a
restart. The sleep timer (the moon) pauses after 15, 30, 45 or 60 minutes, or at the end of the track.

Lyrics come from the file when it has them, and timed lyrics follow the song: tap a line to jump there. For other tracks
the player asks [LRCLIB](https://lrclib.net), unless *Settings → Lyrics from the internet* is off.

Tracks of the same format play without a gap ([audio.md](audio.md#gapless-playback)). A track that can't play stops the
queue and says why, instead of skipping ahead.

| Key (⌘ instead of Ctrl on a Mac) | Action |
|---|---|
| Space | Play or pause |
| Ctrl+→, Ctrl+← | Next or previous track |
| Shift+→, Shift+← | Seek 10 seconds forward or back |
| Ctrl+↑, Ctrl+↓ | Volume up or down |
| Ctrl+F | Search |
| Escape | Back |

## Favorites and playlists

For music from a server, favorites and playlists belong to your account on the server, so every device shows the same
ones; while the player is offline they're read-only. For local music they're kept on the device, but a playlist created
while signed in is a server playlist.

The server identifies a track by its file's path, so moving or renaming a file there drops it from favorites and
playlists. **Most played** and **Recently played** are built from your plays and hold 50 tracks each. To reorder a
playlist, drag its tracks; on a phone, long-press first.

## Downloads

A track, an album, an artist, a playlist or all your favorites can be kept on the device to play without the server: use
the download button next to *Play*, or *⋮ → Download to this device*. With *Sync downloads* on (the default), downloads
follow changes on the server; with it off, each download fetches its tracks once. Files are saved in the
[downloads folder](#where-things-are) as `Album artist/Album/01 - Title.flac`, and signing out deletes them.

## Remote control

Every player signed in to the same account sees the others. Pick a device with the cast button and this player becomes
its remote; *This device* brings playback back, and control also returns if the other device drops off the network.
*Settings → Remote control* turns the feature off or renames this device.

## Phones, TVs and the car

Phones stay in portrait, and tablets rotate. On a touch screen, swipe the mini player to skip, pull a list down past its
top to search, and long-press an album, artist or playlist for a preview with its menu; on tablets and touchpads, pinch
to resize the tiles.

On a TV (Android TV or Tizen), the arrows move, the center button plays and Back goes back. Some formats may not play on
Tizen ([audio.md](audio.md#tizen)). Once the phone is signed in, Android Auto lists your albums, artists, playlists and
favorites and takes voice search.

## Where things are

| What | Where |
|---|---|
| Player data: library, settings, sign-in (`wiretune.db`), log (`wiretune.log`), lyrics and artist pictures from the internet | `~/.config/Wiretune` (Linux), `%APPDATA%\Wiretune` (Windows), `~/Library/Application Support/Wiretune` (macOS), the app's private storage (phones, TVs) |
| Cover cache for server music, up to 300 MB | `ServerCovers` in the system cache folder (`~/.cache/com.wiretune.player` on Linux) |
| Downloads | `Wiretune` in your music folder (computers, Android), the app's private storage (iOS, Tizen) |

The server keeps its data in [its own folder](server.md#data-directory).

## Environment variables

| Variable | Effect |
|---|---|
| `WIRETUNE_DATA_DIR` | Use another data folder, for example a throw-away one for testing |
| `WIRETUNE_LOG_LEVEL` | `debug`, `info` (the default), `warn` or `error`; `debug` also logs paths and device names |
| `WIRETUNE_NO_ARTIST_PICTURES=1` | Don't fetch artist pictures |
| `WIRETUNE_NO_ONLINE_LYRICS=1` | Don't fetch lyrics, whatever the setting says |

## Troubleshooting

| Problem | What to do |
|---|---|
| *None of the output devices supports exclusive mode…* | No device can do it. On Linux there's no ALSA hardware device (check `aplay -l`); press **Refresh** once there is. |
| Exclusive playback on Linux fails with *device busy* | Another player on the same `hw:` device, or a sound server without device reservation, holds the card. Close it, or pick another output. |
| No spectrum on the desktop | Install `ffmpeg` and make sure it's on the `PATH`. |
| The Linux player won't start: missing `libmpv` | Install it: `libmpv2` on Debian and Ubuntu, `mpv-libs` on Fedora, `mpv` on Arch. |
| Favorites or playlists are empty after signing in | Check that you used the same account as before. If you did, the server may have started with a fresh data folder ([server.md](server.md#troubleshooting)). |
| An iPhone can't reach a server on the LAN | Allow *Local Network* for Wiretune in *Settings → Privacy & Security*. |
| No cast button | *Settings → Remote control* says why. If it keeps connecting, the server's proxy may not pass WebSockets on ([server.md](server.md#reverse-proxy-and-tls)). |
| Nothing plays, and nothing says why | Read `wiretune.log` in the player's data folder ([above](#where-things-are)). |
