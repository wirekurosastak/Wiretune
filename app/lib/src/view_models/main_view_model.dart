// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'app_section.dart';
import 'downloads_view_model.dart';
import 'library_view_models.dart';
import 'lyrics_view_model.dart';
import 'player_view_model.dart';
import 'search_view_model.dart';
import 'settings_view_models.dart';

/// What the device the app runs on can do; decided once at start-up.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.supportsLocalFolder = false,
    this.requestFolderAccess,
    this.kind = DeviceKind.desktop,
    this.name = '',
  });

  /// Scanning a folder of the device's own (desktop, Android phones).
  final bool supportsLocalFolder;

  /// Asks for the permission to read that folder (Android), true when given; null when there is nothing to ask.
  final Future<bool> Function()? requestFolderAccess;

  /// What the other players of the account see this one as, and the name it has until the user gives it another.
  final DeviceKind kind;
  final String name;
}

/// A short message that needs no answer: a change that wasn't made, one the server turned down, something that went
/// through. The app shows the latest for a few seconds.
class AppNotice {
  const AppNotice(this.message, {this.isError = false, this.undo});

  final String message;
  final bool isError;

  /// Takes back what the notice tells of: its Undo button is there when this is.
  final VoidCallback? undo;
}

/// An artist, album or track the user hid, and the name the settings list it by.
class HiddenItem {
  const HiddenItem(this.kind, this.id, this.label);

  final HiddenKind kind;
  final String id;
  final String label;
}

/// The whole app's state: the services, one view model per area, the navigation and the status lines. The wide and
/// the phone layout are two views of this one model.
class MainViewModel extends ChangeNotifier {
  MainViewModel(
    this.audioEngine,
    this.library,
    this.session, {
    OnlineLyrics? onlineLyrics,
    ArtistPictureService? artistPictures,
    this.capabilities = const DeviceCapabilities(),
    DownloadService? downloadService,
    RemoteClient? remote,
  }) : _onlineLyrics = onlineLyrics,
       _artistPictures = artistPictures,
       downloadService = downloadService ?? DownloadService(library, session),
       remote = remote ?? RemoteClient(session) {
    // Stream URLs carry a short-lived, media-only token that the session renews, not the sign-in token; a server track
    // that was downloaded plays from its copy.
    audioEngine
      ..setStreamTokenProvider(session.getStreamToken)
      ..setOfflineCopyProvider(this.downloadService.localCopy);
    // Downloads may land in the local folder (Music/Wiretune); they are server tracks, not local music.
    library.downloadFolder = this.downloadService.directory;

    player = PlayerViewModel(audioEngine, library)..attachRemote(this.remote);
    lyrics = LyricsViewModel(player, own: _ownLyrics, online: onlineLyrics?.find);

    tracks = TracksViewModel(library, player);
    albums = AlbumsViewModel(library, player)..onNavWave = triggerNavWave;
    artists = ArtistsViewModel(library, player, artistPictures)..onNavWave = triggerNavWave;
    playlists = PlaylistsViewModel(library, player)..onNavWave = triggerNavWave;
    favorites = FavoritesViewModel(library, player);
    downloads = DownloadsViewModel(this.downloadService);
    audioSettings = AudioSettingsViewModel(audioEngine);
    serverSettings = ServerSettingsViewModel(
      library,
      session,
      supportsLocalFolder: capabilities.supportsLocalFolder,
      requestFolderAccess: capabilities.requestFolderAccess,
    );
    search = SearchViewModel(library, player, openAlbum, openArtist, () => playlists.allPlaylists);

    // The full-screen player has nothing to show once nothing is loaded.
    player.addListener(() {
      if (player.currentTrack == null && _isNowPlayingOpen) isNowPlayingOpen = false;
    });

    _unsubscribers.addAll([
      audioEngine.trackChanged.listen((_) => _updateStatusText()),
      audioEngine.bitPerfectChanged.listen((_) => _updateStatusText()),
      audioEngine.exclusiveModeChanged.listen((_) => _updateStatusText()),
      audioEngine.stateChanged.listen((_) => _updateStatusText()),
      audioEngine.devicesChanged.listen((_) => _updateStatusText()),
      library.libraryChanged.listen((_) {
        _hidden = null; // the hidden items, and the tracks that name them, may have changed
        _followLocalFolder(); // a scan may have been of another folder
        _updateStatusText();
      }),
      library.scanningStateChanged.listen((_) => _updateStatusText()),
      session.stateChanged.listen((_) => _onSessionStateChanged()),
      Localizer.instance.languageChanged.listen((_) => _refreshLocalizedTexts()),
      // In offline mode, being out of touch with the server is no error.
      library.changeNotice.listen(
        (notice) => switch (notice) {
          ChangeNotice.readOnlyOffline when session.isOfflineMode => showNotice(Localizer.get('OfflineModeReadOnly')),
          ChangeNotice.readOnlyOffline => showNotice(Localizer.get('OfflineReadOnly'), isError: true),
          ChangeNotice.playlistKeptOnDevice => showNotice(
            Localizer.get(session.isOfflineMode ? 'OfflineModePlaylistLocal' : 'OfflinePlaylistLocal'),
          ),
        },
      ),
      // In offline mode, a copy removed is a track no longer shown.
      this.downloadService.changed.listen((_) => _followOfflineMode()),
      session.changeRefused.listen((reason) => showNotice(Localizer.format('ChangeRefused', [reason]), isError: true)),
      // Another player of the account changed its favourites, playlists or hidden items: this one shows them too.
      this.remote.accountDataChanged.listen((_) => unawaited(session.refreshUserData())),
      // The server found new music: it shows here without a restart.
      this.remote.libraryChanged.listen((_) => unawaited(session.refreshLibrary())),
    ]);

    _updateStatusText();
  }

