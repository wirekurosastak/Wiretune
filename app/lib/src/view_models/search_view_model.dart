// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'player_view_model.dart';

enum BestMatchKind { artist, album, track }

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

  final LibraryService _library;
  final PlayerViewModel _player;

  /// The playlists as the Playlists page lists them, the automatic ones first.
  final List<Playlist> Function() _allPlaylists;
  late final List<void Function()> _unsubscribers;

  String query = '';

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
    query = newQuery?.trim() ?? '';
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
    final lower = q.toLowerCase();
    matchingTracks = _library.search(q).take(maxTracks).toList();
    matchingAlbums = _library.albums
        .where((a) => a.title.toLowerCase().contains(lower) || a.artist.toLowerCase().contains(lower))
        .take(maxCards)
        .toList();
    matchingArtists = _library.artists.where((a) => a.name.toLowerCase().contains(lower)).take(maxCards).toList();
    // An artist only featured on other people's songs has no place in the artist list, but is found by name.
    if (!matchingArtists.any((a) => a.name.toLowerCase() == lower)) {
      final guest = _library.getArtistByName(q);
      if (guest != null) matchingArtists = [guest, ...matchingArtists.take(maxCards - 1)];
    }
    matchingPlaylists = _allPlaylists().where((p) => p.name.toLowerCase().contains(lower)).take(maxCards).toList();
    bestMatch = _computeBestMatch(lower);
    notifyListeners();
  }

  BestMatch? _computeBestMatch(String q) {
    T? firstWhere<T>(List<T> items, bool Function(T) test) => items.where(test).firstOrNull;

    final artist =
        firstWhere(matchingArtists, (a) => a.name.toLowerCase() == q) ??
        firstWhere(matchingArtists, (a) => a.name.toLowerCase().startsWith(q));
    if (artist != null) return _artistMatch(artist);

    final album =
        firstWhere(matchingAlbums, (a) => a.title.toLowerCase() == q) ??
        firstWhere(matchingAlbums, (a) => a.title.toLowerCase().startsWith(q));
    if (album != null) return _albumMatch(album);

    final track =
        firstWhere(matchingTracks, (t) => t.title.toLowerCase() == q) ??
        firstWhere(matchingTracks, (t) => t.title.toLowerCase().startsWith(q)) ??
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
      if (artist.tracks.isNotEmpty) _player.playQueue(artist.tracks);
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
      if (album.tracks.isNotEmpty) _player.playQueue(album.tracks);
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
    play: () => _player.playQueue([track], track),
  );

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}
