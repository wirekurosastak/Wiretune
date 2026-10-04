import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'app_section.dart';
import 'player_view_model.dart';

String formatTotal(Iterable<Track> tracks) =>
    Localizer.formatTotalDuration(tracks.fold(Duration.zero, (sum, t) => sum + t.duration));

/// The Tracks section: the whole library.
class TracksViewModel extends ChangeNotifier {
  TracksViewModel(this._library, this._player) {
    _unsubscribe = _library.libraryChanged.listen((_) => refreshTracks());
    refreshTracks();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  late final void Function() _unsubscribe;

  List<Track> displayedTracks = const [];
  int get totalTracksCount => displayedTracks.length;
  bool get hasTracks => displayedTracks.isNotEmpty;
  String totalTracksDuration = '';

  void refreshTracks() {
    displayedTracks = _library.tracks;
    totalTracksDuration = formatTotal(displayedTracks);
    notifyListeners();
  }

  void playTrack(Track? track) {
    if (track != null) _player.playQueue(displayedTracks, track);
  }

  void playAll() {
    if (displayedTracks.isNotEmpty) _player.playQueue(displayedTracks);
  }

  void shuffleAll() {
    if (displayedTracks.isEmpty) return;
    _player.setShuffle(true);
    _player.playQueue(displayedTracks);
  }

  Future<void> toggleFavorite(Track? track) async {
    if (track != null) await _library.toggleFavorite(track.id);
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}

enum AlbumSortField { title, year, quality }

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
  AlbumSortField sortField = AlbumSortField.title;
  bool isSortDescending = false;

  /// The library's genres, for the filter; empty when no track has one.
  List<String> genres = const [];

  /// The genre the list is narrowed to; null shows every album.
  String? genre;

  bool get isSortByTitle => sortField == AlbumSortField.title;
  bool get isSortByYear => sortField == AlbumSortField.year;
  bool get isSortByQuality => sortField == AlbumSortField.quality;

  String get backText => backButtonText('BackToAlbums');

  String get sortTitleLabel => isSortByTitle ? 'ABC ${isSortDescending ? '↓' : '↑'}' : 'ABC';
  String get sortYearLabel =>
      isSortByYear ? '${Localizer.get('SortYear')} ${isSortDescending ? '↓' : '↑'}' : Localizer.get('SortYear');
  String get sortQualityLabel => isSortByQuality
      ? '${Localizer.get('SortQuality')} ${isSortDescending ? '↓' : '↑'}'
      : Localizer.get('SortQuality');

  void refreshLocalizedTexts() => notifyListeners();

  /// The active field flips its direction; another one is switched to with its natural default (A→Z for titles,
  /// newest first for years, best first for quality).
  void setSortField(AlbumSortField field) {
    if (field == sortField) {
      isSortDescending = !isSortDescending;
    } else {
      isSortDescending = field != AlbumSortField.title;
      sortField = field;
    }
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
    final albums = [
      for (final album in _library.albums)
        if (wanted == null || hasGenre(album.tracks, wanted)) album,
    ];
    switch (sortField) {
      case AlbumSortField.year:
        // Albums without a year always go last, in either direction.
        sortStable(albums, (a, b) {
          if ((a.year == null) != (b.year == null)) return a.year == null ? 1 : -1;
          final byYear = isSortDescending ? (b.year ?? 0).compareTo(a.year ?? 0) : (a.year ?? 0).compareTo(b.year ?? 0);
          return byYear != 0 ? byYear : compareText(a.title, b.title);
        });
      case AlbumSortField.quality:
        // An album is as good as its weakest track (the tier on its tag says the same); one without tracks ranks last.
        final weakest = <Album, AudioFormat?>{
          for (final album in albums)
            album: album.tracks.isEmpty
                ? null
                : album.tracks.map((t) => t.format).reduce((w, f) => compareFormatQuality(f, w) < 0 ? f : w),
        };
        int compare(Album a, Album b) {
          final (fa, fb) = (weakest[a], weakest[b]);
          if (fa == null || fb == null) return (fa == null ? 0 : 1) - (fb == null ? 0 : 1);
          return compareFormatQuality(fa, fb);
        }

        sortStable(albums, (a, b) {
          final byQuality = compare(a, b);
          return byQuality != 0 ? (isSortDescending ? -byQuality : byQuality) : compareText(a.title, b.title);
        });
      case AlbumSortField.title:
        sortStable(albums, (a, b) => isSortDescending ? compareText(b.title, a.title) : compareText(a.title, b.title));
    }
    displayedAlbums = albums;
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

  void playAlbumTrack(Track? track) {
    if (track != null && selectedAlbum != null) _player.playQueue(selectedAlbum!.tracks, track);
  }

  void shuffleAlbum([Album? album]) {
    final target = album ?? selectedAlbum;
    if (target == null || target.tracks.isEmpty) return;
    _player.setShuffle(true);
    _player.playQueue(target.tracks);
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}

/// The Artists section: the artist grid and one artist's page.
class ArtistsViewModel extends ChangeNotifier with DetailOrigin {
  ArtistsViewModel(this._library, this._player, {ArtistPictureService? pictures})
    : _pictures = pictures ?? ArtistPictureService.instance {
    _unsubscribers.addAll([
      _library.libraryChanged.listen((_) => refreshArtists()),
      _pictures.pictureResolved.listen((_) => notifyListeners()),
    ]);
    refreshArtists();
  }

  final LibraryService _library;
  final PlayerViewModel _player;
  final ArtistPictureService _pictures;
  final List<void Function()> _unsubscribers = [];

  List<Artist> displayedArtists = const [];
  Artist? selectedArtist;
  bool isArtistDetailOpen = false;
  List<Album> selectedArtistAlbums = const [];
  List<Track> selectedArtistTracks = const [];
  bool isSortDescending = false;

  /// The library's genres, for the filter; empty when no track has one.
  List<String> genres = const [];

  /// The genre the list is narrowed to; null shows every artist.
  String? genre;

  bool get hasSelectedArtistAlbums => selectedArtistAlbums.isNotEmpty;

  String get backText => backButtonText('BackToArtists');

  /// Artists are sorted by name only; the arrow shows the direction.
  String get sortNameLabel => 'ABC ${isSortDescending ? '↓' : '↑'}';

  void refreshLocalizedTexts() => notifyListeners();

  void toggleSort() {
    isSortDescending = !isSortDescending;
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
    final artists = [
      for (final artist in _library.artists)
        if (wanted == null || hasGenre(artist.tracks, wanted)) artist,
    ];
    sortStable(artists, (a, b) => isSortDescending ? compareText(b.name, a.name) : compareText(a.name, b.name));
    displayedArtists = artists;
  }

  void refreshArtists() {
    genres = _library.genres;
    // A genre that is no longer in the library would leave an empty list behind.
    if (genre != null && !genres.any((g) => equalsIgnoreCase(g, genre))) genre = null;
    _applySort();
    _pictures.resolveArtistPictures(_library.artists);
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
    _pictures.resolveArtistPicture(artist);
    isArtistDetailOpen = true;
    if (waveDirection != null) onNavWave?.call(waveDirection);
    final albums = List<Album>.of(artist.albums);
    sortStable(albums, (a, b) {
      final byYear = (b.year ?? -0x80000000).compareTo(a.year ?? -0x80000000);
      return byYear != 0 ? byYear : compareText(a.title, b.title);
    });
    selectedArtistAlbums = albums;
    selectedArtistTracks = artist.tracks;
  }

  void closeArtistDetail() {
    final returnAction = _takeOrigin();
    if (isArtistDetailOpen) onNavWave?.call(NavWaveDirection.rightToLeft);
    isArtistDetailOpen = false;
    selectedArtist = null;
    selectedArtistAlbums = const [];
    selectedArtistTracks = const [];
    notifyListeners();
    returnAction?.call();
  }

  void playArtist([Artist? artist]) {
    final target = artist ?? selectedArtist;
    if (target == null || target.tracks.isEmpty) return;
    _player.playQueue(target.tracks);
  }

  void shuffleArtist([Artist? artist]) {
    final target = artist ?? selectedArtist;
    if (target == null || target.tracks.isEmpty) return;
    _player.setShuffle(true);
    _player.playQueue(target.tracks);
  }

  void playArtistTrack(Track? track) {
    if (track != null && selectedArtist != null) _player.playQueue(selectedArtist!.tracks, track);
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}

/// The Favorites section.
class FavoritesViewModel extends ChangeNotifier {
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

  List<Track> favoriteTracks = const [];
  String totalFavoritesDuration = '';
  bool get isEmpty => favoriteTracks.isEmpty;

  void refreshLocalizedTexts() => refreshFavorites();

  void refreshFavorites() {
    favoriteTracks = _library.favorites;
    totalFavoritesDuration = formatTotal(favoriteTracks);
    notifyListeners();
  }

  void playTrack(Track? track) {
    if (track != null) _player.playQueue(favoriteTracks, track);
  }

  void playAll() {
    if (favoriteTracks.isNotEmpty) _player.playQueue(favoriteTracks);
  }

  void shuffleAll() {
    if (favoriteTracks.isEmpty) return;
    _player.setShuffle(true);
    _player.playQueue(favoriteTracks);
  }

  Future<void> removeFavorite(Track? track) async {
    if (track == null) return;
    await _library.toggleFavorite(track.id);
    refreshFavorites();
  }

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

/// The Playlists section, its dialogs (new playlist, add to playlist, delete) and one playlist's page.
class PlaylistsViewModel extends ChangeNotifier {
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

  List<Playlist> playlists = const [];
  Map<String, List<Track>> _tracksOf = const {};
  Playlist? selectedPlaylist;
  List<Track> selectedPlaylistTracks = const [];
  String selectedPlaylistTotalDuration = '';
  bool isPlaylistDetailOpen = false;

  // "New playlist" dialog, optionally adding a pending track once created.
  bool isCreateDialogOpen = false;
  String newPlaylistName = '';

  // "Add to playlist" dialog.
  bool isAddToPlaylistDialogOpen = false;
  Track? trackToAdd;

  // Delete confirmation.
  Playlist? playlistPendingDelete;

  // Inline renaming.
  bool isEditingName = false;
  String editingPlaylistName = '';

  bool get hasPlaylists => playlists.isNotEmpty;
  bool get isSelectedPlaylistEmpty => selectedPlaylist != null && selectedPlaylistTracks.isEmpty;
  bool get isDeleteConfirmOpen => playlistPendingDelete != null;
  bool get isAnyDialogOpen => isCreateDialogOpen || isAddToPlaylistDialogOpen || isDeleteConfirmOpen;

  /// The tracks of [playlist] as the library resolves them (cached per refresh).
  List<Track> tracksOf(Playlist playlist) => _tracksOf[playlist.id] ?? _library.getPlaylistTracks(playlist);

  void refreshPlaylists() {
    final selectedId = selectedPlaylist?.id;
    playlists = _library.playlists;
    _tracksOf = {for (final pl in playlists) pl.id: _library.getPlaylistTracks(pl)};
    for (final pl in playlists) {
      pl.applyQuality(_tracksOf[pl.id]!);
    }
    selectedPlaylist = selectedId == null ? null : _library.getPlaylist(selectedId);
    if (selectedPlaylist == null) isPlaylistDetailOpen = false;
    _refreshSelectedTracks();
    notifyListeners();
  }

  void refreshLocalizedTexts() {
    _refreshSelectedTracks();
    notifyListeners();
  }

  void _refreshSelectedTracks() {
    final selected = selectedPlaylist;
    selectedPlaylistTracks = selected == null ? const [] : _library.getPlaylistTracks(selected);
    selectedPlaylistTotalDuration = selectedPlaylistTracks.isEmpty ? '' : formatTotal(selectedPlaylistTracks);
    selected?.applyQuality(selectedPlaylistTracks);
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

  void openCreateDialog() {
    newPlaylistName = '';
    isAddToPlaylistDialogOpen = false;
    isCreateDialogOpen = true;
    notifyListeners();
  }

  void closeCreateDialog() {
    isCreateDialogOpen = false;
    trackToAdd = null;
    notifyListeners();
  }

  Future<void> createPlaylist([String? name]) async {
    if (name != null) newPlaylistName = name;
    if (newPlaylistName.trim().isEmpty) return;

    final playlist = await _library.createPlaylist(newPlaylistName);
    final pending = trackToAdd;
    if (pending != null) await _library.addTrackToPlaylist(playlist.id, pending.id);

    isCreateDialogOpen = false;
    trackToAdd = null;
    refreshPlaylists();
    _select(_library.getPlaylist(playlist.id));
    isPlaylistDetailOpen = true;
    notifyListeners();
  }

  void requestDeletePlaylist(Playlist? playlist) {
    playlistPendingDelete = playlist;
    notifyListeners();
  }

  void cancelDeletePlaylist() {
    playlistPendingDelete = null;
    notifyListeners();
  }

  Future<void> confirmDeletePlaylist() async {
    final playlist = playlistPendingDelete;
    playlistPendingDelete = null;
    if (playlist != null) await deletePlaylist(playlist);
    notifyListeners();
  }

  Future<void> deletePlaylist(Playlist? playlist) async {
    if (playlist == null) return;
    await _library.deletePlaylist(playlist.id);
    if (selectedPlaylist?.id == playlist.id) {
      _select(null);
      isPlaylistDetailOpen = false;
    }
    refreshPlaylists();
  }

  void startRename() {
    final selected = selectedPlaylist;
    if (selected == null) return;
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
      await _library.renamePlaylist(selected.id, newName);
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

  void playPlaylist([Playlist? playlist]) {
    final target = playlist ?? selectedPlaylist;
    if (target == null) return;
    final tracks = _library.getPlaylistTracks(target);
    if (tracks.isNotEmpty) _player.playQueue(tracks);
  }

  void shufflePlaylist([Playlist? playlist]) {
    final target = playlist ?? selectedPlaylist;
    if (target == null) return;
    final tracks = _library.getPlaylistTracks(target);
    if (tracks.isEmpty) return;
    _player.setShuffle(true);
    _player.playQueue(tracks);
  }

  void playTrack(Track? track) {
    if (track != null) _player.playQueue(selectedPlaylistTracks, track);
  }

  Future<void> removeTrackFromSelected(Track? track) async {
    final selected = selectedPlaylist;
    if (track == null || selected == null) return;
    await _library.removeTrackFromPlaylist(selected.id, track.id);
    refreshPlaylists();
  }

  void beginAddTrack(Track track) {
    trackToAdd = track;
    isAddToPlaylistDialogOpen = true;
    notifyListeners();
  }

  void cancelAddTrack() {
    isAddToPlaylistDialogOpen = false;
    trackToAdd = null;
    notifyListeners();
  }

  Future<void> addPendingTrackTo(Playlist? playlist) async {
    final track = trackToAdd;
    if (playlist != null && track != null) await _library.addTrackToPlaylist(playlist.id, track.id);
    cancelAddTrack();
  }

  void createPlaylistForPendingTrack() {
    newPlaylistName = trackToAdd?.album ?? '';
    isAddToPlaylistDialogOpen = false;
    isCreateDialogOpen = true;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    super.dispose();
  }
}