  final WiretuneAudioEngine audioEngine;
  final LibraryService library;
  final ServerSession session;
  final DownloadService downloadService;
  final RemoteClient remote;
  final DeviceCapabilities capabilities;
  final OnlineLyrics? _onlineLyrics;
  final ArtistPictureService? _artistPictures;
  final List<void Function()> _unsubscribers = [];
  bool _disposed = false;

  late final PlayerViewModel player;
  late final LyricsViewModel lyrics;
  late final TracksViewModel tracks;
  late final AlbumsViewModel albums;
  late final ArtistsViewModel artists;
  late final PlaylistsViewModel playlists;
  late final FavoritesViewModel favorites;
  late final DownloadsViewModel downloads;
  late final AudioSettingsViewModel audioSettings;
  late final ServerSettingsViewModel serverSettings;
  late final SearchViewModel search;

  /// Called whenever the session's address or token changes, so cover requests to the server carry the token.
  void Function(String serverUrl, String? token)? onServerCredentialsChanged;

  /// What the app shows the user for a few seconds ([showNotice]).
  final Event<AppNotice> notices = Event<AppNotice>();

  void showNotice(String message, {bool isError = false, VoidCallback? undo}) =>
      notices.emit(AppNotice(message, isError: isError, undo: undo));

  // ── Navigation ─────────────────────────────────────────────────────────────────────────────────

  AppSection _selectedSection = AppSection.artists;

  // The tabs the user came from, the latest last; the tab that is open is never in it. Back walks it backwards.
  final List<AppSection> _tabHistory = [];
  bool _isRestoringTab = false;

  int waveTrigger = 0;
  NavWaveDirection lastWaveDirection = NavWaveDirection.leftToRight;

  AppSection get selectedSection => _selectedSection;
  set selectedSection(AppSection value) {
    if (_selectedSection == value) return;
    player.closeQueue();
    final previous = _selectedSection;
    _selectedSection = value;
    if (!_isRestoringTab) _rememberTab(previous, value);
    // The wave runs downwards to a section drawn below the one left, upwards to one above it.
    triggerNavWave(
      navVisualOrder(value) > navVisualOrder(previous) ? NavWaveDirection.leftToRight : NavWaveDirection.rightToLeft,
    );
    notifyListeners();
  }

  /// Leaving a tab adds it to the history; returning to a tab already in it cuts the history back to it.
  void _rememberTab(AppSection from, AppSection to) {
    final index = _tabHistory.lastIndexOf(to);
    if (index >= 0) {
      _tabHistory.removeRange(index, _tabHistory.length);
    } else {
      _tabHistory.add(from);
    }
  }

  void triggerNavWave(NavWaveDirection direction) {
    lastWaveDirection = direction;
    waveTrigger++;
    notifyListeners();
  }

  /// Raised when the section on show is chosen again from the navigation while its list is up (no album's, artist's
  /// or playlist's page, no search over it): the list scrolls back to its top. Its place is kept otherwise.
  final Event<void> scrollToTopRequested = Event<void>();

  /// How wide a wide screen's tiles are at the least (albums, artists, playlists): a pinch makes them larger or smaller,
  /// for as long as the app runs.
  final ValueNotifier<double> tileSize = ValueNotifier(tileSizeDefault);

  static const double tileSizeDefault = 176, tileSizeMin = 128, tileSizeMax = 320;

  /// A tab (a section of the sidebar) as TIDAL's and Spotify's: another one shows as it was left, an album's, an
  /// artist's or a playlist's page still open; the one on show chosen again goes from such a page back to its list,
  /// and from the list to its top.
  void navigateTo(AppSection section) {
    if (section == selectedSection && !isSearchOpen && !_closeDetailOf(section)) scrollToTopRequested.emit(null);
    // A page kept open is its tab's from now on, wherever it was opened from.
    albums.forgetOrigin();
    artists.forgetOrigin();
    playlists.forgetOrigin();
    searchQuery = '';
    isSearchOpen = false;
    // The automatic playlists follow what was played since.
    if (section == AppSection.playlists) playlists.refreshPlaylists();
    selectedSection = section;
  }

