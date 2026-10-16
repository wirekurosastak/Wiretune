// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'app_section.dart';
import 'player_view_model.dart';

String formatTotal(Iterable<Track> tracks) =>
    Localizer.formatTotalDuration(tracks.fold(Duration.zero, (sum, t) => sum + t.duration));

/// What a list of tracks sorts by, in the order the sort buttons and the table's columns show them: the title, the
/// track's own fields, then the release year, the date added and the quality, as on the albums and the artists pages.
enum TrackSortField { title, artist, album, length, released, added, quality }

/// Whether [field] starts with its highest values (the newest release or date, the best quality) rather than A to Z or
/// the shortest first.
bool startsDescending(TrackSortField field) =>
    field == TrackSortField.released || field == TrackSortField.added || field == TrackSortField.quality;

/// The order of a list: the field it sorts by and the direction. Choosing the active field again flips the direction;
/// another field starts in its natural one, which [startsDescending] tells.
class SortOrder<F extends Enum> {
  SortOrder(this._field, {required this.startsDescending, bool? descending})
    : _descending = descending ?? startsDescending(_field);

  final bool Function(F field) startsDescending;
  F _field;
  bool _descending;

  F get field => _field;
  bool get descending => _descending;

  void select(F field) {
    if (field == _field) {
      _descending = !_descending;
    } else {
      _field = field;
      _descending = startsDescending(field);
    }
  }

  /// The label of [field]'s sort button: its [name], and while it is the active one the direction.
  String label(F field, String name) => field == _field ? '$name ${_descending ? '↓' : '↑'}' : name;
}

/// [tracks] ordered by [field]; tracks that tie keep their order in [tracks], and one without a release year or a date
/// ([addedAt], the date added to the library unless given) goes last in either direction.
List<Track> sortTracks(
  List<Track> tracks,
  TrackSortField field, {
  bool descending = false,
  DateTime? Function(Track track)? addedAt,
}) {
  final added = addedAt ?? (Track t) => t.addedAt;
  return sortedBy(
    tracks,
    switch (field) {
      TrackSortField.title => (a, b) => compareText(a.title, b.title),
      TrackSortField.artist => (a, b) => compareText(a.artist, b.artist),
      TrackSortField.album => (a, b) => compareText(a.album, b.album),
      TrackSortField.length => (a, b) => a.duration.compareTo(b.duration),
      TrackSortField.released => (a, b) => a.releaseYear!.compareTo(b.releaseYear!),
      TrackSortField.added => (a, b) => added(a)!.compareTo(added(b)!),
      TrackSortField.quality => (a, b) => compareFormatQuality(a.format, b.format),
    },
    descending: descending,
    missing: switch (field) {
      TrackSortField.released => (t) => t.releaseYear == null,
      TrackSortField.added => (t) => added(t) == null,
      _ => null,
    },
  );
}

/// When the newest of [tracks] was added (the epoch for none): how new an album or an artist is.
DateTime latestAdded(Iterable<Track> tracks) =>
    tracks.map((t) => t.addedAt).fold(DateTime.fromMillisecondsSinceEpoch(0), (a, b) => b.isAfter(a) ? b : a);

/// The weakest format of [tracks]: an album is as good as its weakest track (the tier on its tag says the same).
AudioFormat weakestFormat(Iterable<Track> tracks) =>
    tracks.map((t) => t.format).reduce((w, f) => compareFormatQuality(f, w) < 0 ? f : w);

/// The order of a page of tracks and the labels of its sort buttons, which the wide table's column headers share. As
/// on the albums page, the active field flips its direction and another one starts in its natural one
/// ([startsDescending]).
mixin TrackSorting on ChangeNotifier {
  /// The page's order; each page starts in its own.
  SortOrder<TrackSortField> get _order;

  TrackSortField get sortField => _order.field;
  bool get isSortDescending => _order.descending;

  /// When a track was added: to the library, or (on the favourites page) to the favourites.
  DateTime? addedAt(Track track) => track.addedAt;

  /// Puts the page's tracks in the order again.
  void _applySort();

  void setSortField(TrackSortField field) {
    _order.select(field);
    _applySort();
    notifyListeners();
  }

  /// The button of [field]: its name, and while it is the active one the direction.
  String sortLabel(TrackSortField field) => _order.label(field, switch (field) {
    TrackSortField.title => 'ABC',
    TrackSortField.artist => Localizer.get('SortArtist'),
    TrackSortField.album => Localizer.get('SortAlbum'),
    TrackSortField.length => Localizer.get('SortLength'),
    TrackSortField.released => Localizer.get('SortReleased'),
    TrackSortField.added => Localizer.get('SortAdded'),
    TrackSortField.quality => Localizer.get('SortQuality'),
  });

  /// [tracks] (in the library's order) in the page's order; the library's order of artist, album and track number
  /// stays among tracks that tie.
  List<Track> _sorted(List<Track> tracks) =>
      sortTracks(tracks, sortField, descending: isSortDescending, addedAt: addedAt);
}

