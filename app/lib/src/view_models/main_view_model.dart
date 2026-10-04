import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'app_section.dart';
import 'library_view_models.dart';
import 'player_view_model.dart';
import 'search_view_model.dart';
import 'settings_view_models.dart';

/// What the device the app runs on can do; decided once at start-up.
class DeviceCapabilities {
  const DeviceCapabilities({this.supportsLocalFolder = false, this.isTv = false, this.isDesktop = false});

  /// Scanning a folder of the device's own (desktop).
  final bool supportsLocalFolder;

  /// A television (Android TV, Tizen): the wide layout, steered with a remote.
  final bool isTv;

  final bool isDesktop;
}

/// The whole app's state: the services, one view model per area, the navigation and the status lines. The wide and
/// the phone layout are two views of this one model.
class MainViewModel extends ChangeNotifier {
  MainViewModel(
    this.audioEngine,
    this.library,
    this.session, {
    OnlineLyrics? onlineLyrics,
    this.capabilities = const DeviceCapabilities(),
  }) : _onlineLyrics = onlineLyrics {
    // Stream URLs carry a short-lived, media-only token that the session renews, not the sign-in token.
    audioEngine.setStreamTokenProvider(session.getStreamToken);

    player = PlayerViewModel(audioEngine, library)
      ..lyricsProvider = ((track, ct) =>
          track.isLocal ? MetadataScanner.readLyrics(track.filePath) : session.getLyrics(track))
      ..isOnlineLyricsEnabled = _useOnlineLyrics;
    if (onlineLyrics != null) player.onlineLyricsProvider = (track, ct) => onlineLyrics.find(track);

    tracks = TracksViewModel(library, player);
    albums = AlbumsViewModel(library, player)..onNavWave = triggerNavWave;
    artists = ArtistsViewModel(library, player)..onNavWave = triggerNavWave;
    playlists = PlaylistsViewModel(library, player)..onNavWave = triggerNavWave;
    favorites = FavoritesViewModel(library, player);
    audioSettings = AudioSettingsViewModel(audioEngine);
    serverSettings = ServerSettingsViewModel(library, session, supportsLocalFolder: capabilities.supportsLocalFolder);
    search = SearchViewModel(library, player, (q) => searchQuery = q, openAlbum, openArtist);

    // The full-screen player has nothing to show once nothing is loaded.
    player.addListener(() {
      if (player.currentTrack == null && _isNowPlayingOpen) isNowPlayingOpen = false;
    });

    _unsubscribers.addAll([
      audioEngine.trackChanged.listen((_) => _updateStatusText()),
      audioEngine.bitperfectChanged.listen((_) => _updateStatusText()),
      audioEngine.exclusiveModeChanged.listen((_) => _updateStatusText()),
      audioEngine.stateChanged.listen((_) => _updateStatusText()),
      audioEngine.devicesChanged.listen((_) => _updateStatusText()),
      library.libraryChanged.listen((_) => _updateStatusText()),
      library.scanningStateChanged.listen((_) => _updateStatusText()),
      session.stateChanged.listen((_) => _onSessionStateChanged()),
      Localizer.instance.languageChanged.listen((_) => _refreshLocalizedTexts()),
    ]);

    _updateAuthDisplay();
    _updateStatusText();
  }

  static const double compactLayoutWidth = 1000;

  final WiretuneAudioEngine audioEngine;
  final LibraryService library;
  final ServerSession session;
  final DeviceCapabilities capabilities;
  final OnlineLyrics? _onlineLyrics;
  final List<void Function()> _unsubscribers = [];
  bool _disposed = false;

  late final PlayerViewModel player;
  late final TracksViewModel tracks;
  late final AlbumsViewModel albums;
  late final ArtistsViewModel artists;
  late final PlaylistsViewModel playlists;
  late final FavoritesViewModel favorites;
  late final AudioSettingsViewModel audioSettings;
  late final ServerSettingsViewModel serverSettings;
  late final SearchViewModel search;

  /// Called whenever the session's address or token changes, so cover requests to the server carry the token.
  void Function(String serverUrl, String? token)? onServerCredentialsChanged;

  // ── Navigation ─────────────────────────────────────────────────────────────────────────────────

  AppSection _selectedSection = AppSection.artists;
  AppSection _previousSection = AppSection.artists;

  // The tabs the user came from, the latest last; the tab that is open is never in it. Back walks it backwards.
  final List<AppSection> _tabHistory = [];
  bool _isRestoringTab = false;

  int waveTrigger = 0;
  NavWaveDirection lastWaveDirection = NavWaveDirection.leftToRight;