  /// Closes the page open over [section]'s list; false when none is.
  bool _closeDetailOf(AppSection section) {
    switch (section) {
      case AppSection.albums when albums.isAlbumDetailOpen:
        albums.forgetOrigin();
        albums.closeAlbumDetail();
      case AppSection.artists when artists.isArtistDetailOpen:
        artists.forgetOrigin();
        artists.closeArtistDetail();
      case AppSection.playlists when playlists.isPlaylistDetailOpen:
        playlists.forgetOrigin();
        playlists.closePlaylistDetail();
      default:
        return false;
    }
    return true;
  }

  // ── Search ─────────────────────────────────────────────────────────────────────────────────────

  String _searchQuery = '';
  bool _isSearchActive = false;
  bool _isSearchOpen = false;

  String get searchQuery => _searchQuery;
  set searchQuery(String value) {
    if (_searchQuery == value) return;
    _searchQuery = value;
    search.updateQuery(value);
    isSearchActive = value.trim().isNotEmpty;
    notifyListeners();
  }

  bool get isSearchActive => _isSearchActive;
  set isSearchActive(bool value) {
    if (_isSearchActive == value) return;
    _isSearchActive = value;
    if (value) {
      isSearchOpen = true;
    } else if (_searchQuery.isNotEmpty) {
      // A result was opened (the query is kept so that "back" can return to it): leave the search mode.
      isSearchOpen = false;
    }
    notifyListeners();
  }

  /// The search page of the phone layout.
  bool get isSearchOpen => _isSearchOpen;
  set isSearchOpen(bool value) {
    if (_isSearchOpen == value) return;
    _isSearchOpen = value;
    notifyListeners();
  }

  void clearSearch() => searchQuery = '';

  void openSearch() => isSearchOpen = true;

  /// Counts the requests for the cursor in the search field (Ctrl+F); the search field follows it.
  final ValueNotifier<int> searchFocusRequests = ValueNotifier(0);

  /// Opens the search (the phone layout's page) and puts the cursor in its field.
  void focusSearch() {
    openSearch();
    searchFocusRequests.value++;
  }

  void closeSearch() {
    searchQuery = '';
    isSearchOpen = false;
  }

  // ── Full-screen player (phone) ─────────────────────────────────────────────────────────────────

  bool _isNowPlayingOpen = false;
  NowPlayingTab _nowPlayingTab = NowPlayingTab.track;

  bool get isNowPlayingOpen => _isNowPlayingOpen;
  set isNowPlayingOpen(bool value) {
    if (_isNowPlayingOpen == value) return;
    _isNowPlayingOpen = value;
    if (!value) nowPlayingTab = NowPlayingTab.track;
    notifyListeners();
  }

  /// The queue and the lyrics are the player's queue panel: open while either is shown.
  NowPlayingTab get nowPlayingTab => _nowPlayingTab;
  set nowPlayingTab(NowPlayingTab value) {
    _nowPlayingTab = value;
    player.isQueueOpen = value != NowPlayingTab.track;
    notifyListeners();
  }

  void openNowPlaying() {
    if (player.currentTrack != null) isNowPlayingOpen = true;
  }

  PlayerSwipe? _playerSwipe;

  /// What a swipe left or right does in the full-screen player; null until the user picks it (at the first swipe).
  PlayerSwipe? get playerSwipe => _playerSwipe;
  set playerSwipe(PlayerSwipe? value) {
    if (value == null || value == _playerSwipe) return;
    _playerSwipe = value;
    _remember(_playerSwipePreference, value.name);
    notifyListeners();
  }

  /// A swipe in the full-screen player, to the left ([forward], towards what comes next) or to the right, doing what
  /// [playerSwipe] says. The tabs stop at either end.
  void swipeNowPlaying({required bool forward}) {
    switch (_playerSwipe) {
      case PlayerSwipe.tracks:
        forward ? player.nextTrack() : player.previousTrack(restart: false);
      case PlayerSwipe.tabs:
        const tabs = NowPlayingTab.values;
        final index = tabs.indexOf(_nowPlayingTab) + (forward ? 1 : -1);
        if (index >= 0 && index < tabs.length) nowPlayingTab = tabs[index];
      case null:
        break;
    }
  }

  void closeNowPlaying() => isNowPlayingOpen = false;

  // ── Back ───────────────────────────────────────────────────────────────────────────────────────

  /// The back button / gesture / remote key: closes the innermost open layer (full-screen player, sign-in screen,
  /// search, queue, detail page) and then walks back through the tabs the user visited. False when there is
  /// nothing left to go back to and the app may close.
  bool tryNavigateBack() {
    final step = _backStep();
    step?.call();
    return step != null;
  }