/// The Tracks section: the whole library.
class TracksViewModel extends ChangeNotifier with TrackSorting {
  TracksViewModel(this._library, this._player) {
    _unsubscribe = _library.libraryChanged.listen((_) => refreshTracks());
    refreshTracks();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  late final void Function() _unsubscribe;

  @override
  final SortOrder<TrackSortField> _order = SortOrder(TrackSortField.title, startsDescending: startsDescending);

  List<Track> displayedTracks = const [];
  int get totalTracksCount => displayedTracks.length;
  bool get hasTracks => displayedTracks.isNotEmpty;
  String totalTracksDuration = '';

  void refreshTracks() {
    _applySort();
    totalTracksDuration = formatTotal(displayedTracks);
    notifyListeners();
  }

  @override
  void _applySort() => displayedTracks = _sorted(_library.tracks);

  void playAll() {
    if (displayedTracks.isNotEmpty) _player.playQueue(displayedTracks);
  }

  void shuffleAll() => _player.shuffleQueue(displayedTracks);

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}

/// What the albums page sorts by, in the order of its buttons: the title, the album's own field, then the shared ones.
enum AlbumSortField { title, artist, released, added, quality }

/// What the artists page sorts by, in the order of its buttons: the name, the artist's own field, then the date added.
enum ArtistSortField { name, albums, added }

/// What the playlists page sorts by, in the order of its buttons: the name, the playlist's own field, then when it was
/// made.
enum PlaylistSortField { name, tracks, added }

/// Whether any of [tracks] is tagged with [genre], in any capitalisation.
bool hasGenre(Iterable<Track> tracks, String genre) => tracks.any((t) => equalsIgnoreCase(t.genre, genre));

/// Orders formats from the weakest to the best: by tier, then by bit depth and sample rate (lossless) or bitrate and
/// sample rate (lossy).
int compareFormatQuality(AudioFormat a, AudioFormat b) {
  final byTier = a.tier.index.compareTo(b.tier.index);
  if (byTier != 0) return byTier;
  final byDepth = a.isLossless && b.isLossless
      ? a.bitsPerSample.compareTo(b.bitsPerSample)
      : a.bitrateKbps.compareTo(b.bitrateKbps);
  return byDepth != 0 ? byDepth : a.sampleRate.compareTo(b.sampleRate);
}

/// A detail page that remembers where "back" leads.
mixin DetailOrigin on ChangeNotifier {
  void Function(NavWaveDirection direction)? onNavWave;

  /// What happens when the detail page is closed (returning to the search, another detail page or a tab).
  void Function()? returnAction;
  String Function()? _backTextSource;

  String backButtonText(String fallbackKey) {
    final text = _backTextSource?.call();
    return text != null && text.isNotEmpty ? text : Localizer.get(fallbackKey);
  }

  void _setOrigin(String Function()? backTextSource, void Function()? onReturn) {
    returnAction = onReturn;
    _backTextSource = backTextSource;
  }

  /// Clears the origin and returns the action to run after the detail page was closed.
  void Function()? _takeOrigin() {
    final action = returnAction;
    returnAction = null;
    _backTextSource = null;
    return action;
  }
}

/// The Albums section: the album grid and one album's page.
class AlbumsViewModel extends ChangeNotifier with DetailOrigin {
  AlbumsViewModel(this._library, this._player) {
    _unsubscribe = _library.libraryChanged.listen((_) => refreshAlbums());
    refreshAlbums();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  late final void Function() _unsubscribe;

  List<Album> displayedAlbums = const [];
  Album? selectedAlbum;
  bool isAlbumDetailOpen = false;

  // A to Z for titles and artists; the newest years and additions, and the best quality, first.
  final SortOrder<AlbumSortField> _order = SortOrder(
    AlbumSortField.title,
    startsDescending: (field) =>
        field == AlbumSortField.released || field == AlbumSortField.added || field == AlbumSortField.quality,
  );

  AlbumSortField get sortField => _order.field;
  bool get isSortDescending => _order.descending;

  /// The library's genres, for the filter; empty when no track has one.
  List<String> genres = const [];

  /// The genre the list is narrowed to; null shows every album.
  String? genre;

  String get backText => backButtonText('NavAlbums');

  /// The button of [field]: its name, and while it is the active one the direction.
  String sortLabel(AlbumSortField field) => _order.label(field, switch (field) {
    AlbumSortField.title => 'ABC',
    AlbumSortField.artist => Localizer.get('SortArtist'),
    AlbumSortField.released => Localizer.get('SortReleased'),
    AlbumSortField.added => Localizer.get('SortAdded'),
    AlbumSortField.quality => Localizer.get('SortQuality'),
  });

  void refreshLocalizedTexts() => notifyListeners();

  void setSortField(AlbumSortField field) {
    _order.select(field);
    _applySort();
    notifyListeners();
  }

  /// Narrows the list to the albums with a track of [value]; null shows them all again.
  void setGenre(String? value) {
    genre = value;
    _applySort();
    notifyListeners();
  }

  void refreshAlbums() {
    genres = _library.genres;
    // A genre that is no longer in the library would leave an empty list behind.
    if (genre != null && !genres.any((g) => equalsIgnoreCase(g, genre))) genre = null;
    _applySort();
    final previous = selectedAlbum;
    if (previous != null) {
      final updated = _library.getAlbum(previous.id);
      if (updated == null) {
        closeAlbumDetail();
        return;
      }
      selectedAlbum = updated;
    }
    notifyListeners();
  }

  void _applySort() {
    final wanted = genre;
    displayedAlbums = inSortOrder([
      for (final album in _library.albums)
        if (wanted == null || hasGenre(album.tracks, wanted)) album,
    ]);
  }

  /// [source] in the order chosen on this page, which the car's list of albums follows too. Albums that tie go A to Z.
  List<Album> inSortOrder(Iterable<Album> source) {
    final albums = List.of(source);
    final added = {
      if (sortField == AlbumSortField.added)
        for (final a in albums) a: latestAdded(a.tracks),
    };
    final weakest = {
      if (sortField == AlbumSortField.quality)
        for (final a in albums) a: weakestFormat(a.tracks),
    };
    return sortedBy(
      albums,
      switch (sortField) {
        AlbumSortField.title => (a, b) => compareText(a.title, b.title),
        AlbumSortField.artist => (a, b) => compareText(a.artist, b.artist),
        AlbumSortField.released => (a, b) => a.releaseYear!.compareTo(b.releaseYear!),
        AlbumSortField.added => (a, b) => added[a]!.compareTo(added[b]!),
        AlbumSortField.quality => (a, b) => compareFormatQuality(weakest[a]!, weakest[b]!),
      },
      descending: isSortDescending,
      missing: sortField == AlbumSortField.released ? (a) => a.releaseYear == null : null,
      thenBy: sortField == AlbumSortField.title ? null : (a, b) => compareText(a.title, b.title),
    );
  }

  void openAlbum(Album? album) => openAlbumWithOrigin(album, null, null, NavWaveDirection.leftToRight);

  /// [backTextSource] produces the back button's label; it is asked again whenever the language changes.
  void openAlbumWithOrigin(
    Album? album,
    String Function()? backTextSource,
    void Function()? onReturn, [
    NavWaveDirection? waveDirection = NavWaveDirection.leftToRight,
  ]) {
    if (album == null) return;
    _setOrigin(backTextSource, onReturn);
    selectedAlbum = album;
    isAlbumDetailOpen = true;
    if (waveDirection != null) onNavWave?.call(waveDirection);
    notifyListeners();
  }

  void closeAlbumDetail() {
    final returnAction = _takeOrigin();
    if (isAlbumDetailOpen) onNavWave?.call(NavWaveDirection.rightToLeft);
    isAlbumDetailOpen = false;
    selectedAlbum = null;
    notifyListeners();
    returnAction?.call();
  }

  void playAlbum([Album? album]) {
    final target = album ?? selectedAlbum;
    if (target == null || target.tracks.isEmpty) return;
    _player.playQueue(target.tracks);
  }

  void shuffleAlbum() => _player.shuffleQueue(selectedAlbum?.tracks ?? const []);

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}

/// The Artists section: the artist grid and one artist's page.
class ArtistsViewModel extends ChangeNotifier with DetailOrigin {
  /// [pictures] looks the artists' pictures up online; without it they show an album cover.
  ArtistsViewModel(this._library, this._player, [this._pictures]) {
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) => refreshArtists()),
      ?_pictures?.pictureResolved.listen((_) => notifyListeners()),
    ]);
    refreshArtists();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  final ArtistPictureService? _pictures;
  final List<void Function()> _unsubscribers = [];

  List<Artist> displayedArtists = const [];
  Artist? selectedArtist;
  bool isArtistDetailOpen = false;

  // A to Z for the name; the most albums and the newest first.
  final SortOrder<ArtistSortField> _order = SortOrder(
    ArtistSortField.name,
    startsDescending: (field) => field != ArtistSortField.name,
  );

  ArtistSortField get sortField => _order.field;
  bool get isSortDescending => _order.descending;

  /// The library's genres, for the filter; empty when no track has one.
  List<String> genres = const [];

  /// The genre the list is narrowed to; null shows every artist.
  String? genre;

  String get backText => backButtonText('NavArtists');

  /// The button of [field]: its name, and while it is the active one the direction.
  String sortLabel(ArtistSortField field) => _order.label(field, switch (field) {
    ArtistSortField.name => 'ABC',
    ArtistSortField.albums => Localizer.get('SortAlbums'),
    ArtistSortField.added => Localizer.get('SortAdded'),
  });

  void refreshLocalizedTexts() => notifyListeners();

  void setSortField(ArtistSortField field) {
    _order.select(field);
    _applySort();
    notifyListeners();
  }

  /// Narrows the list to the artists with a track of [value]; null shows them all again.
  void setGenre(String? value) {
    genre = value;
    _applySort();
    notifyListeners();
  }

  void _applySort() {
    final wanted = genre;
    displayedArtists = inSortOrder([
      for (final artist in _library.artists)
        if (wanted == null || hasGenre(artist.tracks, wanted)) artist,
    ]);
  }

  /// [source] in the order chosen on this page, which the car's list of artists follows too. Artists that tie go A to Z.
  List<Artist> inSortOrder(Iterable<Artist> source) {
    final artists = List.of(source);
    final added = {
      if (sortField == ArtistSortField.added)
        for (final a in artists) a: latestAdded(a.tracks),
    };
    return sortedBy(
      artists,
      switch (sortField) {
        ArtistSortField.name => (a, b) => compareText(a.name, b.name),
        ArtistSortField.albums => (a, b) => a.albumCount.compareTo(b.albumCount),
        ArtistSortField.added => (a, b) => added[a]!.compareTo(added[b]!),
      },
      descending: isSortDescending,
      thenBy: sortField == ArtistSortField.name ? null : (a, b) => compareText(a.name, b.name),
    );
  }

  void refreshArtists() {
    genres = _library.genres;
    // A genre that is no longer in the library would leave an empty list behind.
    if (genre != null && !genres.any((g) => equalsIgnoreCase(g, genre))) genre = null;
    _applySort();
    _pictures?.resolveArtistPictures(_library.artists);
    final previous = selectedArtist;
    if (previous != null) {
      final updated = _library.getArtist(previous.id);
      if (updated == null) {
        closeArtistDetail();
        return;
      }
      _showArtist(updated, null); // keep where "back" leads to
    }
    notifyListeners();
  }

  void openArtist(Artist? artist) => openArtistWithOrigin(artist, null, null, NavWaveDirection.leftToRight);

  void openArtistWithOrigin(
    Artist? artist,
    String Function()? backTextSource,
    void Function()? onReturn, [
    NavWaveDirection? waveDirection = NavWaveDirection.leftToRight,
  ]) {
    if (artist == null) return;
    _setOrigin(backTextSource, onReturn);
    _showArtist(artist, waveDirection);
    notifyListeners();
  }

  void _showArtist(Artist artist, NavWaveDirection? waveDirection) {
    selectedArtist = artist;
    _pictures?.resolveArtistPicture(artist);
    isArtistDetailOpen = true;
    if (waveDirection != null) onNavWave?.call(waveDirection);
  }

  void closeArtistDetail() {
    final returnAction = _takeOrigin();
    if (isArtistDetailOpen) onNavWave?.call(NavWaveDirection.rightToLeft);
    isArtistDetailOpen = false;
    selectedArtist = null;
    notifyListeners();
    returnAction?.call();
  }

  void playArtist([Artist? artist]) {
    final target = artist ?? selectedArtist;
    if (target == null || target.tracks.isEmpty) return;
    _player.playQueue(target.tracks);
  }

  void shuffleArtist() => _player.shuffleQueue(selectedArtist?.tracks ?? const []);

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}

