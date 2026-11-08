// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../view_models/app_section.dart';
import '../widgets/ambient.dart';
import 'library_pages.dart';
import 'playlists_page.dart';
import 'settings_page.dart';

/// The page of a navigation section; the same in both layouts.
Widget sectionPage(AppSection section) => switch (section) {
  AppSection.tracks => const TracksPage(),
  AppSection.albums => const ViewedAccent(child: AlbumsPage()),
  AppSection.artists => const ViewedAccent(child: ArtistsPage()),
  AppSection.playlists => const PlaylistsPage(),
  AppSection.favorites => const FavoritesPage(),
  AppSection.settings => const SettingsPage(),
};

/// The icon of a section, in the sidebar and the phone's tab bar alike.
IconData sectionIcon(AppSection section) => switch (section) {
  AppSection.artists => Icons.person_rounded,
  AppSection.albums => Icons.album,
  AppSection.tracks => Icons.music_note_rounded,
  AppSection.favorites => Icons.favorite_rounded,
  AppSection.playlists => Icons.queue_music_rounded,
  AppSection.settings => Icons.tune_rounded,
};
