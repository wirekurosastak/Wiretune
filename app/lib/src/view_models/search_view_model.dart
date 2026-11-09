// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'player_view_model.dart';

enum BestMatchKind { artist, album, track }

/// What the results narrow to: one kind of them, longer lists of it, and no best match.
enum SearchFilter { artists, albums, tracks, playlists }

/// The most likely result of a search, shown big at the top.
class BestMatch {
  BestMatch({
    required this.kind,
    required this.item,
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.coverPath,
    required this.tracks,
    required this.play,
  });

  final BestMatchKind kind;

  /// The [Artist], [Album] or [Track] it is: its ⋮ is that one's menu.
  final Object item;
  final String title;
  final String subtitle;
  final String meta;
  final String? coverPath;

  /// What [play] plays: its button pauses and resumes them while they are the queue.
  final List<Track> tracks;
  final void Function() play;

  String get typeLabel => Localizer.get(switch (kind) {
    BestMatchKind.artist => 'TypeArtist',
    BestMatchKind.album => 'TypeAlbum',
    BestMatchKind.track => 'TypeTrack',
  });
}

/// The search results: up to 25 tracks, 12 albums, 12 artists and 12 playlists, and a best match.
class SearchViewModel extends ChangeNotifier {
  SearchViewModel(this._library, this._player, this._allPlaylists) {
    void searchAgain(_) {
      if (hasQuery) _execute(query);
    }

    _unsubscribers = [_library.libraryChanged.listen(searchAgain), _library.playlistsChanged.listen(searchAgain)];
  }

  static const int maxTracks = 25;
  static const int maxCards = 12;

  /// As many of one kind while the results are narrowed to it ([filter]).
  static const int maxFiltered = 100;

  /// How many searches it remembers ([recent]).
  static const int maxRecent = 10;
  static const String _recentPreference = 'recent_searches';

  final LibraryService _library;
  final PlayerViewModel _player;

  /// The playlists as the Playlists page lists them, the automatic ones first.
  final List<Playlist> Function() _allPlaylists;
  late final List<void Function()> _unsubscribers;

  String query = '';

  /// The kind of results shown alone; null for all of them.
  SearchFilter? filter;

  /// Shows only [value]'s results (null: all of them), more of them; for the same query until it changes.
  void setFilter(SearchFilter? value) {
    if (filter == value) return;
    filter = value;
    if (hasQuery) {
      _execute(query);
    } else {
      notifyListeners();
    }
  }

  /// What was searched for on this device, the latest first: the searches that led somewhere (a result opened or
  /// played).
  List<String> get recent {
    try {
      final saved = jsonDecode(_library.getPreference(_recentPreference) ?? '[]');
      return saved is List ? [for (final q in saved) ?q as String?] : const [];
    } on FormatException {
      return const [];
    }
  }

  /// Remembers the query on show as a recent search: a result of it was opened or played.
  void rememberQuery() {
    final q = query.trim();
    if (q.isEmpty) return;
    final kept = [
      q,
      for (final other in recent)
        if (!equalsIgnoreCase(other, q)) other,
    ].take(maxRecent).toList();
    _library.setPreference(_recentPreference, jsonEncode(kept));
    notifyListeners();
  }

  /// Forgets [q] from the recent searches.
  void forget(String q) {
    _library.setPreference(
      _recentPreference,
      jsonEncode([
        for (final other in recent)
          if (other != q) other,
      ]),
    );
    notifyListeners();
  }

  /// Whether anything is searched for (`MainViewModel.isSearchActive` says whether the results are on show).
  bool get hasQuery => query.isNotEmpty;
  BestMatch? bestMatch;
  List<Track> matchingTracks = const [];
  List<Album> matchingAlbums = const [];
  List<Artist> matchingArtists = const [];
  List<Playlist> matchingPlaylists = const [];

  bool get hasTracks => matchingTracks.isNotEmpty;
  bool get hasAlbums => matchingAlbums.isNotEmpty;
  bool get hasArtists => matchingArtists.isNotEmpty;
  bool get hasPlaylists => matchingPlaylists.isNotEmpty;
  bool get hasResults => hasTracks || hasAlbums || hasArtists || hasPlaylists;

  void refreshLocalizedTexts() {
    if (hasQuery) _execute(query);
  }