/// The Favorites section; the newest favourites first unless the user sorts otherwise.
class FavoritesViewModel extends ChangeNotifier with TrackSorting {
  FavoritesViewModel(this._library, this._player) {
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) => refreshFavorites()),
      _library.favoriteChanged.listen((_) => refreshFavorites()),
    ]);
    refreshFavorites();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  final List<void Function()> _unsubscribers = [];

  @override
  final SortOrder<TrackSortField> _order = SortOrder(TrackSortField.added, startsDescending: startsDescending);

  List<Track> favoriteTracks = const [];
  String totalFavoritesDuration = '';
  bool get isEmpty => favoriteTracks.isEmpty;

  void refreshLocalizedTexts() => refreshFavorites();

  void refreshFavorites() {
    _applySort();
    totalFavoritesDuration = formatTotal(favoriteTracks);
    notifyListeners();
  }

  /// When the track became a favourite.
  @override
  DateTime? addedAt(Track track) => _library.favoritedAt(track.id);

  @override
  void _applySort() => favoriteTracks = _sorted(_library.favorites);

  void playAll() {
    if (favoriteTracks.isNotEmpty) _player.playQueue(favoriteTracks);
  }

  void shuffleAll() => _player.shuffleQueue(favoriteTracks);

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}

/// The covers a playlist's tile shows: up to four distinct album covers of its tracks (repeated to fill a 2x2 grid).
List<String> playlistCovers(List<Track> tracks) {
  final seenAlbums = <String>{};
  final covers = <String>[];
  for (final t in tracks) {
    final cover = t.coverArtPath;
    if (cover == null || cover.trim().isEmpty) continue;
    final key = t.album.trim().isEmpty ? cover : '${t.album}||${t.effectiveAlbumArtist}';
    if (!seenAlbums.add(key) || covers.contains(cover)) continue;
    covers.add(cover);
    if (covers.length == 4) break;
  }
  return switch (covers.length) {
    0 => const [],
    1 => [covers[0], covers[0], covers[0], covers[0]],
    2 => [covers[0], covers[1], covers[1], covers[0]],
    3 => [covers[0], covers[1], covers[2], covers[0]],
    _ => covers,
  };
}

