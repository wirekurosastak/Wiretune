// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/widgets.dart';

import '../view_models/app_section.dart';
import 'library_pages.dart';
import 'playlists_page.dart';
import 'settings_page.dart';

/// The page of a navigation section; the same in both layouts.
Widget sectionPage(AppSection section) => switch (section) {
  AppSection.tracks => const TracksPage(),
  AppSection.albums => const AlbumsPage(),
  AppSection.artists => const ArtistsPage(),
  AppSection.playlists => const PlaylistsPage(),
  AppSection.favorites => const FavoritesPage(),
  AppSection.settings => const SettingsPage(),
};