  /// Whether back has somewhere to go in the app ([tryNavigateBack] would be true); the app tells the system so, which
  /// otherwise closes it on a back gesture.
  bool get canNavigateBack => _backStep() != null;

  /// What back does now, or null when nothing is left to go back to.
  VoidCallback? _backStep() {
    if (_isNowPlayingOpen) {
      // The queue and the lyrics are tabs of the full-screen player: back returns to the track's, then closes it.
      return _nowPlayingTab != NowPlayingTab.track
          ? () => nowPlayingTab = NowPlayingTab.track
          : () => isNowPlayingOpen = false;
    }

    // The sign-in screen is shown over an empty library; leaving it to reach the (empty) app would be a dead end.
    if (_isLoginViewActive && library.tracks.isNotEmpty) return () => isLoginViewActive = false;

    if (_isSearchOpen || _isSearchActive) return closeSearch;

    if (player.isQueueOpen) return player.closeQueue;

    switch (_selectedSection) {
      case AppSection.albums when albums.isAlbumDetailOpen:
        return albums.closeAlbumDetail;
      case AppSection.artists when artists.isArtistDetailOpen:
        return artists.closeArtistDetail;
      // Back while renaming a playlist ends the renaming, as its Cancel does; the playlist stays open.
      case AppSection.playlists when playlists.isEditingName:
        return playlists.cancelRename;
      case AppSection.playlists when playlists.isPlaylistDetailOpen:
        return playlists.closePlaylistDetail;
      default:
        break;
    }

    // Back from a tab goes to the tab the user came from, shown as it was left (an open album stays open).
    if (_tabHistory.isNotEmpty) {
      return () {
        final previous = _tabHistory.removeLast();
        _isRestoringTab = true;
        try {
          selectedSection = previous;
        } finally {
          _isRestoringTab = false;
        }
      };
    }
    return null;
  }

  // ── Opening albums, artists and playlists from anywhere ────────────────────────────────────────

  /// How many times a page was opened from another tab or the search, or back went from it to there. The wide layout
  /// shows such a jump at once, as a page opened or left within a tab, the cover's flight being the way between the
  /// two: a cross-fade back would show the tab left, whose page is closed by then, as its list, and send the page's
  /// cover flying back to that list. (The phone's pages change at once anyway.)
  int jumps = 0;

  /// A page about to open on [target]'s tab: from another tab or the search, a jump ([jumps]).
  void _jumpTo(AppSection target) {
    if (target != _selectedSection || _isSearchOpen || _isSearchActive) jumps++;
  }

  /// What "back" does on an album, artist or playlist page opened from where the user is now: return to the search
  /// results, to the detail page the user came from, or to the tab. [target] is the section being opened.
  (String Function()?, void Function()?) _captureOrigin(AppSection target) {
    final (backText, onReturn) = _originOf(target);
    if (onReturn == null) return (backText, null);
    return (
      backText,
      () {
        jumps++;
        onReturn();
      },
    );
  }

  (String Function()?, void Function()?) _originOf(AppSection target) {
    if (_isSearchActive) {
      final activeQuery = _searchQuery;
      return (
        () => Localizer.get('Search'),
        () {
          _searchQuery = '';
          searchQuery = activeQuery;
          isSearchActive = true;
        },
      );
    }

    switch (_selectedSection) {
      case AppSection.albums when target != AppSection.albums && albums.selectedAlbum != null:
        final returnAlbum = albums.selectedAlbum!;
        return (
          () => returnAlbum.title,
          () {
            selectedSection = AppSection.albums;
            albums.openAlbumWithOrigin(returnAlbum, null, null, NavWaveDirection.rightToLeft);
          },
        );
      case AppSection.artists when target != AppSection.artists && artists.selectedArtist != null:
        final returnArtist = artists.selectedArtist!;
        return (
          () => returnArtist.name,
          () {
            selectedSection = AppSection.artists;
            artists.openArtistWithOrigin(returnArtist, null, null, NavWaveDirection.rightToLeft);
          },
        );
      case AppSection.playlists when target != AppSection.playlists && playlists.selectedPlaylist != null:
        final returnPlaylist = playlists.selectedPlaylist!;
        return (
          () => returnPlaylist.name,
          () {
            selectedSection = AppSection.playlists;
            playlists.openPlaylistWithOrigin(returnPlaylist, null, null, NavWaveDirection.rightToLeft);
          },
        );
      case AppSection.favorites:
        return (() => Localizer.get('NavFavorites'), () => selectedSection = AppSection.favorites);
      case AppSection.tracks:
        return (() => Localizer.get('NavTracks'), () => selectedSection = AppSection.tracks);
      default:
        return (null, null);
    }
  }

