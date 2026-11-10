// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'app_section.dart';
import 'downloads_view_model.dart';
import 'friends_view_model.dart';
import 'library_view_models.dart';
import 'lyrics_view_model.dart';
import 'player_view_model.dart';
import '../connect_link.dart';
import '../update_installer.dart';
import 'search_view_model.dart';
import 'settings_view_models.dart';
import 'update_view_model.dart';

/// What the device the app runs on can do; decided once at start-up.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.supportsLocalFolder = false,
    this.requestFolderAccess,
    this.kind = DeviceKind.desktop,
    this.name = '',
    this.mobileData,
  });

  /// Scanning a folder of the device's own (desktop, Android phones).
  final bool supportsLocalFolder;

  /// Asks for the permission to read that folder (Android), true when given; null when there is nothing to ask.
  final Future<bool> Function()? requestFolderAccess;

  /// What the other players of the account see this one as, and the name it has until the user gives it another.
  final DeviceKind kind;
  final String name;

  /// Whether the device is on mobile data, now and whenever that changes (phones and tablets); null where it never is.
  final Stream<bool>? mobileData;
}

/// A short message that needs no answer: a change that wasn't made, one the server turned down, something that went
/// through. The app shows the latest for a few seconds.
class AppNotice {
  const AppNotice(this.message, {this.isError = false, this.undo, this.action});

  final String message;
  final bool isError;

  /// Takes back what the notice tells of: its Undo button is there when this is.
  final VoidCallback? undo;

  /// A button of its own instead (Join): its label, and what it does.
  final (String, VoidCallback)? action;
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
    UpdateCheck? updateCheck,
    UpdateInstaller? updateInstaller,
    UpnpClient? upnp,
    Future<void> Function({String? relaunch})? quit,
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

    together = ListenTogether(this.remote);
    streamers = upnp == null ? null : Streamers(this.remote, session, library, upnp);
    player = PlayerViewModel(audioEngine, library)
      ..attachRemote(this.remote)
      ..attachListenTogether(together);
    lyrics = LyricsViewModel(player, own: _ownLyrics, online: onlineLyrics?.find);