  void updateQuery(String? newQuery) {
    final next = newQuery?.trim() ?? '';
    // Another search starts with all of its results.
    if (next != query) filter = null;
    query = next;
    if (hasQuery) {
      _execute(query);
      return;
    }
    matchingTracks = const [];
    matchingAlbums = const [];
    matchingArtists = const [];
    matchingPlaylists = const [];
    bestMatch = null;
    notifyListeners();
  }

  void _execute(String q) {
    final lower = foldForSearch(q);
    // Narrowed to one kind, that kind alone and more of it, as Spotify's chips do.
    final only = filter;
    int most(SearchFilter kind, int usual) => only == null ? usual : (only == kind ? maxFiltered : 0);
    final cards = most(SearchFilter.albums, maxCards);
    matchingTracks = _library.search(q).take(most(SearchFilter.tracks, maxTracks)).toList();
    matchingAlbums = _library.albums
        .where((a) => foldForSearch(a.title).contains(lower) || foldForSearch(a.artist).contains(lower))
        .take(cards)
        .toList();
    final artists = most(SearchFilter.artists, maxCards);
    matchingArtists = _library.artists.where((a) => foldForSearch(a.name).contains(lower)).take(artists).toList();
    // An artist only featured on other people's songs has no place in the artist list, but is found by name.
    if (artists > 0 && !matchingArtists.any((a) => foldForSearch(a.name) == lower)) {
      final guest = _library.getArtistByName(q);
      if (guest != null) matchingArtists = [guest, ...matchingArtists.take(artists - 1)];
    }
    matchingPlaylists = _allPlaylists()
        .where((p) => foldForSearch(p.name).contains(lower))
        .take(most(SearchFilter.playlists, maxCards))
        .toList();
    bestMatch = only == null ? _computeBestMatch(lower) : null;
    notifyListeners();
  }

  BestMatch? _computeBestMatch(String q) {
    T? firstWhere<T>(List<T> items, bool Function(T) test) => items.where(test).firstOrNull;

    final artist =
        firstWhere(matchingArtists, (a) => foldForSearch(a.name) == q) ??
        firstWhere(matchingArtists, (a) => foldForSearch(a.name).startsWith(q));
    if (artist != null) return _artistMatch(artist);

    final album =
        firstWhere(matchingAlbums, (a) => foldForSearch(a.title) == q) ??
        firstWhere(matchingAlbums, (a) => foldForSearch(a.title).startsWith(q));
    if (album != null) return _albumMatch(album);

    final track =
        firstWhere(matchingTracks, (t) => foldForSearch(t.title) == q) ??
        firstWhere(matchingTracks, (t) => foldForSearch(t.title).startsWith(q)) ??
        matchingTracks.firstOrNull;
    if (track != null) return _trackMatch(track);

    if (matchingArtists.isNotEmpty) return _artistMatch(matchingArtists.first);
    if (matchingAlbums.isNotEmpty) return _albumMatch(matchingAlbums.first);
    return null;
  }

  BestMatch _artistMatch(Artist artist) => BestMatch(
    kind: BestMatchKind.artist,
    item: artist,
    title: artist.name,
    subtitle: Localizer.get('SubtitleArtist'),
    meta:
        '${Localizer.format('AlbumCount', [artist.albumCount])} • ${Localizer.format('TrackCount', [artist.trackCount])}',
    coverPath: artist.picturePath,
    tracks: artist.tracks,
    play: () {
      rememberQuery();
      if (artist.tracks.isNotEmpty) _player.playQueue(artist.tracks, null, () => artist.name, artist);
    },
  );

  BestMatch _albumMatch(Album album) => BestMatch(
    kind: BestMatchKind.album,
    item: album,
    title: album.title,
    subtitle: album.artist,
    meta: album.releaseYear != null
        ? '${album.releaseYear} • ${Localizer.format('TrackCount', [album.trackCount])}'
        : Localizer.format('TrackCount', [album.trackCount]),
    coverPath: album.coverArtPath,
    tracks: album.tracks,
    play: () {
      rememberQuery();
      if (album.tracks.isNotEmpty) _player.playQueue(album.tracks, null, () => album.title, album);
    },
  );

  BestMatch _trackMatch(Track track) => BestMatch(
    kind: BestMatchKind.track,
    item: track,
    title: track.title,
    subtitle: '${track.artist} • ${track.album}',
    meta: '${track.formattedDuration} • ${track.format.tagSpec}',
    coverPath: track.coverArtPath,
    tracks: [track],
    play: () {
      rememberQuery();
      _player.playQueue([track], track);
    },
  );

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}