  /// Opens a page of [section] (an album's, an artist's, a playlist's) with [open], from wherever the user is: Back
  /// leads there again.
  void _openPage(AppSection section, void Function(String Function()? backText, void Function()? onReturn) open) {
    _jumpTo(section);
    final (backText, onReturn) = _captureOrigin(section);
    open(backText, onReturn);
    isNowPlayingOpen = false;
    isSearchActive = false;
    selectedSection = section;
    notifyListeners();
  }

  void openAlbum(Album? album) {
    if (album == null) return;
    _openPage(AppSection.albums, (backText, onReturn) => albums.openAlbumWithOrigin(album, backText, onReturn));
  }

  void openAlbumOfTrack(Track? track) {
    if (track != null) openAlbum(library.getAlbumForTrack(track));
  }

  void openArtist(Artist? artist) {
    if (artist == null) return;
    _openPage(AppSection.artists, (backText, onReturn) => artists.openArtistWithOrigin(artist, backText, onReturn));
  }

  void openPlaylist(Playlist? playlist) {
    if (playlist == null) return;
    _openPage(
      AppSection.playlists,
      (backText, onReturn) => playlists.openPlaylistWithOrigin(playlist, backText, onReturn),
    );
  }

  void openArtistByName(String? artistName) {
    if (artistName != null && artistName.trim().isNotEmpty) openArtist(library.getArtistByName(artistName));
  }

  /// Puts [tracks] right after the current track ([next]) or at the end of the queue, and says so, naming them by
  /// [name] (a track's title, an album's, an artist's name), with an Undo (not for a device being controlled). With
  /// nothing queued they simply play, which says enough.
  void queue(List<Track> tracks, {required bool next, required String name}) {
    if (tracks.isEmpty) return;
    final says = player.queueItems.isNotEmpty;
    final undo = next ? player.playNext(tracks) : player.addToQueue(tracks);
    if (says) showNotice(Localizer.format(next ? 'QueuedNext' : 'QueuedLast', [name]), undo: undo);
  }

  // ── Server and sign-in ─────────────────────────────────────────────────────────────────────────

  /// The banner over the library while the server's tracks can't play: the server is out of reach, or this device is
  /// no longer signed in to it (the sign-in expired, the password changed, the account was removed).
  bool isServerOfflineBannerVisible = false;
  String serverBannerMessage = '';

  /// The banner's way out: sign in again, rather than reconnect.
  bool serverBannerNeedsSignIn = false;
  bool _isLoginViewActive = false;

  bool get isUserLoggedIn => session.isLoggedIn;

  bool get isLoginViewActive => _isLoginViewActive;
  set isLoginViewActive(bool value) {
    if (_isLoginViewActive == value) return;
    _isLoginViewActive = value;
    notifyListeners();
  }

  Future<void> retryConnectServer() => session.connect();

  /// The player came back to the front: what changed while it was away shows, and a server that was out of reach is
  /// asked again at once. A local folder that can't be watched (a phone's) is read again, at most once a minute.
  Future<void> resume() async {
    if (startupError != null) return;
    if (!FolderWatch.isSupported && DateTime.now().difference(_localFolderRead) > const Duration(minutes: 1)) {
      unawaited(_readLocalFolder());
    }
    await session.resume();
  }

  // ── The local folder ───────────────────────────────────────────────────────────────────────────

  /// Music copied into the local folder, or deleted from it, shows by itself: the folder is read at start, watched
  /// while the player runs (a computer), and read again when the player comes back to the front (a phone).
  late final FolderWatch _folderWatch = FolderWatch(() => unawaited(_readLocalFolder()));
  DateTime _localFolderRead = DateTime.fromMillisecondsSinceEpoch(0);

  void _followLocalFolder() {
    final folder = library.musicFolder;
    if (!capabilities.supportsLocalFolder || folder.isEmpty) return _folderWatch.stop();
    _folderWatch.watch(folder, skip: downloadService.directory);
  }

  /// Reads what changed in the local folder since its last scan (only changed files are read, and an unchanged folder
  /// changes nothing). A folder that is gone or looks empty, such as an unplugged drive or a card taken out, is left
  /// for later: it never empties the library.
  Future<void> _readLocalFolder() async {
    final folder = library.musicFolder;
    if (!capabilities.supportsLocalFolder || folder.isEmpty || library.isScanning) return;
    _localFolderRead = DateTime.now();
    try {
      final directory = Directory(folder);
      if (!directory.existsSync() || directory.listSync().isEmpty) return;
      await library.scanFolder(folder);
    } catch (e) {
      WiretuneLog.warn('MainViewModel', "Could not read the local folder '$folder' again: $e");
    }
  }

  void dismissServerBanner() {
    isServerOfflineBannerVisible = false;
    notifyListeners();
  }

  void continueOffline() => isLoginViewActive = false;

  void showLoginScreen() => isLoginViewActive = true;

  /// Signs out, and removes the downloads: they are copies of the account's server.
  Future<void> logout() async {
    player.releaseRemote();
    await serverSettings.logout();
    downloadService.removeAll();
    isLoginViewActive = library.tracks.isEmpty;
    notifyListeners();
  }

