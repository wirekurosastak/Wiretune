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
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.coverPath,
    required this.play,
    required this.open,
  });

  final BestMatchKind kind;
  final String title;
  final String subtitle;
  final String meta;
  final String? coverPath;
  final void Function() play;

  /// What a tap on the card does: an artist or an album opens, a track plays.
  final void Function() open;

  String get typeLabel => Localizer.get(switch (kind) {
    BestMatchKind.artist => 'TypeArtist',
    BestMatchKind.album => 'TypeAlbum',
    BestMatchKind.track => 'TypeTrack',
  });
}

/// The search results: up to 25 tracks, 12 albums and 12 artists, and a best match.
class SearchViewModel extends ChangeNotifier {
  SearchViewModel(this._library, this._player, this._openAlbum, this._openArtist) {
    _unsubscribe = _library.libraryChanged.listen((_) {
      if (isSearchActive) _execute(query);
    });
  }

  static const int maxTracks = 25;
  static const int maxCards = 12;

  final LibraryService _library;
  final PlayerViewModel _player;
  final void Function(Album album) _openAlbum;
  final void Function(Artist artist) _openArtist;
  late final void Function() _unsubscribe;

  String query = '';
  bool isSearchActive = false;
  BestMatch? bestMatch;
  List<Track> matchingTracks = const [];
  List<Album> matchingAlbums = const [];
  List<Artist> matchingArtists = const [];

  bool get hasTracks => matchingTracks.isNotEmpty;
  bool get hasAlbums => matchingAlbums.isNotEmpty;
  bool get hasArtists => matchingArtists.isNotEmpty;
  bool get hasResults => hasTracks || hasAlbums || hasArtists;

  void refreshLocalizedTexts() {
    if (isSearchActive) _execute(query);
  }

  void updateQuery(String? newQuery) {
    query = newQuery?.trim() ?? '';
    isSearchActive = query.isNotEmpty;
    if (isSearchActive) {
      _execute(query);
      return;
    }
    matchingTracks = const [];
    matchingAlbums = const [];
    matchingArtists = const [];
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
    title: artist.name,
    subtitle: Localizer.get('SubtitleArtist'),
    meta:
        '${Localizer.format('AlbumCount', [artist.albumCount])} • ${Localizer.format('TrackCount', [artist.trackCount])}',
    coverPath: artist.picturePath,
    play: () {
      if (artist.tracks.isNotEmpty) _player.playQueue(artist.tracks);
    },
    open: () => _openArtist(artist),
  );

  BestMatch _albumMatch(Album album) => BestMatch(
    kind: BestMatchKind.album,
    title: album.title,
    subtitle: album.artist,
    meta: album.year != null
        ? '${album.year} • ${Localizer.format('TrackCount', [album.trackCount])}'
        : Localizer.format('TrackCount', [album.trackCount]),
    coverPath: album.coverArtPath,
    play: () {
      if (album.tracks.isNotEmpty) _player.playQueue(album.tracks);
    },
    open: () => _openAlbum(album),
  );

  BestMatch _trackMatch(Track track) {
    void play() => _player.playQueue([track], track);
    return BestMatch(
      kind: BestMatchKind.track,
      title: track.title,
      subtitle: '${track.artist} • ${track.album}',
      meta: '${track.formattedDuration} • ${track.format.tagSpec}',
      coverPath: track.coverArtPath,
      play: play,
      open: play,
    );
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}