    tracks = TrackListViewModel.allTracks(library, player);
    albums = AlbumsViewModel(library, player)..onNavWave = triggerNavWave;
    artists = ArtistsViewModel(library, player, artistPictures)..onNavWave = triggerNavWave;
    blends = Blends(session, this.remote);
    playlists = PlaylistsViewModel(library, player, blends: blends)..onNavWave = triggerNavWave;
    favorites = TrackListViewModel.favorites(library, player);
    downloads = DownloadsViewModel(this.downloadService);
    audioSettings = AudioSettingsViewModel(audioEngine);
    serverSettings = ServerSettingsViewModel(
      library,
      session,
      supportsLocalFolder: capabilities.supportsLocalFolder,
      requestFolderAccess: capabilities.requestFolderAccess,
    );
    search = SearchViewModel(library, player, () => playlists.allPlaylists);
    friends = FriendsViewModel(
      session,
      library,
      Recommendations(session, library, this.remote),
      together,
      blends,
      PlaylistInvites(session, this.remote),
      notify: (message, {isError = false, undo}) => showNotice(message, isError: isError, undo: undo),
    );
    updates = UpdateViewModel(
      updateCheck,
      updateInstaller,
      isOffline: () => session.isOfflineMode,
      notify: (message, {isError = false}) => showNotice(message, isError: isError),
      quit: quit ?? ({relaunch}) async {},
    );

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
      this.remote.accountChanged.listen((_) => unawaited(session.refreshCurrentUser())),
      // The server found new music: it shows here without a restart.
      this.remote.libraryChanged.listen((_) => unawaited(session.refreshLibrary())),
      // Listening together: who joined, an invite, the end, and what the others asked for.
      together.changed.listen((_) => _onListeningChanged()),
      together.ended.listen((_) => showNotice(Localizer.get('ListenEnded'))),
      player.leftForOwnMusic.listen((_) => showNotice(Localizer.get('ListenLeft'))),
      player.castHere.listen((account) => showNotice(Localizer.format('CastHere', [account.username]))),
      player.listenerQueued.listen((queued) {
        final (from, tracks) = queued;
        final what = tracks.length == 1 ? tracks.single.title : Localizer.format('TrackCount', [tracks.length]);
        showNotice(Localizer.format('ListenQueued', [from, what]));
      }),
    ]);

    _updateStatusText();
  }

  final WiretuneAudioEngine audioEngine;
  final LibraryService library;
  final ServerSession session;
  final DownloadService downloadService;
  final RemoteClient remote;

  /// Listening together with players of other accounts.
  late final ListenTogether together;
  final DeviceCapabilities capabilities;
  final OnlineLyrics? _onlineLyrics;
  final ArtistPictureService? _artistPictures;
  final List<void Function()> _unsubscribers = [];
  bool _disposed = false;

  late final PlayerViewModel player;
  late final LyricsViewModel lyrics;
  late final TrackListViewModel tracks;
  late final AlbumsViewModel albums;
  late final ArtistsViewModel artists;
  late final PlaylistsViewModel playlists;
  late final TrackListViewModel favorites;
  late final DownloadsViewModel downloads;
  late final AudioSettingsViewModel audioSettings;
  late final ServerSettingsViewModel serverSettings;
  late final SearchViewModel search;
  late final UpdateViewModel updates;
  late final FriendsViewModel friends;

  /// The account's Blends: playlists the server mixes from its listening and a friend's.
  late final Blends blends;

  /// The streamers on the network (UPnP renderers) among the devices to play on; null where they can't be looked for.
  late final Streamers? streamers;

  /// Looks for streamers on the network again (the devices menu opened).
  void searchStreamers() => unawaited(streamers?.search());

  /// What the app shows the user for a few seconds ([showNotice]).
  final Event<AppNotice> notices = Event<AppNotice>();

  void showNotice(String message, {bool isError = false, VoidCallback? undo, (String, VoidCallback)? action}) =>
      notices.emit(AppNotice(message, isError: isError, undo: undo, action: action));

  // ── Listening together ─────────────────────────────────────────────────────────────────────────

  Set<String> _listeners = const {};
  Set<String> _invitedTo = const {};

  void _onListeningChanged() {
    final group = together.group;
    final listeners = {for (final member in group?.members ?? const <ListeningDevice>[]) member.deviceId};
    if (together.isHost) {
      for (final member in group!.members) {
        if (!_listeners.contains(member.deviceId)) showNotice(Localizer.format('ListenJoined', [member.username]));
      }
    }
    _listeners = listeners;
    final invites = together.invites;
    for (final invite in invites) {
      if (_invitedTo.contains(invite.groupId) || invite.groupId == group?.id) continue;
      showNotice(
        Localizer.format('ListenInvitedYou', [invite.host.username]),
        action: (Localizer.get('ListenJoin'), () => together.join(invite.groupId)),
      );
    }
    _invitedTo = {for (final invite in invites) invite.groupId};
  }

  // ── Navigation ─────────────────────────────────────────────────────────────────────────────────

  /// The section whose page is on show: the tab's own, or another's opened from it (an album opened on an artist's page
  /// shows under Artists, as in Spotify and TIDAL).
  AppSection _selectedSection = AppSection.artists;

  /// The tab the navigation has lit: the one the page on show was reached from.
  AppSection _selectedTab = AppSection.artists;

  /// Each tab's way back: the places under the one on show, the latest last. Back goes to the last; the tab chosen again
  /// drops them and shows its list.
  final Map<AppSection, List<_Place>> _under = {};

  /// Each tab's place on show when another tab was chosen, shown again when it is chosen again.
  final Map<AppSection, _Place> _left = {};

  // The tabs the user came from, the latest last; the tab that is open is never in it. Back from a tab's list walks it
  // backwards.
  final List<AppSection> _tabHistory = [];

  int waveTrigger = 0;
  NavWaveDirection lastWaveDirection = NavWaveDirection.leftToRight;

  AppSection get selectedSection => _selectedSection;
  AppSection get selectedTab => _selectedTab;

  /// Shows [section]'s page: its list, or the page open over it. The tab stays as it is.
  void _showSection(AppSection section) {
    if (_selectedSection == section) return;
    player.closeQueue();
    final previous = _selectedSection;
    _selectedSection = section;
    // The wave runs downwards to a section drawn below the one left, upwards to one above it.
    triggerNavWave(
      navVisualOrder(section) > navVisualOrder(previous) ? NavWaveDirection.leftToRight : NavWaveDirection.rightToLeft,
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

  /// A tab (a section of the sidebar) as TIDAL's and Spotify's: another one shows as it was left, with the page that was
  /// open in it and the way back from there; the one on show chosen again goes from any page back to its list, and from
  /// the list to its top.
  void navigateTo(AppSection section) {
    final searching = isSearchOpen;
    searchQuery = '';
    isSearchOpen = false;
    // The automatic playlists follow what was played since.
    if (section == AppSection.playlists) playlists.refreshPlaylists();
    if (section != _selectedTab) return _switchTab(section, remember: true);
    if (searching) return;
    final atList = _selectedSection == section && _openPageOf(section) == null && (_under[section]?.isEmpty ?? true);
    if (atList) return scrollToTopRequested.emit(null);
    _under[section]?.clear();
    _restore(_Place(section, null));
  }

  /// Shows [tab] as it was left; [remember]ing the tab left, for Back.
  void _switchTab(AppSection tab, {required bool remember}) {
    _left[_selectedTab] = _placeNow();
    final previous = _selectedTab;
    _selectedTab = tab;
    if (remember) _rememberTab(previous, tab);
    _restore(_left.remove(tab) ?? _Place(tab, null), wave: null);
    notifyListeners();
  }

  /// The album, artist or playlist open over [section]'s list; null when its list is up.
  Object? _openPageOf(AppSection section) => switch (section) {
    AppSection.albums => albums.selectedAlbum,
    AppSection.artists => artists.selectedArtist,
    AppSection.playlists => playlists.selectedPlaylist,
    _ => null,
  };

  /// Where the user is now in the tab: the section on show and its page; [after] is what comes back over it (the search
  /// it was left from, a sheet), [title] what Back is called on the way to it.
  _Place _placeNow({VoidCallback? after, String Function()? title}) =>
      _Place(_selectedSection, _openPageOf(_selectedSection), after: after, title: title);

  /// Shows [place] of the tab on show: its section, and its page as the library has it now (its list, when the page is
  /// gone), with Back leading to the place under it. [wave] runs the navigation's wave that way.
  void _restore(_Place place, {NavWaveDirection? wave = NavWaveDirection.rightToLeft}) {
    final under = _under[_selectedTab];
    final back = under == null || under.isEmpty ? null : under.last;
    final backText = back?.title;
    final onReturn = back == null ? null : _back;
    switch (place.section) {
      case AppSection.albums:
        final album = place.page is Album ? library.getAlbum((place.page as Album).id) : null;
        albums.showPage(album, backText, onReturn, wave);
      case AppSection.artists:
        final artist = place.page is Artist ? library.getArtist((place.page as Artist).id) : null;
        artists.showPage(artist, backText, onReturn, wave);
      case AppSection.playlists:
        final playlist = place.page is Playlist ? library.getPlaylist((place.page as Playlist).id) : null;
        playlists.showPage(playlist, backText, onReturn, wave);
      default:
        break;
    }
    _showSection(place.section);
    place.after?.call();
    notifyListeners();
  }

  /// Back from the page on show to the place under it in the tab: the page it was opened from, the list, the search.
  void _back() {
    final under = _under[_selectedTab];
    if (under == null || under.isEmpty) return;
    final place = under.removeLast();
    // Into another section or the search, as a page opened from there: at once, the cover's flight the way between.
    if (place.section != _selectedSection || place.after != null) jumps++;
    _restore(place);
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
      // A page closes; Back then goes on to the place it was opened from in the tab, if any.
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

    // A list over places in its tab (the one a page was opened from): back to them.
    if (_under[_selectedTab]?.isNotEmpty ?? false) return _back;

    // Back from a tab's list goes to the tab the user came from, shown as it was left.
    if (_tabHistory.isNotEmpty) return () => _switchTab(_tabHistory.removeLast(), remember: false);
    return null;
  }

  // ── Opening albums, artists and playlists from anywhere ────────────────────────────────────────

  /// The listening summary is to open again over Playlists: Back returned from a page opened in it.
  bool wantsListeningSummary = false;

  /// How many times a page was opened from another section or the search, or back went from it to there. The wide
  /// layout shows such a jump at once, as a page opened or left within a section, the cover's flight being the way
  /// between the two: a cross-fade would show the page left as it closes, and send its cover flying back to a list.
  /// (The phone's pages change at once anyway.)
  int jumps = 0;

  /// Opens a page of [section] (an album's, an artist's, a playlist's) with [open], over the place the user is at in the
  /// tab, which Back then leads to: the page or list on show, or the search's results. [reopen] is what comes back
  /// over that place on the way back (the sheet the page was opened from).
  void _openPage(
    AppSection section,
    void Function(String Function()? backText, void Function()? onReturn) open, {
    VoidCallback? reopen,
  }) {
    final query = _searchQuery;
    final fromSearch = _isSearchActive;
    // A search that led somewhere is one to remember.
    if (fromSearch) search.rememberQuery();
    final place = _placeNow(
      after: fromSearch
          ? () {
              _searchQuery = '';
              searchQuery = query;
              isSearchActive = true;
            }
          : reopen,
      title: fromSearch ? () => Localizer.get('Search') : null,
    );
    (_under[_selectedTab] ??= []).add(place);
    if (section != _selectedSection || fromSearch) jumps++;
    open(place.title, _back);
    isNowPlayingOpen = false;
    isSearchActive = false;
    _showSection(section);
    notifyListeners();
  }

  /// Opens [album]'s page over the place the user is at; [reopen] comes back over that place on the way back.
  void openAlbum(Album? album, {VoidCallback? reopen}) {
    if (album == null) return;
    _openPage(
      AppSection.albums,
      (backText, onReturn) => albums.openAlbumWithOrigin(album, backText, onReturn),
      reopen: reopen,
    );
  }

  void openAlbumOfTrack(Track? track) {
    if (track != null) openAlbum(library.getAlbumForTrack(track));
  }

  void openArtist(Artist? artist, {VoidCallback? reopen}) {
    if (artist == null) return;
    _openPage(
      AppSection.artists,
      (backText, onReturn) => artists.openArtistWithOrigin(artist, backText, onReturn),
      reopen: reopen,
    );
  }

  void openPlaylist(Playlist? playlist) {
    if (playlist == null) return;
    _openPage(
      AppSection.playlists,
      (backText, onReturn) => playlists.openPlaylistWithOrigin(playlist, backText, onReturn),
    );
  }

  /// Opens what the queue was played from ([PlayerViewModel.playingSource]): its album, artist or playlist, or its page
  /// of tracks.
  void openPlayingSource() {
    switch (player.playingSource) {
      case final Album album:
        openAlbum(library.getAlbum(album.id) ?? album);
      case final Artist artist:
        openArtistByName(artist.name);
      case final Playlist playlist:
        openPlaylist(library.getPlaylist(playlist.id));
      case final AppSection section:
        closeNowPlaying();
        navigateTo(section);
    }
  }

  void openArtistByName(String? artistName, {VoidCallback? reopen}) {
    if (artistName != null && artistName.trim().isNotEmpty) {
      openArtist(library.getArtistByName(artistName), reopen: reopen);
    }
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

  /// Counts the links from a QR code that opened the app ([openConnectLink]): the sign-in screen is built anew for each,
  /// with the address it brought.
  int connectLinks = 0;

  /// A QR code's link opened the app ([ConnectLink]): the sign-in screen with the [link]'s server in it, connecting; with
  /// a one-time code, signed in to the account that showed it, which closes the screen.
  Future<void> openConnectLink(({String server, String? code}) link) async {
    final server = serverSettings;
    final same = ServerSession.normalizeServerUrl(link.server)?.toLowerCase() == session.serverUrl.toLowerCase();
    if (link.code == null && same && session.isLoggedIn) return;
    server.serverUrl = link.server;
    connectLinks++;
    _isLoginViewActive = true;
    notifyListeners();
    final code = link.code;
    await (code == null ? server.connectServer() : server.loginWithCode(code));
  }

  /// Signs out, and removes the downloads: they are copies of the account's server.
  Future<void> logout() async {
    player.releaseRemote();
    await serverSettings.logout();
    downloadService.removeAll();
    isLoginViewActive = library.tracks.isEmpty;
    notifyListeners();
  }

  void _onSessionStateChanged() {
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
  static const String _sidebarPinnedPreference = 'sidebar_pinned';
  static const String _sidebarOpenedPreference = 'sidebar_opened';
  static const String _performanceStatsPreference = 'show_performance_stats';
  static const String _onlineLyricsPreference = 'online_lyrics';
  static const String _remoteIdPreference = 'remote_device_id';
  static const String _remoteNamePreference = 'remote_device_name';
  static const String _remoteEnabledPreference = 'remote_enabled';
  static const String _remoteSharingPreference = 'remote_sharing';
  static const String _normalizationPreference = 'volume_normalization';
  static const String _streamingQualityPreference = 'streaming_quality';

  /// The quality on mobile data, a [StreamingQuality]'s name; none until it was chosen.
  static const String _mobileQualityPreference = 'mobile_streaming_quality';
  static const String _equalizerPreference = 'equalizer';
  static const String _equalizerOnPreference = 'equalizer_on';
  static const String _gaplessPreference = 'gapless';
  static const String _autoplayPreference = 'autoplay';
  static const String _updateCheckPreference = 'update_check';

  WiretuneTheme _theme = WiretuneTheme.airy;
  bool _showPerformanceStats = false;

  WiretuneTheme get theme => _theme;

  void setTheme(WiretuneTheme theme, {bool persist = true}) {
    _theme = theme;
    if (persist) _remember(_themePreference, theme.name);
    notifyListeners();
  }

  bool _isSidebarPinned = false;
  bool _hasOpenedSidebar = false;

  /// A computer's hidden sidebar has been out once: the chevron at the window's edge has done its job and keeps still,
  /// from then on.
  bool get hasOpenedSidebar => _hasOpenedSidebar;
  void sidebarOpened() {
    if (_hasOpenedSidebar) return;
    _hasOpenedSidebar = true;
    _remember(_sidebarOpenedPreference, '1');
    notifyListeners();
  }

  /// A computer's sidebar stays beside the page; unpinned (the default) it is out of sight until the mouse comes to the
  /// window's left edge, and then over the page.
  bool get isSidebarPinned => _isSidebarPinned;
  set isSidebarPinned(bool value) {
    _isSidebarPinned = value;
    _remember(_sidebarPinnedPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// Frame graphs drawn over the app, for tuning performance; off until the user turns them on.
  bool get showPerformanceStats => _showPerformanceStats;
  set showPerformanceStats(bool value) {
    _showPerformanceStats = value;
    _remember(_performanceStatsPreference, value ? '1' : '0');
    notifyListeners();
  }

  /// Whether the player looks for a newer release on GitHub, at start and once a day; on by default.
  bool get checkForUpdates => updates.isEnabled;
  set checkForUpdates(bool value) {
    updates.isEnabled = value;
    _remember(_updateCheckPreference, value ? '1' : '0');
    notifyListeners();
    if (value) unawaited(updates.checkNow());
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

  Equalizer _equalizer = Equalizer.flat();
  bool _isEqualizerOn = false;

  /// The equalizer's bands, as the listener set them (they stay when it is switched off).
  Equalizer get equalizer => _equalizer;

  /// Whether the equalizer filters the sound; off by default. Bit-perfect output never uses it.
  bool get isEqualizerOn => _isEqualizerOn;
  set isEqualizerOn(bool value) {
    _isEqualizerOn = value;
    _remember(_equalizerOnPreference, value ? '1' : '0');
    _applyEqualizer();
  }

  /// Sets the band at [index] to [gainDb]; [save] is false while a slider is still being dragged.
  void setEqualizerBand(int index, double gainDb, {bool save = true}) {
    final gains = _equalizer.gains;
    if (index < 0 || index >= gains.length) return;
    gains[index] = gainDb;
    _setEqualizer(Equalizer.fromGains(gains), save: save);
  }

  /// Puts one of [Equalizer.presets] in, and switches the equalizer on for it.
  void setEqualizerPreset(String name) {
    final gains = Equalizer.presets[name];
    if (gains == null) return;
    _setEqualizer(Equalizer.fromGains(gains), save: true);
    if (!_isEqualizerOn && name != 'flat') isEqualizerOn = true;
  }

  void _setEqualizer(Equalizer value, {required bool save}) {
    _equalizer = value;
    if (save) _remember(_equalizerPreference, value.toJson());
    _applyEqualizer();
  }

  void _applyEqualizer() {
    audioEngine.setEqualizer(_isEqualizerOn ? _equalizer : Equalizer.flat());
    audioSettings.refreshDeviceList(); // the signal path mentions it
    notifyListeners();
  }

  /// How much of a server track is asked for (on Wi-Fi, where there is mobile data): the file (the default), or the
  /// server's Opus conversion for a slow link.
  StreamingQuality get streamingQuality => _streamingQuality;
  StreamingQuality _streamingQuality = StreamingQuality.original;
  set streamingQuality(StreamingQuality value) {
    _streamingQuality = value;
    _remember(_streamingQualityPreference, value.name);
    _applyStreamingQuality();
  }

  /// Whether the device can be on mobile data, and has a quality of its own there ([mobileStreamingQuality]).
  bool get hasMobileData => capabilities.mobileData != null;

  /// The quality on mobile data; the Wi-Fi one ([streamingQuality]) until it is chosen.
  StreamingQuality get mobileStreamingQuality => _mobileQuality ?? _streamingQuality;
  StreamingQuality? _mobileQuality;

  /// Whether the quality on mobile data was chosen (in Settings, or when asked); until it is, the first time the device
  /// streams over mobile data asks ([asksMobileQuality]).
  bool get _mobileQualityChosen => _mobileQuality != null;
  set mobileStreamingQuality(StreamingQuality value) {
    _mobileQuality = value;
    asksMobileQuality = false;
    _remember(_mobileQualityPreference, value.name);
    _applyStreamingQuality();
  }

  bool _onMobileData = false;
  StreamSubscription<bool>? _mobileData;

  /// The device is on mobile data for the first time, with music from a server: the app asks which quality to stream
  /// there ([mobileStreamingQuality] answers, [skipMobileQuality] asks again at the next start).
  bool asksMobileQuality = false;

  void skipMobileQuality() {
    asksMobileQuality = false;
    notifyListeners();
  }

  void _followMobileData(bool mobile) {
    _onMobileData = mobile;
    if (mobile && !_mobileQualityChosen && session.usesServer && !session.isOfflineMode) asksMobileQuality = true;
    _applyStreamingQuality();
  }

  /// The engine streams in the quality of the network the device is on.
  void _applyStreamingQuality() {
    unawaited(audioEngine.setStreamingQuality(_onMobileData ? mobileStreamingQuality : _streamingQuality));
    audioSettings.refreshDeviceList(); // the signal path mentions it
    notifyListeners();
  }

  /// Autoplay (similar music after the queue's end); on by default.
  bool get isAutoplayEnabled => player.isAutoplayEnabled;
  set isAutoplayEnabled(bool value) {
    player.isAutoplayEnabled = value;
    _remember(_autoplayPreference, value ? '1' : '0');
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

  /// Whether other accounts on the server may play music here (cast to this player), and which: by default only music
  /// this account doesn't hide, and none on a phone. An account that blocks this one, or that this one blocks, never
  /// can.
  DeviceSharing get deviceSharing => remote.sharing;
  set deviceSharing(DeviceSharing value) {
    if (value == remote.sharing) return;
    _configureRemote(sharing: value);
    _remember(_remoteSharingPreference, value.name);
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

  void _configureRemote({String? id, String? name, bool? enabled, DeviceSharing? sharing}) {
    remote.configure(
      id: id ?? remote.deviceId,
      name: name ?? remote.deviceName,
      kind: capabilities.kind,
      enabled: enabled ?? remote.isEnabled,
      sharing: sharing ?? remote.sharing,
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

    // Airy unless Dark was picked (an earlier version's light theme too).
    _theme = WiretuneTheme.values.asNameMap()[library.getPreference(_themePreference)] ?? WiretuneTheme.airy;

    _showPerformanceStats = library.getPreference(_performanceStatsPreference) == '1';
    _isSidebarPinned = library.getPreference(_sidebarPinnedPreference) == '1';
    _hasOpenedSidebar = library.getPreference(_sidebarOpenedPreference) == '1';
    lyrics.isOnlineEnabled = library.getPreference(_onlineLyricsPreference) != '0'; // on unless turned off
    updates.isEnabled = library.getPreference(_updateCheckPreference) != '0'; // on unless turned off
    final normalization = VolumeNormalization.values.asNameMap()[library.getPreference(_normalizationPreference)];
    if (normalization != null) audioEngine.setNormalization(normalization);
    _equalizer = Equalizer.fromJson(library.getPreference(_equalizerPreference));
    _isEqualizerOn = library.getPreference(_equalizerOnPreference) == '1';
    audioEngine.setEqualizer(_isEqualizerOn ? _equalizer : Equalizer.flat());
    final qualities = StreamingQuality.values.asNameMap();
    _streamingQuality = qualities[library.getPreference(_streamingQualityPreference)] ?? StreamingQuality.original;
    _mobileQuality = qualities[library.getPreference(_mobileQualityPreference)];
    unawaited(audioEngine.setStreamingQuality(_streamingQuality));
    player.isGaplessEnabled = library.getPreference(_gaplessPreference) != '0'; // on unless turned off
    player.isAutoplayEnabled = library.getPreference(_autoplayPreference) != '0'; // on unless turned off

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
      sharing: switch (library.getPreference(_remoteSharingPreference)) {
        // A phone goes everywhere with its owner: nobody else plays on it until they let them.
        null => capabilities.kind == DeviceKind.phone ? DeviceSharing.off : DeviceSharing.unhidden,
        final saved => DeviceSharing.parse(saved),
      },
    );
  }

  void _refreshLocalizedTexts() {
    _onSessionStateChanged();
    tracks.refresh();
    albums.refreshLocalizedTexts();
    artists.refreshLocalizedTexts();
    player.refreshLocalizedTexts();
    lyrics.refreshLocalizedTexts();
    playlists.refreshLocalizedTexts();
    favorites.refresh();
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
  /// take back. [reopen] opens again the page the hiding closed, so the Undo leads back to where the user was.
  void hide(HiddenKind kind, String id, String name, {VoidCallback? reopen}) {
    library.setHidden(kind, id, true);
    // Offline, an account's music can't change, and the library says why itself.
    if (!library.hidden(kind).contains(id)) return;
    showNotice(
      Localizer.format('HiddenNotice', [name]),
      undo: () {
        library.setHidden(kind, id, false);
        reopen?.call();
      },
    );
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
    updates.start();

    if (session.usesServer) await session.connect();
    _mobileData = capabilities.mobileData?.listen(_followMobileData);

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
    unawaited(_mobileData?.cancel());
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
    updates.dispose();
    friends.dispose();
    unawaited(audioEngine.dispose());
    together.dispose();
    streamers?.dispose();
    blends.dispose();
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

/// A place in a tab: a section, with the album, artist or playlist open over its list ([page]; null for the list); what
/// comes back over it when Back returns there ([after]: the search it was left from, a sheet); and what Back calls it.
class _Place {
  _Place(this.section, this.page, {this.after, String Function()? title}) : title = title ?? _titleOf(section, page);

  final AppSection section;
  final Object? page;
  final VoidCallback? after;
  final String Function() title;

  static String Function() _titleOf(AppSection section, Object? page) => switch (page) {
    final Album album => () => album.title,
    final Artist artist => () => artist.name,
    final Playlist playlist => () => playlist.name,
    _ => () => Localizer.get(switch (section) {
      AppSection.artists => 'NavArtists',
      AppSection.albums => 'NavAlbums',
      AppSection.tracks => 'NavTracks',
      AppSection.favorites => 'NavFavorites',
      AppSection.playlists => 'NavPlaylists',
      AppSection.settings => 'NavSettings',
    }),
  };
}
