# User guide

## First start

**With a server:** enter its address (`http://<server-ip>:5200`) and press **Connect**. On a new server, create the
administrator account with the setup code ([server.md](server.md#start-it)); otherwise sign in. A sign-in lasts 24
hours, or 90 days with *Keep me signed in*.

**Adding a phone:** on a signed-in device, open *Settings → Account & connection → Connect a phone* and scan a QR code
with the phone's camera. *Server only* fills in the address; *Sign in as …* also signs the phone in to your account (it
works once, for 5 minutes).

**With your own files** (computers and Android phones): choose **Continue without a server** if you have none, pick
your music folder in *Settings → Local folder* and press **Scan**.

*Settings → Appearance* has the language (English, Hungarian, German) and the theme: **Airy** (the cover's colors fill
the window) or **Dark** (pages on black).

## The library

Your files are never changed.

- **Albums:** tracks with the same album title and album artist. A folder of tracks with one album title is one album
  even if the artist tags differ. A folder of one artist's songs from several albums becomes one album named after the
  folder (*ACDC Essentials*), unless it holds a complete album or several artists.
- **Several artists:** if a file has one `ARTIST` field per artist, or an `ARTISTS` field, every artist is listed with
  a link. Names are never split at `&`, `,` or `/`: *Simon & Garfunkel* stays one artist.
- **Quality badges:** **gold** for hi-res (lossless above 16 bit or 48 kHz), **silver** for CD-quality lossless,
  **bronze** for lossy. An album or playlist shows its weakest track's badge, or *MIXED* when formats differ.
- **Covers:** the picture embedded in the file, or a `cover`, `folder`, `front`, `albumart` or `artwork` image
  (`.jpg`, `.jpeg`, `.png`) next to it. In a local folder on Android 13 and later, only embedded covers work.
- **Artist pictures** come from the internet ([what's sent](../SECURITY.md#what-leaves-your-network)). To use your own,
  put an `artist.jpg` (or `.jpeg`, `.png`) in a folder named after the artist, such as `Miles Davis/artist.jpg`, in the
  server's music folder or your local one. For an artist without a folder, create one with just the picture.
- **Duplicates:** a song both on the server and in your local folder shows once, and the local copy plays. Two tracks
  are the same song when title and artist match (ignoring case, punctuation and tails such as *(2011 Remaster)*) and
  the lengths are close. *Live*, *Acoustic* and *Demo* versions stay separate. Downloads never count as local music.
- **New music** appears by itself ([server.md](server.md#scanning)). A phone checks its local folder when you return
  to the app. **Reindex** in *Settings → Library* rescans the server (administrator).
- **Genres and labels** come from the tags, or with a server from Deezer for albums whose files don't name them
  ([what's sent](../SECURITY.md#what-leaves-your-network)). An album's page ends with its label and ℗ line; tap them
  for the label's other albums.
- **Credits** (a track's *⋮ → Credits*): the composer from the tags and, with a server, who wrote, produced, played and
  mixed it, from MusicBrainz.
- **Related music:** an album's page ends with *More by* its artist and *Similar albums*, an artist's with *Related
  artists*: artists credited together first, then the same genre and era.
- **Genre filter:** Albums, Artists, Tracks and Favorites narrow to a genre (the genre button on a computer, the sort
  sheet on a phone).
- **Sorting** lasts until the app closes. Press the active sort again to reverse it. *Plays* puts what you played
  most first.
- **Back** returns to where you opened a page from, however far you went (an artist, its album, a similar album…).
  Pressing the current tab again goes back to its list.
- **Hidden** artists, albums and tracks come back from *Settings → Hidden content*.

## Playing music

Clicking a track plays the list it's in. Every *⋮* menu has **Play next** and **Add to queue**. The queue survives a
restart; drag a song by its ≡ to move it (a long press on a phone, its arrows on a TV). **Save as playlist** in the
queue's header keeps it. When the queue ends, similar music plays on (*Settings → Audio → Autoplay*). The sleep timer
pauses after 15, 30, 45 or 60 minutes, or at the end of the track.

*Playing from* in the player opens what the music was played from. A click on the quality tag shows the file and its
way to the speakers (the signal path).

Lyrics come from the file, else from [LRCLIB](https://lrclib.net) (*Settings → Appearance → Lyrics from the
internet*). Tap a timed line to jump there.

Tracks of the same format play without a gap ([audio.md](audio.md#gapless-playback)). A track that can't play stops the
queue and says why.

| Key (⌘ instead of Ctrl on a Mac) | Action |
|---|---|
| Space | Play or pause |
| Ctrl+→, Ctrl+← | Next or previous track |
| Shift+→, Shift+← | Seek 10 seconds forward or back |
| Ctrl+↑, Ctrl+↓ | Volume up or down |
| Ctrl+F | Search |
| Escape | Back |

## Favorites and playlists

With a server, favorites and playlists belong to your account and are the same on every device (read-only while
offline). Without one, they're stored on the device. A moved or renamed file keeps its favorites and playlists.

To reorder a playlist, drag its tracks (on a phone, long-press first). **Most played**, **Recently played** and
**Recently added** fill themselves, 50 tracks each.

**Your listening**, at the top of Playlists, shows your most played artists, albums, tracks and genres, and the
minutes: this month, this year (both need a server) or all time.

**Share…** on a server playlist's page (on a phone, in its ⋮) shares it with the friends you tick. Once they join from
the bell, they can add, remove and reorder its tracks; only you rename or delete it. **Leave playlist** takes a shared
one off your list.

## Downloads

Download a track, album, artist, playlist or all favorites with the download button next to *Play*, or *⋮ → Download
to this device*. With *Sync downloads* on (the default), downloads follow changes on the server; on mobile data those
wait for Wi-Fi, and only what you chose yourself downloads. Files go to the [downloads folder](#where-things-are) as
`Album artist/Album/01 - Title.flac`. Signing out deletes them.

*Settings → Account & connection → Offline mode* shows only downloads and local music, and stops looking for the
server. What you play while the server is out of reach is counted when it's back.

Phones and computers also cache the server tracks they play, each once all of it has arrived (usually a moment after
it starts), and play them from the [cache](#where-things-are) next time. It holds up to 2 GB; the tracks played longest
ago go first.

## Friends

Everyone else with an account on your server is a friend.

- **Recommend…** in a track's, album's or artist's ⋮ sends it to the friends you pick, with a note. What friends send
  you waits under the bell. Nothing you've hidden shows there.
- **Blend** on the Playlists page invites a friend to a playlist mixed from what you both play and love, without what
  either of you hides. **Leave Blend** ends it for both.
- **Listen together…** in the cast menu invites friends to hear what you play, in step. They can skip, seek and add to
  the queue; pausing is each one's own. Playing something else leaves.
- **Block** in *Settings → Friends* stops someone's recommendations and invites. They aren't told.

## Remote control

Players signed in to the same account see each other: pick one with the cast button to play there and control it
(on a computer it's in the player bar). *This device* brings playback back.
*Settings → Remote control* turns it off or renames this device.

*Others on this server can play here* lets other accounts play on this device too, such as a living-room TV: *Only
music I don't hide* or *Any music*. Only players on the same network see it (your own devices see each other from
anywhere). Their plays count for them. Someone you blocked, or who blocked you, never sees the device. It's *Only music I
don't hide* by default, *Off* on a phone.

The cast button also lists **streamers** on your network (UPnP/DLNA renderers: hi-fi streamers, amplifiers, speakers).
They play server music in its original quality, straight from the server, with a short gap between tracks. The
streamer must reach the server at the address you signed in with, so not `localhost`. Not on iPhone.

## Updates

When a new version is out, a banner says so. **Update** downloads and installs it; × hides the banner until the next
check.

| Installed from | What **Update** does |
|---|---|
| The Linux folder, or its `install.sh` | Replaces the folder and starts the new version |
| The `.deb` or `.rpm` | Asks for your password, installs the new package with apt or dnf, and starts it |
| The Windows installer | Closes the player, runs the new installer silently, and starts it again |
| The macOS disk image | Opens the new disk image: drag Wiretune into *Applications* over the old one |
| An Android APK | Hands the new APK to Android, which asks before installing |

Copies on iPhone and iPad, Tizen TVs and the portable Windows folder don't check for updates.

The player checks at start and once a day; *Settings → About → Look for updates* turns it off. Update the server too
and keep both on the same version ([how](server.md#updating)): *Settings → About* says when the server is older than
the player.

## Phones, TVs and the car

Phones stay in portrait; tablets rotate. On a touch screen:

- the full-screen player has the queue at its bottom left, and its ⋮ at the bottom right has the lyrics, the sleep
  timer and the song's menu; the cast button is at its top right (on the pages too while nothing is loaded)
- swipe the mini player, or the full-screen player's cover, to skip
- swipe a song in the queue to the left to take it out
- pull a list down past its top to search; the search shows your recent searches, and its results narrow to artists,
  albums, tracks or playlists
- a long list has a thumb at its right edge while it scrolls: drag it to jump
- the top of a ⋮ menu opens what it's for
- long-press an album, artist or playlist for a preview with its menu
- pinch to resize tiles (tablets and touchpads)

On Android, the media notification and Android Auto have a heart and a shuffle button, and the home-screen widget shows
what plays (two cells tall, with the heart and shuffle too).

On a TV (Android TV or Tizen), the arrows move, the center button plays and Back goes back. Some formats may not play on
Tizen ([audio.md](audio.md#tizen)).

Android Auto shows your albums, artists, playlists and favorites once the phone is signed in, with voice search.

## Where things are

| What | Where |
|---|---|
| Player data: library, settings, sign-in (`wiretune.db`), log (`wiretune.log`), lyrics and artist pictures from the internet | `~/.config/Wiretune` (Linux), `%APPDATA%\Wiretune` (Windows), `~/Library/Application Support/Wiretune` (macOS), the app's private storage (phones, TVs) |
| Cover cache for server music, up to 300 MB | `ServerCovers` in the system cache folder (`~/.cache/com.wiretune.player` on Linux) |
| Downloads | `Wiretune` in your music folder (computers, Android), the app's private storage (iOS, Tizen) |
| Cached tracks, up to 2 GB (not on TVs) | `Music/Wiretune/Cache`, the app's private storage (iOS) |

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