  AppSection get selectedSection => _selectedSection;
  set selectedSection(AppSection value) {
    if (_selectedSection == value) return;
    player.closeQueue();
    _selectedSection = value;

    if (_previousSection != value) {
      if (!_isRestoringTab) _rememberTab(_previousSection, value);
      final oldOrder = navVisualOrder(_previousSection);
      final newOrder = navVisualOrder(value);
      if (newOrder > oldOrder) {
        triggerNavWave(NavWaveDirection.leftToRight); // downwards
      } else if (newOrder < oldOrder) {
        triggerNavWave(NavWaveDirection.rightToLeft); // upwards
      }
    }
    _previousSection = value;
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

  void navigateTo(AppSection section) {
    if (section == AppSection.albums) {
      albums.returnAction = null;
      albums.closeAlbumDetail();
    } else if (section == AppSection.artists) {
      artists.returnAction = null;
      artists.closeArtistDetail();
    }
    searchQuery = '';
    isSearchOpen = false;
    selectedSection = section;
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

  void closeSearch() {
    searchQuery = '';
    isSearchOpen = false;
  }

  // ── Full-screen player (phone) ─────────────────────────────────────────────────────────────────

  bool _isNowPlayingOpen = false;
  int _nowPlayingTab = 0;

  bool get isNowPlayingOpen => _isNowPlayingOpen;
  set isNowPlayingOpen(bool value) {
    if (_isNowPlayingOpen == value) return;
    _isNowPlayingOpen = value;
    if (!value) nowPlayingTab = 0;
    notifyListeners();
  }

  /// 0 = player, 1 = queue, 2 = lyrics.
  int get nowPlayingTab => _nowPlayingTab;
  set nowPlayingTab(int value) {
    if (value < 0 || value > 2) return;
    _nowPlayingTab = value;
    player.isQueueOpen = value != 0;
    notifyListeners();
  }

  void openNowPlaying() {
    if (player.currentTrack != null) isNowPlayingOpen = true;
  }

  void closeNowPlaying() => isNowPlayingOpen = false;

  // ── Back ───────────────────────────────────────────────────────────────────────────────────────

  /// The back button / gesture / remote key: closes the innermost open layer (dialog, full-screen player, sign-in
  /// screen, search, queue, detail page) and then walks back through the tabs the user visited. False when there is
  /// nothing left to go back to and the app may close.
  bool tryNavigateBack() {
    if (playlists.isCreateDialogOpen) {
      playlists.closeCreateDialog();
      return true;
    }
    if (playlists.isAddToPlaylistDialogOpen) {
      playlists.cancelAddTrack();
      return true;
    }
    if (playlists.isDeleteConfirmOpen) {
      playlists.cancelDeletePlaylist();
      return true;
    }

    if (_isNowPlayingOpen) {
      // The queue and the lyrics are pages of the full-screen player: back returns to the player, then closes it.
      if (_nowPlayingTab != 0) {
        nowPlayingTab = 0;
      } else {
        isNowPlayingOpen = false;
      }
      return true;
    }

    // The sign-in screen is shown over an empty library; leaving it to reach the (empty) app would be a dead end.
    if (_isLoginViewActive && library.tracks.isNotEmpty) {
      isLoginViewActive = false;
      return true;
    }

    if (_isSearchOpen || _isSearchActive) {
      closeSearch();
      return true;
    }

    if (player.isQueueOpen) {
      player.closeQueue();
      return true;
    }

    switch (_selectedSection) {
      case AppSection.albums when albums.isAlbumDetailOpen:
        albums.closeAlbumDetail();
        return true;
      case AppSection.artists when artists.isArtistDetailOpen:
        artists.closeArtistDetail();
        return true;
      case AppSection.playlists when playlists.isPlaylistDetailOpen:
        playlists.closePlaylistDetail();
        return true;
      default:
        break;
    }

    // Back from a tab goes to the tab the user came from, shown as it was left (an open album stays open).
    if (_tabHistory.isNotEmpty) {
      final previous = _tabHistory.removeLast();
      _isRestoringTab = true;
      try {
        selectedSection = previous;
      } finally {
        _isRestoringTab = false;
      }
      return true;
    }
    return false;
  }

  // ── Opening albums and artists from anywhere ───────────────────────────────────────────────────

  /// What "back" does on an album or artist page opened from where the user is now: return to the search results, to
  /// the detail page the user came from, or to the tab. [target] is the section being opened.
  (String Function()?, void Function()?) _captureOrigin(AppSection target) {
    if (_isSearchActive) {
      final activeQuery = _searchQuery;
      return (
        () => Localizer.get('BackToSearch'),
        () {
          _searchQuery = '';
          searchQuery = activeQuery;
          isSearchActive = true;
        },
      );
    }

    switch (_selectedSection) {
      case AppSection.albums
          when target != AppSection.albums && albums.isAlbumDetailOpen && albums.selectedAlbum != null:
        final returnAlbum = albums.selectedAlbum!;
        return (
          () => Localizer.format('BackTo', [returnAlbum.title]),
          () {
            selectedSection = AppSection.albums;
            albums.openAlbumWithOrigin(returnAlbum, null, null, NavWaveDirection.rightToLeft);
          },
        );
      case AppSection.artists
          when target != AppSection.artists && artists.isArtistDetailOpen && artists.selectedArtist != null:
        final returnArtist = artists.selectedArtist!;
        return (
          () => Localizer.format('BackTo', [returnArtist.name]),
          () {
            selectedSection = AppSection.artists;
            artists.openArtistWithOrigin(returnArtist, null, null, NavWaveDirection.rightToLeft);
          },
        );
      case AppSection.playlists when playlists.isPlaylistDetailOpen && playlists.selectedPlaylist != null:
        final returnPlaylist = playlists.selectedPlaylist!;
        return (
          () => Localizer.format('BackTo', [returnPlaylist.name]),
          () {
            selectedSection = AppSection.playlists;
            playlists.openPlaylist(returnPlaylist);
          },
        );
      case AppSection.favorites:
        return (() => Localizer.get('BackToFavorites'), () => selectedSection = AppSection.favorites);
      case AppSection.tracks:
        return (() => Localizer.get('BackToTracks'), () => selectedSection = AppSection.tracks);
      default:
        return (null, null);
    }
  }

  void openAlbum(Album? album) {
    if (album == null) return;
    final (backText, onReturn) = _captureOrigin(AppSection.albums);
    albums.openAlbumWithOrigin(album, backText, onReturn);
    isNowPlayingOpen = false;
    isSearchActive = false;
    selectedSection = AppSection.albums;
    notifyListeners();
  }

  void openAlbumOfTrack(Track? track) {
    if (track != null) openAlbum(library.getAlbumForTrack(track));
  }

  void openArtist(Artist? artist) {
    if (artist == null) return;
    final (backText, onReturn) = _captureOrigin(AppSection.artists);
    artists.openArtistWithOrigin(artist, backText, onReturn);
    isNowPlayingOpen = false;
    isSearchActive = false;
    selectedSection = AppSection.artists;
    notifyListeners();
  }

  void openArtistByName(String? artistName) {
    if (artistName != null && artistName.trim().isNotEmpty) openArtist(library.getArtistByName(artistName));
  }

  void addToPlaylist(Track? track) {
    if (track != null) playlists.beginAddTrack(track);
  }

  // ── Server and sign-in ─────────────────────────────────────────────────────────────────────────

  bool isServerOfflineBannerVisible = false;
  String serverBannerMessage = '';
  bool _isLoginViewActive = false;
  bool isUserLoggedIn = false;
  String currentUserBadge = Localizer.get('SignIn');

  bool get isLoginViewActive => _isLoginViewActive;
  set isLoginViewActive(bool value) {
    if (_isLoginViewActive == value) return;
    _isLoginViewActive = value;
    notifyListeners();
  }

  Future<void> retryConnectServer() => session.connect();

  void dismissServerBanner() {
    isServerOfflineBannerVisible = false;
    notifyListeners();
  }

  void continueOffline() => isLoginViewActive = false;

  void showLoginScreen() => isLoginViewActive = true;

  Future<void> logout() async {
    await serverSettings.logout();
    _updateAuthDisplay();
    isLoginViewActive = library.tracks.isEmpty;
    notifyListeners();
  }

  void _onSessionStateChanged() {
    onServerCredentialsChanged?.call(session.serverUrl, session.authToken);
    isServerOfflineBannerVisible =
        (session.source == LibrarySource.server || session.source == LibrarySource.hybrid) &&
        session.state == ServerConnectionState.offline;
    serverBannerMessage = session.source == LibrarySource.hybrid && session.state == ServerConnectionState.offline
        ? Localizer.format('ServerBannerOffline', [session.serverUrl])
        : session.statusMessage ?? Localizer.format('ServerBannerUnreachable', [session.serverUrl]);

    if (session.isLoggedIn) _isLoginViewActive = false;
    _updateAuthDisplay();
    _updateStatusText();
  }

  void _updateAuthDisplay() {
    isUserLoggedIn = session.isLoggedIn;
    currentUserBadge = session.currentUser?.username ?? Localizer.get('SignIn');
  }

  // ── Status lines ───────────────────────────────────────────────────────────────────────────────

  bool isStarting = true;
  bool isLibraryEmpty = false;
  String statusText = Localizer.get('StatusStarting');
  String rightFooterStatusText = Localizer.get('FooterLoading');

  void _updateStatusText() {
    if (_disposed) return;
    isLibraryEmpty = !isStarting && library.tracks.isEmpty;

    final device = audioEngine.currentDevice;
    final mode = Localizer.get(
      audioEngine.isBitperfect ? 'ModeBitPerfect' : (audioEngine.isExclusiveMode ? 'ModeExclusive' : 'ModeShared'),
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

  static const String _languagePreference = 'Language';
  static const String _themePreference = 'Theme';
  static const String _performanceStatsPreference = 'ShowPerformanceStats';
  static const String _onlineLyricsPreference = 'OnlineLyrics';

  bool _isLight = false;
  bool _showPerformanceStats = false;
  bool _useOnlineLyrics = true;

  bool get isLight => _isLight;

  void toggleTheme() => setTheme(light: !_isLight);

  void setTheme({required bool light, bool persist = true}) {
    _isLight = light;
    if (persist) _remember(library.setPreference(_themePreference, light ? 'Light' : 'Dark'));
    notifyListeners();
  }

  /// Frame graphs drawn over the app, for tuning performance; off until the user turns them on.
  bool get showPerformanceStats => _showPerformanceStats;
  set showPerformanceStats(bool value) {
    _showPerformanceStats = value;
    _remember(library.setPreference(_performanceStatsPreference, value ? '1' : '0'));
    notifyListeners();
  }

  /// Whether a track without lyrics of its own is looked up online (LRCLIB); on by default.
  bool get useOnlineLyrics => _useOnlineLyrics;
  set useOnlineLyrics(bool value) {
    _useOnlineLyrics = value;
    player.isOnlineLyricsEnabled = value;
    _remember(library.setPreference(_onlineLyricsPreference, value ? '1' : '0'));
    notifyListeners();
  }

  /// The languages the user can pick.
  List<LanguageInfo> get languages => Localizer.languages;

  String get language => Localizer.instance.language;

  /// Text of the language picker's button: the active language's code, e.g. "EN".
  String get languageBadge => Localizer.instance.language.toUpperCase();

  /// Switches the interface language and remembers the choice.
  void changeLanguage(String? code) {
    if (!Localizer.instance.setLanguage(code)) return;
    _remember(library.setPreference(_languagePreference, Localizer.instance.language));
  }

  void _remember(Future<void> write) => unawaited(
    write.catchError((Object e) {
      WiretuneLog.warn('MainViewModel', 'Could not save a preference: $e');
    }),
  );

  /// Applies the language, theme and switches the user picked in an earlier session.
  Future<void> _applyPreferences() async {
    final language = Localizer.normalize(await library.getPreference(_languagePreference));
    if (language != null) Localizer.instance.setLanguage(language);

    final theme = await library.getPreference(_themePreference);
    if (theme != null) _isLight = theme.toLowerCase() == 'light';

    _showPerformanceStats = await library.getPreference(_performanceStatsPreference) == '1';
    _useOnlineLyrics = await library.getPreference(_onlineLyricsPreference) != '0'; // on unless turned off
    player.isOnlineLyricsEnabled = _useOnlineLyrics;
  }

  void _refreshLocalizedTexts() {
    _onSessionStateChanged();
    tracks.refreshTracks();
    albums.refreshLocalizedTexts();
    artists.refreshLocalizedTexts();
    player.refreshLocalizedTexts();
    playlists.refreshLocalizedTexts();
    favorites.refreshLocalizedTexts();
    search.refreshLocalizedTexts();
    audioSettings.refreshLocalizedTexts();
    serverSettings.refreshLocalizedTexts();
    notifyListeners();
  }

  // ── Start-up ───────────────────────────────────────────────────────────────────────────────────

  /// Loads the local cache, then reconnects to the server if it is the library source.
  Future<void> start() async {
    try {
      await library.initialize();
      await _applyPreferences();
      await session.initialize();
      serverSettings.syncWithSession();
    } catch (e, s) {
      WiretuneLog.error('MainViewModel', 'Start-up failed: $e', e, s);
      statusText = Localizer.format('StartupError', ['$e']);
      isStarting = false;
      notifyListeners();
      return;
    }
    // The cached library is usable now; the server connection below may take a while.
    isStarting = false;
    _updateStatusText();

    if (session.source == LibrarySource.server || session.source == LibrarySource.hybrid) await session.connect();

    isLoginViewActive =
        (session.source == LibrarySource.none && library.tracks.isEmpty) ||
        (session.source == LibrarySource.server &&
            (session.state == ServerConnectionState.loginRequired ||
                session.state == ServerConnectionState.setupRequired));
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
    player.dispose();
    tracks.dispose();
    albums.dispose();
    artists.dispose();
    playlists.dispose();
    favorites.dispose();
    audioSettings.dispose();
    serverSettings.dispose();
    search.dispose();
    unawaited(audioEngine.dispose());
    session.dispose();
    _onlineLyrics?.close();
    super.dispose();
  }
}