/// The Playlists section, its dialogs (new playlist, add to playlist, delete) and one playlist's page. The list of
/// playlists starts with the newest; a playlist's tracks in the order they were added to it (Added ↑), the only date a
/// playlist knows of them being their place in it.
class PlaylistsViewModel extends ChangeNotifier with TrackSorting {
  PlaylistsViewModel(this._library, this._player) {
    _unsubscribers.addAll([
      _library.playlistsChanged.listen((_) => refreshPlaylists()),
      _library.libraryChanged.listen((_) => refreshPlaylists()),
    ]);
    refreshPlaylists();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  final List<void Function()> _unsubscribers = [];

  void Function(NavWaveDirection direction)? onNavWave;

  /// A playlist's own order is the one its tracks were added in: Added ↑.
  @override
  final SortOrder<TrackSortField> _order = SortOrder(
    TrackSortField.added,
    startsDescending: startsDescending,
    descending: false,
  );

  // The playlists themselves: A to Z for the name, the most tracks and the newest first.
  final SortOrder<PlaylistSortField> _listOrder = SortOrder(
    PlaylistSortField.added,
    startsDescending: (field) => field != PlaylistSortField.name,
  );

  List<Playlist> playlists = const [];

  /// The most played and the recently played tracks, as read-only playlists above the user's own; each only once
  /// something was played.
  List<Playlist> automaticPlaylists = const [];
  Map<String, List<Track>> _tracksOf = const {};
  Playlist? selectedPlaylist;

  /// The open playlist's tracks in the order chosen on its page.
  List<Track> selectedPlaylistTracks = const [];
  Map<String, int> _positions = const {};
  String selectedPlaylistTotalDuration = '';
  bool isPlaylistDetailOpen = false;

  // Inline renaming.
  bool isEditingName = false;
  String editingPlaylistName = '';

  bool get hasPlaylists => playlists.isNotEmpty || automaticPlaylists.isNotEmpty;

  /// The tracks of [playlist] as the library resolves them (cached per refresh).
  List<Track> tracksOf(Playlist playlist) => _tracksOf[playlist.id] ?? _library.getPlaylistTracks(playlist);

  PlaylistSortField get listSortField => _listOrder.field;
  bool get isListSortDescending => _listOrder.descending;

  /// The button of [field] on the playlists page: its name, and while it is the active one the direction.
  String listSortLabel(PlaylistSortField field) => _listOrder.label(field, switch (field) {
    PlaylistSortField.name => 'ABC',
    PlaylistSortField.tracks => Localizer.get('SortTracks'),
    PlaylistSortField.added => Localizer.get('SortAdded'),
  });

  void setListSortField(PlaylistSortField field) {
    _listOrder.select(field);
    playlists = _inSortOrder(_library.playlists);
    notifyListeners();
  }

  /// [source] in the order chosen on the playlists page (which the car's list of playlists shows too).
  List<Playlist> _inSortOrder(Iterable<Playlist> source) => sortedBy(
    source,
    switch (listSortField) {
      PlaylistSortField.name => (a, b) => compareText(a.name, b.name),
      PlaylistSortField.tracks => (a, b) => a.trackCount.compareTo(b.trackCount),
      PlaylistSortField.added => (a, b) => a.createdAt.compareTo(b.createdAt),
    },
    descending: isListSortDescending,
    thenBy: (a, b) => compareText(a.name, b.name),
  );

  /// Where [track] stands in the open playlist (1 for the first added); null when it isn't in it.
  int? positionOf(Track track) => _positions[track.id];

  static const int _automaticLength = 50;
  static const String _mostPlayedId = 'automatic:most-played';
  static const String _recentlyPlayedId = 'automatic:recently-played';

  /// The automatic playlists as the play counts stand now: the [_automaticLength] most played tracks (the more recent
  /// first among equals), and the last played ones.
  List<Playlist> _automatic() {
    final library = _library;
    final played = library.tracks.where((t) => library.playCount(t.id) > 0 || library.lastPlayedAt(t.id) != null);
    if (played.isEmpty) return const [];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    int recent(Track a, Track b) =>
        (library.lastPlayedAt(b.id) ?? epoch).compareTo(library.lastPlayedAt(a.id) ?? epoch);
    final most = played.where((t) => library.playCount(t.id) > 0).toList()
      ..sort((a, b) {
        final count = library.playCount(b.id).compareTo(library.playCount(a.id));
        return count != 0 ? count : recent(a, b);
      });
    final last = played.where((t) => library.lastPlayedAt(t.id) != null).toList()..sort(recent);
    Playlist list(String id, String key, List<Track> tracks) => Playlist(
      id: id,
      name: Localizer.get(key),
      isAutomatic: true,
      trackIds: [for (final t in tracks.take(_automaticLength)) t.id],
    );
    return [
      if (most.isNotEmpty) list(_mostPlayedId, 'AutoMostPlayed', most),
      if (last.isNotEmpty) list(_recentlyPlayedId, 'AutoRecentlyPlayed', last),
    ];
  }

  void refreshPlaylists() {
    final selectedId = selectedPlaylist?.id;
    playlists = _inSortOrder(_library.playlists);
    automaticPlaylists = _automatic();
    _tracksOf = {
      for (final pl in [...automaticPlaylists, ...playlists]) pl.id: _library.getPlaylistTracks(pl),
    };
    selectedPlaylist = selectedId == null
        ? null
        : (_library.getPlaylist(selectedId) ?? automaticPlaylists.where((pl) => pl.id == selectedId).firstOrNull);
    if (selectedPlaylist == null) isPlaylistDetailOpen = false;
    _refreshSelectedTracks();
    notifyListeners();
  }

  /// The automatic playlists' names are in the language.
  void refreshLocalizedTexts() => refreshPlaylists();

  void _refreshSelectedTracks() {
    _applySort();
    selectedPlaylistTotalDuration = selectedPlaylistTracks.isEmpty ? '' : formatTotal(selectedPlaylistTracks);
  }

  /// Added is the playlist's own order: the tracks were added in it, and it can't be rearranged.
  @override
  void _applySort() {
    final selected = selectedPlaylist;
    final tracks = selected == null ? const <Track>[] : _library.getPlaylistTracks(selected);
    _positions = {for (var i = tracks.length - 1; i >= 0; i--) tracks[i].id: i + 1};
    selectedPlaylistTracks = sortField != TrackSortField.added
        ? _sorted(tracks)
        : (isSortDescending ? tracks.reversed.toList() : tracks);
  }

  void _select(Playlist? playlist) {
    selectedPlaylist = playlist;
    isEditingName = false;
    _refreshSelectedTracks();
  }

  void openPlaylist(Playlist? playlist) {
    if (playlist == null) return;
    _select(playlist);
    isPlaylistDetailOpen = true;
    onNavWave?.call(NavWaveDirection.leftToRight);
    notifyListeners();
  }

  void closePlaylistDetail() {
    if (isPlaylistDetailOpen) onNavWave?.call(NavWaveDirection.rightToLeft);
    isPlaylistDetailOpen = false;
    _select(null);
    notifyListeners();
  }

  /// Makes a playlist called [name] (nothing for a blank one) with [tracks] in it, and opens it.
  void createPlaylist(String name, [List<Track> tracks = const []]) {
    if (name.trim().isEmpty) return;
    final playlist = _library.createPlaylist(name);
    if (tracks.isNotEmpty) _library.addTracksToPlaylist(playlist.id, [for (final t in tracks) t.id]);
    refreshPlaylists();
    _select(_library.getPlaylist(playlist.id));
    isPlaylistDetailOpen = true;
    notifyListeners();
  }

  /// Puts [tracks] at the end of [playlist], those not in it yet.
  void addTracks(Playlist playlist, List<Track> tracks) =>
      _library.addTracksToPlaylist(playlist.id, [for (final t in tracks) t.id]);

  void deletePlaylist(Playlist? playlist) {
    if (playlist == null) return;
    _library.deletePlaylist(playlist.id);
    if (selectedPlaylist?.id == playlist.id) {
      _select(null);
      isPlaylistDetailOpen = false;
    }
    refreshPlaylists();
  }

  void startRename() {
    final selected = selectedPlaylist;
    if (selected == null || selected.isAutomatic) return;
    editingPlaylistName = selected.name;
    isEditingName = true;
    notifyListeners();
  }

  Future<void> confirmRenamePlaylist([String? name]) async {
    if (name != null) editingPlaylistName = name;
    final selected = selectedPlaylist;
    if (selected == null || editingPlaylistName.trim().isEmpty) {
      isEditingName = false;
      notifyListeners();
      return;
    }
    final newName = editingPlaylistName.trim();
    if (newName != selected.name) {
      _library.renamePlaylist(selected.id, newName);
      selectedPlaylist = _library.getPlaylist(selected.id);
      refreshPlaylists();
    }
    isEditingName = false;
    notifyListeners();
  }

  void cancelRename() {
    isEditingName = false;
    notifyListeners();
  }

  /// Plays [playlist] in its own order, or the open one in the order shown.
  void playPlaylist([Playlist? playlist]) {
    final tracks = playlist == null ? selectedPlaylistTracks : _library.getPlaylistTracks(playlist);
    if (tracks.isNotEmpty) _player.playQueue(tracks);
  }

  void shufflePlaylist() => _player.shuffleQueue(selectedPlaylistTracks);

  Future<void> removeTrackFromSelected(Track? track) async {
    final selected = selectedPlaylist;
    if (track == null || selected == null) return;
    _library.removeTrackFromPlaylist(selected.id, track.id);
    refreshPlaylists();
  }

  /// Whether the open playlist shows its own order (Added ↑), the only one its tracks can be moved in.
  bool get canReorder =>
      selectedPlaylist?.isAutomatic == false && sortField == TrackSortField.added && !isSortDescending;

  /// Moves the open playlist's track shown at [from] to [to] (counted after it has been taken out).
  Future<void> moveTrack(int from, int to) async {
    final selected = selectedPlaylist;
    if (selected == null || !canReorder) return;
    _library.movePlaylistTrack(selected.id, from, to);
    refreshPlaylists();
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}
