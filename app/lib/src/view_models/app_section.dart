/// The top-level pages of the app: the sidebar entries of the wide layout and the bottom bar of the phone layout. The
/// order of the values is the order they were added in, not the order they are drawn in (see [navVisualOrder]).
enum AppSection { tracks, albums, artists, playlists, favorites, settings }

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