  void _onSessionStateChanged() {
    onServerCredentialsChanged?.call(session.serverUrl, session.authToken);
    _followOfflineMode();
    final offline = session.state == ServerConnectionState.offline;
    serverBannerNeedsSignIn = session.state == ServerConnectionState.loginRequired && session.authToken == null;
    isServerOfflineBannerVisible = session.usesServer && !session.isOfflineMode && (offline || serverBannerNeedsSignIn);
    serverBannerMessage = serverBannerNeedsSignIn
        ? session.statusMessage ?? Localizer.get('SessionLoginRequired')
        : session.usesLocalFolder && offline
        ? Localizer.format('ServerBannerOffline', [session.serverUrl])
        : session.statusMessage ?? Localizer.format('ServerBannerUnreachable', [session.serverUrl]);

    if (session.isLoggedIn) _isLoginViewActive = false;
    _updateStatusText();
  }

  // What the library shows for offline mode: whether it's on, and how many copies there were.
  bool _showsOffline = false;
  int _copiesShown = 0;

  /// In offline mode the library shows only what plays without the server: the local files and the downloaded copies.
  void _followOfflineMode() {
    final offline = session.isOfflineMode;
    if (offline == _showsOffline && (!offline || downloadService.copyCount == _copiesShown)) return;
    _showsOffline = offline;
    _copiesShown = downloadService.copyCount;
    library.showOnly(offline ? (t) => t.isLocal || downloadService.hasCopy(t) : null);
  }

  // ── Status lines ───────────────────────────────────────────────────────────────────────────────

  /// Why the player could not start (its database can't be opened, say); it then shows only this.
  String? startupError;
  String statusText = Localizer.get('StatusStarting');
  String rightFooterStatusText = Localizer.get('FooterLoading');

  void _updateStatusText() {
    if (_disposed) return;
    final device = audioEngine.currentDevice;
    final mode = Localizer.get(
      audioEngine.isBitPerfect ? 'ModeBitPerfect' : (audioEngine.isExclusiveMode ? 'ModeExclusive' : 'ModeShared'),
    );
    final deviceName = device?.name ?? Localizer.get('DefaultOutput');
    final driver = device != null && device.driverType.trim().isNotEmpty ? '[${device.driverType}]' : '';
    statusText = driver.isEmpty ? '$mode • $deviceName' : '$mode • $deviceName $driver';

    if (library.isScanning) {
      rightFooterStatusText = Localizer.get('FooterScanning');
    } else if (library.tracks.isEmpty) {
      rightFooterStatusText = Localizer.get('FooterNoTracks');
    } else {
      final localCount = library.tracks.where((t) => t.isLocal).length;
      final serverCount = library.tracks.length - localCount;
      final counts =
          '${Localizer.format('ArtistCount', [library.artists.length])} • '
          '${Localizer.format('AlbumCount', [library.albums.length])} • '
          '${Localizer.format('TrackCount', [library.tracks.length])}';
      final origin = localCount > 0 && serverCount > 0
          ? Localizer.format('FooterLocalAndServer', [localCount, serverCount])
          : (serverCount > 0
                ? Localizer.format('FooterServerOnly', [serverCount])
                : Localizer.format('FooterLocalOnly', [localCount]));
      rightFooterStatusText = '$counts $origin';
    }
    notifyListeners();
  }

  // ── Preferences ────────────────────────────────────────────────────────────────────────────────

  static const String _languagePreference = 'language';
  static const String _themePreference = 'theme';
  static const String _performanceStatsPreference = 'show_performance_stats';
  static const String _onlineLyricsPreference = 'online_lyrics';
  static const String _remoteIdPreference = 'remote_device_id';
  static const String _remoteNamePreference = 'remote_device_name';
  static const String _remoteEnabledPreference = 'remote_enabled';
  static const String _normalizationPreference = 'volume_normalization';
  static const String _gaplessPreference = 'gapless';
  static const String _playerSwipePreference = 'player_swipe';

  bool _isLight = false;
  bool _showPerformanceStats = false;

  bool get isLight => _isLight;

  void setTheme({required bool light, bool persist = true}) {
    _isLight = light;
    if (persist) _remember(_themePreference, light ? 'light' : 'dark');
    notifyListeners();
  }

