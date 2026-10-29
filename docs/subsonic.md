# Other apps

The server also speaks the [Subsonic API](https://www.subsonic.org/pages/api.jsp) with the
[OpenSubsonic](https://opensubsonic.netlify.app) additions that fit, so apps such as Feishin, Symfonium, Amperfy and
Tempo can play from it. They see the same library, favorites, play counts and playlists as the Wiretune players.

## Connect an app

1. Make an **app password**. These apps send their secret with every request, so they get a password of their own
   instead of your account password. It opens this API and nothing else, and anyone holding it can't change your
   account. In the player, open **Settings → Account & connection → Other apps** and choose **Make a new password**.
   It is shown once: copy it there. Making another replaces the first, and **Delete** removes it. Changing or
   resetting your account password removes it too. Without a player at hand, the API does the same
   (`POST /api/me/app-password` with your sign-in token, [api.md](api.md)).
2. In the app, add a Subsonic or OpenSubsonic server with the server's address (`http://nas:5200`, or `https://…`),
   your user name and the app password as the password. An app that offers an API key takes the app password as the key.

If an app asks for "legacy authentication", either works: both send the app password.

## What works

Browsing (`getArtists`, `getIndexes`, `getArtist`, `getAlbum`, `getAlbumList2` (the type *highest* is always empty: there are no ratings),
`getMusicDirectory`, `getSong`, `getGenres`, `getRandomSongs`, `getSongsByGenre`, `search2`, `search3`), playing
(`stream`, `download`, `getCoverArt`, `getLyricsBySongId`), favorites (`star`, `unstar`, `getStarred`, `getStarred2`),
`scrobble`, playlists (`getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`), and
`getUser`, `getMusicFolders`, `getScanStatus`, `startScan` (administrators). Answers are JSON with `f=json`, XML
otherwise.

- **`stream`** sends the original file, never a converted one, so `maxBitRate` and `format` are ignored.
- **Songs only.** Wiretune has favorites for songs. Starring an album or an artist is refused with an error, not
  pretended. There are no ratings, podcasts, radio stations, shares or bookmarks: those calls answer with an empty list.
- **Search** ignores case and accents. An empty query returns everything, a page at a time.
- **Covers** are sent at their full size; `size` is ignored.
- **Playlists** belong to the account. They are not shared.
- A play is counted when an app reports it as played (`scrobble` without `submission=false`).

The API follows the Subsonic version 1.16.1. If an app misbehaves, `wiretune-server.log` at `--log-level debug` shows
what it asked for.
