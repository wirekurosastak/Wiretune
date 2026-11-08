// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// The top-level pages of the app: the sidebar entries of the wide layout and the bottom bar of the phone layout. The
/// order of the values is the order they were added in, not the order they are drawn in (see [navVisualOrder]).
enum AppSection { tracks, albums, artists, playlists, favorites, settings }

/// The app's look, picked under Settings → Theme. Airy: the cover of what plays (or of the album or the artist that is
/// open) washes the whole window. Dark: the pages lie on black (on a computer in a frame, the window around it in the
/// colours of the song that plays), and an open album's or artist's cover glows at the top. In both an album's or an
/// artist's page takes its cover's colour as its accent ([ViewedAccent]); the players keep the song's.
enum WiretuneTheme { airy, dark }

/// What the phone's full-screen player shows over its controls: the track that plays (its cover, title and menu), or
/// the queue or the lyrics, which its buttons at the bottom open.
enum NowPlayingTab { track, queue, lyrics }

/// Which way the animated logo's wave runs: downwards / inwards, or upwards / back.
enum NavWaveDirection { leftToRight, rightToLeft }

/// Where a section is drawn in the sidebar, counted from the top: the order the navigation wave runs in.
int navVisualOrder(AppSection section) => switch (section) {
  AppSection.artists => 0,
  AppSection.albums => 1,
  AppSection.tracks => 2,
  AppSection.favorites => 3,
  AppSection.playlists => 4,
  AppSection.settings => 5,
};