  /// Frame graphs drawn over the app, for tuning performance; off until the user turns them on.
  bool get showPerformanceStats => _showPerformanceStats;
  set showPerformanceStats(bool value) {
    _showPerformanceStats = value;
    _remember(_performanceStatsPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// Whether a track without lyrics of its own is looked up online (LRCLIB); on by default.
  bool get useOnlineLyrics => lyrics.isOnlineEnabled;
  set useOnlineLyrics(bool value) {
    lyrics.isOnlineEnabled = value;
    _remember(_onlineLyricsPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// Volume normalization from the ReplayGain tags; off by default (the files play as they are).
  VolumeNormalization get normalization => audioEngine.normalization;
  set normalization(VolumeNormalization value) {
    audioEngine.setNormalization(value);
    audioSettings.refreshDeviceList(); // the signal path mentions it
    _remember(_normalizationPreference, value.name);
    notifyListeners();
  }

  /// Gapless playback (the next track starts the moment the current one ends); on by default.
  bool get isGaplessEnabled => player.isGaplessEnabled;
  set isGaplessEnabled(bool value) {
    player.isGaplessEnabled = value;
    _remember(_gaplessPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// Whether the account's other players see this one and may control it (and it them); on by default.
  bool get isRemoteEnabled => remote.isEnabled;
  set isRemoteEnabled(bool value) {
    if (!value) player.releaseRemote();
    _configureRemote(enabled: value);
    _remember(_remoteEnabledPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// The name the other players show for this one.
  String get deviceName => remote.deviceName;
  set deviceName(String value) {
    final name = RemoteRules.cleanName(value);
    if (name == remote.deviceName) return;
    _configureRemote(name: name);
    _remember(_remoteNamePreference, name);
    notifyListeners();
  }

  /// What remote control is doing, in a sentence: off, signed out, why it can't connect, or how many of the account's
  /// other players it reaches.
  String get remoteStatus {
    if (!isRemoteEnabled) return Localizer.get('RemoteStatusOff');
    final waitingForServer =
        session.state == ServerConnectionState.offline || session.state == ServerConnectionState.connecting;
    if (!session.isLoggedIn && !waitingForServer) return Localizer.get('RemoteStatusSignedOut');
    return switch (remote.problem) {
      RemoteProblem.tooManyDevices => Localizer.format('RemoteStatusTooManyDevices', [
        RemoteRules.maxDevicesPerAccount,
      ]),
      RemoteProblem.replaced => Localizer.get('RemoteStatusReplaced'),
      RemoteProblem.ended => Localizer.get('RemoteStatusEnded'),
      null =>
        player.canReachDevices
            ? Localizer.format('RemoteStatusConnected', [player.otherDevices.length])
            : Localizer.get('RemoteStatusConnecting'),
    };
  }

  /// Whether [remoteStatus] tells why remote control doesn't work.
  bool get hasRemoteProblem => isRemoteEnabled && remote.problem != null;

  void _configureRemote({String? id, String? name, bool? enabled}) {
    remote.configure(
      id: id ?? remote.deviceId,
      name: name ?? remote.deviceName,
      kind: capabilities.kind,
      enabled: enabled ?? remote.isEnabled,
    );
    session.deviceId = remote.deviceId;
  }

  /// The lyrics a track carries: a local file's tags, a downloaded copy's, or the server's copy of them.
  Future<String?> _ownLyrics(Track track) async {
    if (track.isLocal) return track.filePath.isEmpty ? null : MetadataScanner.readLyrics(track.filePath);
    final copy = downloadService.localCopy(track);
    return copy != null ? MetadataScanner.readLyrics(copy) : session.getLyrics(track);
  }

  String get language => Localizer.instance.language;

  /// Switches the interface language and remembers the choice.
  void changeLanguage(String? code) {
    if (!Localizer.instance.setLanguage(code)) return;
    _remember(_languagePreference, Localizer.instance.language);
  }

  void _remember(String name, String value) {
    try {
      library.setPreference(name, value);
    } catch (e) {
      WiretuneLog.warn('MainViewModel', 'Could not save a preference: $e');
    }
  }

  /// Applies the language, theme and switches the user picked in an earlier session.
  Future<void> _applyPreferences() async {
    final language = Localizer.normalize(library.getPreference(_languagePreference));
    if (language != null) Localizer.instance.setLanguage(language);

    final theme = library.getPreference(_themePreference);
    if (theme != null) _isLight = theme == 'light';

    _showPerformanceStats = library.getPreference(_performanceStatsPreference) == '1';
    lyrics.isOnlineEnabled = library.getPreference(_onlineLyricsPreference) != '0'; // on unless turned off
    final normalization = VolumeNormalization.values.asNameMap()[library.getPreference(_normalizationPreference)];
    if (normalization != null) audioEngine.setNormalization(normalization);
    player.isGaplessEnabled = library.getPreference(_gaplessPreference) != '0'; // on unless turned off
    _playerSwipe = PlayerSwipe.values.asNameMap()[library.getPreference(_playerSwipePreference)];

    // A lasting ID of its own, so the others know it again after a restart; it connects once signed in.
    var id = library.getPreference(_remoteIdPreference);
    if (id == null || id.isEmpty) {
      id = newId();
      library.setPreference(_remoteIdPreference, id);
    }
    _configureRemote(
      id: id,
      name: library.getPreference(_remoteNamePreference) ?? capabilities.name,
      enabled: library.getPreference(_remoteEnabledPreference) != '0',
    );
  }

  void _refreshLocalizedTexts() {
    _onSessionStateChanged();
    tracks.refreshTracks();
    albums.refreshLocalizedTexts();
    artists.refreshLocalizedTexts();
    player.refreshLocalizedTexts();
    lyrics.refreshLocalizedTexts();
    playlists.refreshLocalizedTexts();
    favorites.refreshLocalizedTexts();
    search.refreshLocalizedTexts();
    audioSettings.refreshLocalizedTexts();
    serverSettings.refreshLocalizedTexts();
    notifyListeners();
  }

  // ── Hidden artists, albums and tracks ──────────────────────────────────────────────────────────

  List<HiddenItem>? _hidden;

  /// What the user hid, the artists first, then the albums and the tracks, each with the name it goes by. Worked out
  /// again only when the library changes: the names come from the tracks, as artists and albums are hidden by hashes.
  List<HiddenItem> get hiddenItems => _hidden ??= _describeHidden();

  void unhide(HiddenItem item) => library.setHidden(item.kind, item.id, false);

  /// Hides the artist, album or track [id] and says so, naming it [name], with an Undo: a slip in a menu is one tap to
  /// take back.
  void hide(HiddenKind kind, String id, String name) {
    library.setHidden(kind, id, true);
    // Offline, an account's music can't change, and the library says why itself.
    if (!library.hidden(kind).contains(id)) return;
    showNotice(Localizer.format('HiddenNotice', [name]), undo: () => library.setHidden(kind, id, false));
  }

  List<HiddenItem> _describeHidden() {
    final artists = library.hidden(HiddenKind.artist);
    final albums = library.hidden(HiddenKind.album);
    // An artist goes by the album artist of its first track (hidden as either the track's artist or its album
    // artist), an album by its title and album artist.
    final artistNames = <String, String>{};
    final albumNames = <String, String>{};
    if (artists.isNotEmpty || albums.isNotEmpty) {
      for (final track in library.rawTracks) {
        for (final name in artists.isEmpty ? const <String>[] : [track.primaryArtist, track.effectiveAlbumArtist]) {
          final id = artistIdOf(name);
          if (artists.contains(id)) artistNames.putIfAbsent(id, () => track.effectiveAlbumArtist);
        }
        final albumId = albums.isEmpty ? null : track.albumId;
        if (albumId != null && albums.contains(albumId)) {
          albumNames.putIfAbsent(albumId, () => '${track.album} • ${track.effectiveAlbumArtist}');
        }
      }
    }
    return [
      for (final id in artists) HiddenItem(HiddenKind.artist, id, artistNames[id] ?? id),
      for (final id in albums) HiddenItem(HiddenKind.album, id, albumNames[id] ?? id),
      for (final id in library.hidden(HiddenKind.track))
        HiddenItem(HiddenKind.track, id, switch (library.getTrack(id)) {
          final track? => '${track.title} • ${track.artist}',
          null => id,
        }),
    ];
  }

  // ── Start-up ───────────────────────────────────────────────────────────────────────────────────

  /// Loads the local cache, then reconnects to the server if it is the library source.
  Future<void> start() async {
    try {
      library.initialize();
      await _applyPreferences();
      player.restoreSession();
      session.initialize();
      await downloadService.initialize();
      serverSettings.syncWithSession();
    } catch (e, s) {
      WiretuneLog.error('MainViewModel', 'Start-up failed: $e', e, s);
      startupError = e is IncompatibleDatabaseException
          ? Localizer.format('StartupDatabaseIncompatible', [e.path ?? ''])
          : Localizer.format('StartupError', ['$e']);
      statusText = startupError!;
      notifyListeners();
      return;
    }
    // The cached library is usable now; the server connection below may take a while, and so may the local folder.
    _updateStatusText();
    unawaited(_readLocalFolder());
    _followLocalFolder();

    if (session.usesServer) await session.connect();

    // With nothing to play, or only a server that wants a sign-in, the sign-in screen comes first.
    isLoginViewActive = session.usesLocalFolder
        ? false
        : session.usesServer
        ? session.state == ServerConnectionState.loginRequired || session.state == ServerConnectionState.setupRequired
        : library.tracks.isEmpty;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final unsubscribe in _unsubscribers) {
      unsubscribe();
    }
    lyrics.dispose();
    player.dispose();
    tracks.dispose();
    albums.dispose();
    artists.dispose();
    playlists.dispose();
    favorites.dispose();
    downloads.dispose();
    audioSettings.dispose();
    serverSettings.dispose();
    search.dispose();
    unawaited(audioEngine.dispose());
    remote.dispose();
    downloadService.dispose();
    session.dispose();
    _folderWatch.stop();
    _onlineLyrics?.close();
    _artistPictures?.close();
    searchFocusRequests.dispose();
    tileSize.dispose();
    super.dispose();
  }
}
