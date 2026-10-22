// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// The top-level pages of the app: the sidebar entries of the wide layout and the bottom bar of the phone layout. The
/// order of the values is the order they were added in, not the order they are drawn in (see [navVisualOrder]).
enum AppSection { tracks, albums, artists, playlists, favorites, settings }

/// The tabs of the phone's full-screen player: the track that plays (its cover, title and controls), the queue and the
/// lyrics.
enum NowPlayingTab { track, queue, lyrics }

/// What a swipe left or right does in the phone's full-screen player: the next or previous track, or the next or
/// previous of its tabs ([NowPlayingTab]). The user picks it at the first swipe.
enum PlayerSwipe { tracks, tabs }

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
