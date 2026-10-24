// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/library_view_models.dart';
import '../view_models/main_view_model.dart';
import '../view_models/player_view_model.dart';
import 'badges.dart';
import 'buttons.dart';
import 'cover_flight.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'page_parts.dart';
import 'player_controls.dart';

/// An album: cover (with its format on it), title, artist, track count and release year, and a play button.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, required this.onOpen, required this.onPlay, this.withArtist = true});

  final Album album;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  /// Whether its menu leads to the album's artist ([ListMenu.album]).
  final bool withArtist;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final purple = colors.palette.purple;
    final cover = CoverImage(
      path: album.coverArtPath,
      radius: Radii.medium,
      placeholderIcon: Icons.album,
      placeholderColor: purple,
    );
    final details = [
      context.trf('TrackCount', [album.trackCount]),
      if (album.releaseYear != null) '${album.releaseYear}',
    ].join('  •  ');
    final menu = ListMenu.album(album, onPlay: onPlay, withArtist: withArtist);
    return _DesktopTile(
      accent: purple,
      onTap: onOpen,
      onSecondaryTap: (position) => menu.showAt(context, position),
      onLongPress: () => menu.preview(
        context,
        cover: albumPreviewCover(context, album),
        title: album.title,
        subtitle: album.artist,
        onOpen: onOpen,
      ),
      flightTag: 'album:${album.id}',
      menu: menu.coverButton(context),
      cover: cover,
      lines: [
        _line(album.title, 14, FontWeight.w700, colors.textMain),
        _line(album.artist, 12.5, FontWeight.w500, colors.textMuted),
        _line(details, 11, FontWeight.w500, colors.textMuted),
      ],
      badge: QualityTag(tier: album.quality.tier, spec: album.quality.spec),
      play: TilePlayButton(color: purple, onPressed: onPlay, tracks: album.tracks),
    );
  }
}

/// An artist: round picture, name, track count and a play button.
class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist, required this.onOpen, required this.onPlay});

  final Artist artist;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final coral = colors.palette.coral;
    final picture = CoverImage(
      path: artist.picturePath,
      circle: true,
      placeholderIcon: Icons.person,
      placeholderColor: coral,
    );
    final menu = ListMenu.artist(artist, onPlay: onPlay);
    return _DesktopTile(
      accent: coral,
      onTap: onOpen,
      onSecondaryTap: (position) => menu.showAt(context, position),
      onLongPress: () => menu.preview(
        context,
        cover: artistPreviewPicture(context, artist),
        round: true,
        title: artist.name,
        subtitle: artistCounts(context, artist),
        onOpen: onOpen,
      ),
      flightTag: 'artist:${artist.id}',
      menu: menu.coverButton(context),
      circle: true,
      cover: picture,
      lines: [
        _line(artist.name, 14, FontWeight.w700, colors.textMain, center: true),
        _line(artistCounts(context, artist), 12.5, FontWeight.w500, colors.textMuted, center: true),
      ],
      play: TilePlayButton(color: coral, onPressed: onPlay, tracks: artist.tracks),
    );
  }
}

/// An album's cover as large as a preview shows it.
Widget albumPreviewCover(BuildContext context, Album album) => CoverImage(
  path: album.coverArtPath,
  radius: Radii.card,
  decodeWidth: 640,
  placeholderIcon: Icons.album,
  placeholderColor: context.colors.palette.purple,
);

/// An artist's picture as large as a preview shows it.
Widget artistPreviewPicture(BuildContext context, Artist artist) => CoverImage(
  path: artist.picturePath,
  circle: true,
  decodeWidth: 640,
  placeholderIcon: Icons.person,
  placeholderColor: context.colors.palette.coral,
);

/// How many albums and tracks an artist has, as its tile and its row say it.
String artistCounts(BuildContext context, Artist artist) =>
    '${context.trf('AlbumCount', [artist.albumCount])}  •  ${context.trf('TrackCount', [artist.trackCount])}';

enum _ListAction { play, shuffle, playNext, addToQueue, addToPlaylist, download, openArtist, remove }

/// The menu of an album, an artist or a playlist: on its tile (the ⋮ on the cover, or a right click), its phone row (the
/// ⋮) and its page's header (the ⋮ beside play, shuffle, the download and the playlist, which it then leaves out). Play, shuffle, the
/// queue's two, a playlist, the download (when a track of it can be), an album's way to its artist (whose name is no
/// link on a tile or a row), and hiding it (deleting a playlist).
class ListMenu {
  ListMenu._(
    this.tracks, {
    required this.flightTag,
    required this.name,
    required this.label,
    required this.downloadable,
    required this.onPlay,
    required this.isDownloaded,
    required this.onDownload,
    this.artist,
    this.removeKey,
    this.removeIcon = Icons.delete_outline_rounded,
    this.onRemove,
    this.removeIsDanger = false,
  });

  /// [withArtist]: the menu leads to the album's (first) artist, except on that artist's page.
  factory ListMenu.album(Album album, {required VoidCallback onPlay, bool withArtist = true}) => ListMenu._(
    album.tracks,
    flightTag: 'album:${album.id}',
    name: album.title,
    label: '${album.title} • ${album.artist}',
    downloadable: album.tracks,
    onPlay: onPlay,
    isDownloaded: (vm) => vm.downloads.isAlbumDownloaded(album),
    onDownload: (vm) => vm.downloads.toggleAlbum(album),
    artist: withArtist ? album.artistNames.first : null,
    removeKey: 'HideAlbum',
    removeIcon: Icons.visibility_off_outlined,
    onRemove: (context) {
      final vm = context.vm;
      vm.library.setHidden(HiddenKind.album, album.id, true);
      if (vm.albums.selectedAlbum?.id == album.id) vm.albums.closeAlbumDetail();
    },
  );

  factory ListMenu.artist(Artist artist, {required VoidCallback onPlay}) => ListMenu._(
    artist.tracks,
    flightTag: 'artist:${artist.id}',
    name: artist.name,
    label: artist.name,
    // The download keeps the artist's albums, as the button on its page does.
    downloadable: [for (final album in artist.albums) ...album.tracks],
    onPlay: onPlay,
    isDownloaded: (vm) => vm.downloads.isArtistDownloaded(artist),
    onDownload: (vm) => vm.downloads.toggleArtist(artist),
    removeKey: 'HideArtist',
    removeIcon: Icons.visibility_off_outlined,
    onRemove: (context) {
      final vm = context.vm;
      vm.library.setHidden(HiddenKind.artist, artist.id, true);
      if (vm.artists.selectedArtist?.id == artist.id) vm.artists.closeArtistDetail();
    },
  );

  /// An automatic playlist (most played, recently played) can't be downloaded or deleted.
  factory ListMenu.playlist(Playlist playlist, List<Track> tracks, {required VoidCallback onPlay}) => ListMenu._(
    tracks,
    flightTag: 'playlist:${playlist.id}',
    name: playlist.name,
    label: playlist.name,
    downloadable: playlist.isAutomatic ? const [] : tracks,
    onPlay: onPlay,
    isDownloaded: (vm) => vm.downloads.isPlaylistDownloaded(playlist),
    onDownload: (vm) => vm.downloads.togglePlaylist(playlist),
    removeKey: playlist.isAutomatic ? null : 'PlaylistDeleteAction',
    removeIsDanger: true,
    // Asked first.
    onRemove: (context) => confirmDeletePlaylist(context, playlist),
  );

  /// What playing, shuffling, queueing and a playlist take.
  final List<Track> tracks;

  /// What its cover shows ([CoverFlight]): queued, it flies into the player's.
  final String flightTag;

  /// What a notice calls it (its title or name), and what the playlist dialog does (with the album's artist).
  final String name;
  final String label;
  final List<Track> downloadable;
  final VoidCallback onPlay;
  final bool Function(MainViewModel vm) isDownloaded;
  final void Function(MainViewModel vm) onDownload;

  /// The artist "Go to artist" opens; null leaves it out.
  final String? artist;
  final String? removeKey;
  final IconData removeIcon;
  final bool removeIsDanger;
  final void Function(BuildContext context)? onRemove;

  /// [header]: the page's header has play, shuffle, the download and the playlist as buttons of their own.
  List<PopupMenuEntry<_ListAction>> _items(BuildContext context, {bool header = false}) {
    final vm = context.vm;
    final colors = context.colors;
    PopupMenuItem<_ListAction> item(_ListAction action, IconData icon, String text, {Color? color}) => PopupMenuItem(
      value: action,
      enabled: tracks.isNotEmpty || action == _ListAction.remove,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? colors.textMuted),
          const SizedBox(width: 14),
          Flexible(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
    final downloaded = isDownloaded(vm);
    return [
      if (!header) ...[
        item(_ListAction.play, Icons.play_arrow_rounded, context.tr('Play')),
        item(_ListAction.shuffle, Icons.shuffle_rounded, context.tr('Shuffle')),
      ],
      item(_ListAction.playNext, Icons.queue_play_next_rounded, context.tr('PlayNext')),
      item(_ListAction.addToQueue, Icons.add_to_queue_rounded, context.tr('AddToQueue')),
      // The page's header has it as a button of its own.
      if (!header) item(_ListAction.addToPlaylist, Icons.playlist_add_rounded, context.tr('TipAddToPlaylist')),
      if (!header && downloadable.any(vm.downloads.canDownload))
        item(
          _ListAction.download,
          downloaded ? Icons.download_done_rounded : Icons.download_rounded,
          context.tr(downloaded ? 'TipRemoveDownload' : 'TipDownload'),
        ),
      // The page's header has the artist's name as a link.
      if (!header && artist != null) item(_ListAction.openArtist, Icons.person_rounded, context.tr('GoToArtist')),
      if (removeKey case final key?)
        item(_ListAction.remove, removeIcon, context.tr(key), color: removeIsDanger ? colors.danger : null),
    ];
  }

  void _run(BuildContext context, _ListAction? action) {
    if (action == null || !context.mounted) return;
    final vm = context.vm;
    switch (action) {
      case _ListAction.play:
        onPlay();
      case _ListAction.shuffle:
        vm.player.shuffleQueue(tracks);
      case _ListAction.playNext:
        vm.queue(tracks, next: true, name: name);
        CoverFlight.toPlayer(flightTag);
      case _ListAction.addToQueue:
        vm.queue(tracks, next: false, name: name);
        CoverFlight.toPlayer(flightTag);
      case _ListAction.addToPlaylist:
        showAddToPlaylistDialog(context, tracks, label: label, suggestedName: name);
      case _ListAction.download:
        onDownload(vm);
      case _ListAction.openArtist:
        vm.openArtistByName(artist);
      case _ListAction.remove:
        onRemove?.call(context);
    }
  }

  Future<void> _show(BuildContext context, Offset position, {bool header = false}) async {
    final action = await showMenu<_ListAction>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: _items(context, header: header),
    );
    if (context.mounted) _run(context, action);
  }

  /// Opens the menu at [position] (a right click on a tile).
  Future<void> showAt(BuildContext context, Offset position) => _show(context, position);

  /// A long press's preview: [cover] large ([round]: an artist's), its [title] and [subtitle] and the whole menu under
  /// them, floating over the page, which blurs behind it. While the finger that pressed is still down, it can slide
  /// onto an entry and choose it by letting go there ([_PressSlide]); let go elsewhere, the preview stays. A tap on the
  /// cover then opens its page ([onOpen]), the cover flying there; a tap anywhere else but the menu closes it.
  Future<void> preview(
    BuildContext context, {
    required Widget cover,
    bool round = false,
    required String title,
    String? subtitle,
    required VoidCallback onOpen,
  }) async {
    var open = false;
    Widget card(BuildContext dialog, _PressSlide? slide) => _Preview(
      cover: cover,
      round: round,
      title: title,
      subtitle: subtitle,
      flightTag: flightTag,
      onOpen: () {
        open = true;
        Navigator.pop(dialog);
      },
      items: _items(dialog),
      slide: slide,
    );

    // While the finger is down, in the screen's overlay: a dialog (a route) would take the finger away.
    final overlay = Overlay.of(context, rootOverlay: true);
    final shown = AnimationController(vsync: overlay, duration: _previewDuration)..forward();
    final slide = _PressSlide();
    final held = OverlayEntry(
      builder: (overlayContext) => IgnorePointer(
        child: AnimatedBuilder(
          animation: shown,
          builder: (context, child) => ColoredBox(
            color: _previewBarrier.withValues(alpha: 0.3 * shown.value),
            child: child,
          ),
          child: _previewFrame(shown, card(overlayContext, slide)),
        ),
      ),
    );
    overlay.insert(held);
    final (chose, choice) = await slide.released;

    _ListAction? action = choice;
    if (chose) {
      // Chosen with the finger: away, and done.
      await shown.reverse();
      held.remove();
    } else {
      // Let go elsewhere: the preview stays, now as a dialog (Back closes it), already in place.
      final route = PageRouteBuilder<_ListAction>(
        opaque: false,
        barrierDismissible: true,
        barrierLabel: context.mounted ? MaterialLocalizations.of(context).modalBarrierDismissLabel : null,
        barrierColor: _previewBarrier.withValues(alpha: 0.3),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: _previewDuration,
        pageBuilder: (dialog, _, _) => card(dialog, null),
        transitionsBuilder: (context, animation, _, child) => _previewFrame(animation, child),
      );
      final result = context.mounted ? Navigator.of(context, rootNavigator: true).push(route) : null;
      WidgetsBinding.instance.addPostFrameCallback((_) => held.remove());
      action = await result;
    }
    held.dispose();
    shown.dispose();
    if (open) onOpen();
    if (context.mounted) _run(context, action);
  }

  static const Duration _previewDuration = Duration(milliseconds: 240);
  static const Color _previewBarrier = Colors.black;

  /// The preview coming in as [animation] runs: the page blurring behind it, the card fading in and growing to its size.
  static Widget _previewFrame(Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final blur = 14 * animation.value;
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: child,
        );
      },
      child: FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(curved), child: child),
      ),
    );
  }

  /// The ⋮ button of a phone row.
  Widget button(BuildContext context) => PopupMenuButton<_ListAction>(
    icon: Icon(Icons.more_vert_rounded, size: 20, color: context.colors.textMuted),
    tooltip: context.tr('TipMore'),
    onSelected: (action) => _run(context, action),
    itemBuilder: _items,
  );

  /// The ⋮ on a tile's cover: a dark disc, for the white dots to show on any cover.
  Widget coverButton(BuildContext context) => Tooltip(
    message: context.tr('TipMore'),
    child: Material(
      color: const Color(0x99000000),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: SizedBox.square(
        dimension: 32,
        child: PopupMenuButton<_ListAction>(
          tooltip: '',
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          onSelected: (action) => _run(context, action),
          itemBuilder: _items,
        ),
      ),
    ),
  );

  /// The header's button that puts the tracks into a playlist (taken out of its menu), beside the download.
  Widget addToPlaylistButton() => Builder(
    builder: (context) => HeaderIconButton(
      tooltip: context.tr('TipAddToPlaylist'),
      icon: Icons.playlist_add_rounded,
      onPressed: () => showAddToPlaylistDialog(context, tracks, label: label, suggestedName: name),
    ),
  );

  /// The ⋮ of a phone page's top bar ([PinnedTitleBar.menu]): the rest of the menu (play, shuffle, the download and the
  /// playlist are the header's), at hand however far the page is scrolled.
  Widget topBarButton() => Builder(
    builder: (context) => SizedBox.square(
      dimension: PinnedTitleBar.buttonSize,
      child: IconButton(
        tooltip: context.tr('TipMore'),
        onPressed: () {
          final box = context.findRenderObject()! as RenderBox;
          _show(context, box.localToGlobal(box.size.bottomLeft(Offset.zero)), header: true);
        },
        icon: Icon(Icons.more_vert_rounded, size: 24, color: context.colors.textMain),
      ),
    ),
  );

  /// The ⋮ of a page's header, beside play, shuffle and the download: the rest of the menu, opening below it. On a
  /// phone it is in the top bar instead ([topBarButton]).
  Widget headerButton() => Builder(
    builder: (context) => HeaderIconButton(
      tooltip: context.tr('TipMore'),
      icon: Icons.more_vert_rounded,
      onPressed: () {
        final box = context.findRenderObject()! as RenderBox;
        _show(context, box.localToGlobal(box.size.bottomLeft(Offset.zero)), header: true);
      },
    ),
  );
}

/// The card of [ListMenu.preview]: the cover, which opens its page, the names, and the menu's entries, which close it
/// with their choice. A tap on anything else closes it too.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.cover,
    required this.round,
    required this.title,
    required this.subtitle,
    required this.flightTag,
    required this.onOpen,
    required this.items,
    required this.slide,
  });

  final Widget cover;
  final bool round;
  final String title;
  final String? subtitle;
  final String flightTag;
  final VoidCallback onOpen;
  final List<PopupMenuEntry<_ListAction>> items;

  /// The finger still down from the long press, while it is.
  final _PressSlide? slide;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // A Material under it, for the app's text style: a dialog's page has none of its own.
    return Material(
      type: MaterialType.transparency,
      // The gaps between the cover, the names and the menu, and the names themselves, are the page's: a tap there
      // closes it, as one beside it does.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: round ? BoxShape.circle : BoxShape.rectangle,
                        borderRadius: round ? null : BorderRadius.circular(Radii.card),
                        boxShadow: [
                          BoxShadow(color: colors.palette.shadow, blurRadius: 40, offset: const Offset(0, 18)),
                        ],
                      ),
                      child: Semantics(
                        button: true,
                        label: title,
                        child: GestureDetector(
                          onTap: onOpen,
                          child: CoverFlightSource(
                            tag: flightTag,
                            radius: round ? null : Radii.card,
                            cover: SizedBox.square(dimension: 240, child: cover),
                            builder: (context, cover) => cover,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: colors.textMain),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: colors.textMuted),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Material(
                      color: colors.palette.modal,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.card),
                        side: BorderSide(color: colors.glassBorder),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        // A menu, as a screen reader tells it, as the ⋮'s is.
                        child: Semantics(
                          role: ui.SemanticsRole.menu,
                          explicitChildNodes: true,
                          label: title,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: slide?.entries(context, items) ?? items,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The finger of a long press, still down as its preview opens: slid onto one of the menu's entries, which lights up
/// under it, and let go there, it chooses it, as in iOS. Let go without having slid onto one, it chooses nothing
/// ([released]).
class _PressSlide {
  _PressSlide() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_follow);
  }

  final Completer<(bool chose, _ListAction? action)> _released = Completer();

  /// Completes when the finger lets go: whether it chose an entry, and which.
  Future<(bool, _ListAction?)> get released => _released.future;

  /// The entry under the finger, by its place in the menu.
  final ValueNotifier<int?> _over = ValueNotifier(null);
  List<GlobalKey> _keys = const [];
  List<PopupMenuEntry<_ListAction>> _items = const [];
  Offset? _start;
  bool _moved = false;

  /// How far the finger goes before it is sliding (not just held).
  static const double _slop = 12;

  /// [items], each marked for the finger to find, and lit while it is over it.
  List<Widget> entries(BuildContext context, List<PopupMenuEntry<_ListAction>> items) {
    if (_items.length != items.length) _keys = [for (final _ in items) GlobalKey()];
    _items = items;
    final colors = context.colors;
    return [
      for (final (i, item) in items.indexed)
        ValueListenableBuilder<int?>(
          key: _keys[i],
          valueListenable: _over,
          builder: (context, over, child) =>
              ColoredBox(color: over == i ? colors.accent.withValues(alpha: 0.16) : Colors.transparent, child: child),
          child: item,
        ),
    ];
  }

  void _follow(PointerEvent event) {
    if (_released.isCompleted) return;
    if (event is PointerMoveEvent) {
      final start = _start ??= event.position;
      if (!_moved && (event.position - start).distance < _slop) return;
      _moved = true;
      final over = _entryAt(event.position);
      if (over != _over.value && over != null) unawaited(HapticFeedback.selectionClick());
      _over.value = over;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_follow);
      final over = event is PointerUpEvent ? _over.value : null;
      _over.value = null;
      _released.complete(switch (over == null ? null : _items[over]) {
        PopupMenuItem<_ListAction>(enabled: true, :final value) => (true, value),
        _ => (false, null),
      });
    }
  }

  /// The enabled entry at [position] on the screen, if any.
  int? _entryAt(Offset position) {
    for (final (i, key) in _keys.indexed) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(position)) {
        return switch (_items[i]) {
          PopupMenuItem<_ListAction>(enabled: true) => i,
          _ => null,
        };
      }
    }
    return null;
  }
}

/// Albums as a sliver: on a phone a list of rows (the cover, the title, the artist and the release year), on a wide screen a grid
/// of tiles.
class AlbumsSliver extends StatelessWidget {
  const AlbumsSliver({
    super.key,
    required this.albums,
    required this.onOpen,
    required this.onPlay,
    this.withArtist = true,
  });

  final List<Album> albums;
  final void Function(Album album) onOpen;
  final void Function(Album album) onPlay;

  /// Whether the albums' menus lead to their artist: not on that artist's page.
  final bool withArtist;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        itemCount: albums.length,
        itemBuilder: (context, index) => AlbumCard(
          album: albums[index],
          onOpen: () => onOpen(albums[index]),
          onPlay: () => onPlay(albums[index]),
          withArtist: withArtist,
        ),
      );
    }
    final purple = context.colors.palette.purple;
    return _rows(albums.length, (index) {
      final album = albums[index];
      final menu = ListMenu.album(album, onPlay: () => onPlay(album), withArtist: withArtist);
      return _ListRow(
        onTap: () => onOpen(album),
        onLongPress: () => menu.preview(
          context,
          cover: albumPreviewCover(context, album),
          title: album.title,
          subtitle: album.artist,
          onOpen: () => onOpen(album),
        ),
        flightTag: 'album:${album.id}',
        picture: CoverImage(
          path: album.coverArtPath,
          size: _ListRow.pictureSize,
          radius: Radii.small,
          placeholderIcon: Icons.album,
          placeholderColor: purple,
        ),
        title: album.title,
        subtitle: [album.artist, if (album.releaseYear != null) '${album.releaseYear}'].join('  •  '),
        badge: QualityTag(
          tier: album.quality.tier,
          spec: album.quality.compactSpec,
          fontSize: 9.5,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        ),
        trailing: menu.button(context),
      );
    });
  }
}

/// Artists as a sliver: on a phone a list of rows (the round picture, the name, the albums and tracks), on a wide
/// screen a grid of tiles.
class ArtistsSliver extends StatelessWidget {
  const ArtistsSliver({super.key, required this.artists, required this.onOpen, required this.onPlay});

  final List<Artist> artists;
  final void Function(Artist artist) onOpen;
  final void Function(Artist artist) onPlay;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        kind: TileKind.twoLines,
        itemCount: artists.length,
        itemBuilder: (context, index) => ArtistCard(
          artist: artists[index],
          onOpen: () => onOpen(artists[index]),
          onPlay: () => onPlay(artists[index]),
        ),
      );
    }
    final coral = context.colors.palette.coral;
    return _rows(artists.length, (index) {
      final artist = artists[index];
      final menu = ListMenu.artist(artist, onPlay: () => onPlay(artist));
      return _ListRow(
        onTap: () => onOpen(artist),
        onLongPress: () => menu.preview(
          context,
          cover: artistPreviewPicture(context, artist),
          round: true,
          title: artist.name,
          subtitle: artistCounts(context, artist),
          onOpen: () => onOpen(artist),
        ),
        flightTag: 'artist:${artist.id}',
        circle: true,
        picture: CoverImage(
          path: artist.picturePath,
          size: _ListRow.pictureSize,
          circle: true,
          placeholderIcon: Icons.person,
          placeholderColor: coral,
        ),
        title: artist.name,
        subtitle: artistCounts(context, artist),
        trailing: menu.button(context),
      );
    });
  }
}

/// Playlists as a sliver: on a phone a list of rows (matching album cover size), on a wide screen a grid of tiles.
class PlaylistsSliver extends StatelessWidget {
  const PlaylistsSliver({
    super.key,
    required this.playlists,
    required this.tracksOf,
    required this.onOpen,
    required this.onPlay,
  });

  final List<Playlist> playlists;
  final List<Track> Function(Playlist playlist) tracksOf;
  final void Function(Playlist playlist) onOpen;
  final void Function(Playlist playlist) onPlay;

  @override
  Widget build(BuildContext context) {
    if (!PhoneChrome.isPhone(context)) {
      return TileGridSliver(
        kind: TileKind.twoLines,
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          final tracks = tracksOf(playlist);
          return PlaylistCard(
            playlist: playlist,
            covers: playlistCovers(tracks),
            quality: qualityOf(tracks),
            menu: ListMenu.playlist(playlist, tracks, onPlay: () => onPlay(playlist)),
            onOpen: () => onOpen(playlist),
            onPlay: () => onPlay(playlist),
          );
        },
      );
    }
    return _rows(playlists.length, (index) {
      final playlist = playlists[index];
      final tracks = tracksOf(playlist);
      final covers = playlistCovers(tracks);
      final quality = qualityOf(tracks);
      final badge = quality == null
          ? null
          : QualityTag(
              tier: quality.tier,
              spec: quality.compactSpec,
              fontSize: 9.5,
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            );
      final menu = ListMenu.playlist(playlist, tracks, onPlay: () => onPlay(playlist));
      return _ListRow(
        onTap: () => onOpen(playlist),
        onLongPress: () => menu.preview(
          context,
          cover: PlaylistCover(covers: covers, radius: Radii.card),
          title: playlist.name,
          subtitle: context.trf('TrackCount', [playlist.trackCount]),
          onOpen: () => onOpen(playlist),
        ),
        flightTag: 'playlist:${playlist.id}',
        picture: PlaylistCover(covers: covers, radius: Radii.small),
        title: playlist.name,
        subtitle: context.trf('TrackCount', [playlist.trackCount]),
        badge: badge,
        trailing: menu.button(context),
      );
    });
  }
}

/// A phone's list of [count] rows, all as tall as the first: that follows the user's font size, and the list still
/// knows where every row is without building it.
Widget _rows(int count, Widget Function(int index) row) => count == 0
    ? const SliverToBoxAdapter()
    : SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverPrototypeExtentList.builder(
          prototypeItem: row(0),
          itemCount: count,
          itemBuilder: (context, index) => row(index),
        ),
      );

/// A phone's list row, as large as the music apps' lists: the picture, the title and below it the [subtitle]; a tap
/// opens what it shows.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.onTap,
    this.onLongPress,
    this.flightTag,
    this.circle = false,
    required this.picture,
    required this.title,
    required this.subtitle,
    this.badge,
    this.trailing,
  });

  static const double pictureSize = 68;

  final VoidCallback onTap;

  /// A long press: the preview ([ListMenu.preview]).
  final VoidCallback? onLongPress;

  /// What the picture shows, for it to fly to the page the row opens ([CoverFlightSource]).
  final String? flightTag;

  /// The picture is round (an artist's).
  final bool circle;
  final Widget picture;
  final String title;
  final String subtitle;
  final Widget? badge;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tag = flightTag;
    return tag == null
        ? _build(context, picture)
        : CoverFlightSource(tag: tag, radius: circle ? null : Radii.small, cover: picture, builder: _build);
  }

  Widget _build(BuildContext context, Widget picture) {
    final colors = context.colors;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Radii.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              SizedBox.square(
                dimension: pictureSize,
                child: badge == null
                    ? picture
                    : Stack(
                        children: [
                          Positioned.fill(child: picture),
                          Positioned(
                            left: 4,
                            right: 4,
                            bottom: 4,
                            child: Align(
                              alignment: Alignment.bottomLeft,
                              heightFactor: 1,
                              child: FittedBox(fit: BoxFit.scaleDown, child: badge!),
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: colors.textMain,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// A playlist's cover: a 2x2 collage of its albums, one cover, or an icon.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({super.key, required this.covers, this.radius = Radii.small});

  final List<String> covers;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final lime = context.colors.palette.lime;
    if (covers.isEmpty) {
      return CoverImage(path: null, radius: radius, placeholderIcon: Icons.queue_music, placeholderColor: lime);
    }
    if (covers.toSet().length == 1) {
      return CoverImage(path: covers.first, radius: radius, placeholderIcon: Icons.queue_music, placeholderColor: lime);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [for (final c in covers.take(4)) CoverImage(path: c, radius: 0, decodeWidth: 256)],
      ),
    );
  }
}

/// A playlist: its cover collage (with the format on it), name, track count and a play button.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.playlist,
    required this.covers,
    required this.quality,
    required this.menu,
    required this.onOpen,
    required this.onPlay,
  });

  final Playlist playlist;
  final List<String> covers;

  /// The quality tag of its tracks; null for an empty playlist, which has none.
  final QualitySummary? quality;
  final ListMenu menu;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final lime = colors.palette.lime;
    return _DesktopTile(
      accent: lime,
      onTap: onOpen,
      onSecondaryTap: (position) => menu.showAt(context, position),
      onLongPress: () => menu.preview(
        context,
        cover: PlaylistCover(covers: covers, radius: Radii.card),
        title: playlist.name,
        subtitle: context.trf('TrackCount', [playlist.trackCount]),
        onOpen: onOpen,
      ),
      flightTag: 'playlist:${playlist.id}',
      menu: menu.coverButton(context),
      cover: PlaylistCover(covers: covers, radius: Radii.medium),
      lines: [
        _line(playlist.name, 14, FontWeight.w700, colors.textMain),
        _line(context.trf('TrackCount', [playlist.trackCount]), 12.5, FontWeight.w500, colors.textMuted),
      ],
      badge: quality == null ? null : QualityTag(tier: quality!.tier, spec: quality!.spec),
      play: TilePlayButton(color: lime, onPressed: playlist.trackCount > 0 ? onPlay : null, tracks: menu.tracks),
    );
  }
}

Widget _line(String text, double size, FontWeight weight, Color color, {bool center = false}) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  textAlign: center ? TextAlign.center : TextAlign.start,
  style: TextStyle(fontSize: size, fontWeight: weight, color: color, letterSpacing: size >= 14 ? -0.1 : 0),
);

/// A wide screen's tile: a square cover with a soft shadow and the caption lines under it. Under the mouse, or while
/// the remote's focus is on it or its play button, the tile lifts, its background lights up, the cover's shadow takes
/// the [accent] and the play button rises onto the cover, its ⋮ with it. On a touch screen both are always there.
class _DesktopTile extends StatefulWidget {
  const _DesktopTile({
    required this.accent,
    required this.onTap,
    this.onSecondaryTap,
    this.onLongPress,
    this.flightTag,
    required this.cover,
    required this.lines,
    required this.play,
    required this.menu,
    this.badge,
    this.circle = false,
  });

  /// The space around the cover, inside the tile.
  static const double padding = 10;

  /// The space between the cover and the caption.
  static const double captionGap = 12;

  final Color accent;
  final VoidCallback onTap;
  final void Function(Offset position)? onSecondaryTap;

  /// A long press (a touch screen's): the preview ([ListMenu.preview]).
  final VoidCallback? onLongPress;

  /// What the cover shows, for it to fly to the page the tile opens ([CoverFlightSource]).
  final String? flightTag;
  final Widget cover;
  final List<Widget> lines;
  final Widget play;

  /// The tile's ⋮, on the cover's top corner; it comes with the play button.
  final Widget menu;
  final Widget? badge;
  final bool circle;

  @override
  State<_DesktopTile> createState() => _DesktopTileState();
}

class _DesktopTileState extends State<_DesktopTile> {
  bool _hover = false;
  bool _focus = false;

  /// What the last press was made with: a mouse held down doesn't open the preview, a finger or a pen does.
  ui.PointerDeviceKind? _pressedWith;

  /// The play and menu buttons: a TV remote passes them by, so a tile is one step, and OK opens it.
  static Widget? _offTv(Widget? button) =>
      button != null && AppPlatform.current.isTv ? ExcludeFocus(child: button) : button;

  @override
  Widget build(BuildContext context) {
    final tag = widget.flightTag;
    return tag == null
        ? _build(context, widget.cover)
        : CoverFlightSource(
            tag: tag,
            radius: widget.circle ? null : Radii.medium,
            cover: widget.cover,
            builder: _build,
          );
  }

  Widget _build(BuildContext context, Widget coverImage) {
    final colors = context.colors;
    final active = _hover || _focus;
    final showPlay = active || AppPlatform.current.isMobile;
    const duration = Duration(milliseconds: 240);
    final shape = widget.circle
        ? const BoxDecoration(shape: BoxShape.circle)
        : BoxDecoration(borderRadius: BorderRadius.circular(Radii.medium));
    final cover = AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: duration,
            decoration: shape.copyWith(
              boxShadow: [
                BoxShadow(
                  color: active ? widget.accent.withValues(alpha: 0.38) : colors.palette.shadow,
                  blurRadius: active ? 26 : 16,
                  spreadRadius: -6,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: coverImage,
          ),
          if (widget.badge != null)
            // Beside the play button, while it is there, the tag shrinks rather than slide under it.
            Positioned(
              left: 8,
              right: showPlay ? 8 + 44 + 8 : 8,
              bottom: 8,
              child: Align(
                alignment: Alignment.bottomLeft,
                heightFactor: 1,
                child: FittedBox(fit: BoxFit.scaleDown, child: widget.badge!),
              ),
            ),
          Positioned(
            top: widget.circle ? 0 : 8,
            right: widget.circle ? 0 : 8,
            child: AnimatedOpacity(opacity: showPlay ? 1 : 0, duration: duration, child: _offTv(widget.menu)),
          ),
          Positioned(
            right: widget.circle ? 4 : 8,
            bottom: widget.circle ? 4 : 8,
            child: AnimatedSlide(
              offset: showPlay ? Offset.zero : const Offset(0, 0.35),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(opacity: showPlay ? 1 : 0, duration: duration, child: _offTv(widget.play)),
            ),
          ),
        ],
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focus = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (event) => _pressedWith = event.kind,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, active ? -4 : 0, 0),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.card),
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                onTap: widget.onTap,
                onLongPress: switch (widget.onLongPress) {
                  final onLongPress? => () {
                    if (_pressedWith == ui.PointerDeviceKind.touch || _pressedWith == ui.PointerDeviceKind.stylus) {
                      onLongPress();
                    }
                  },
                  null => null,
                },
                onSecondaryTapUp: widget.onSecondaryTap != null
                    ? (d) => widget.onSecondaryTap!(d.globalPosition)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.all(_DesktopTile.padding),
                  child: Column(
                    crossAxisAlignment: widget.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(height: _DesktopTile.captionGap),
                      for (var i = 0; i < widget.lines.length; i++) ...[
                        if (i > 0) const SizedBox(height: 2),
                        SizedBox(width: double.infinity, child: widget.lines[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which kind of tile a [TileGridSliver] holds; it decides the tile's height.
enum TileKind {
  /// Albums: three lines of caption.
  album,

  /// Artists and playlists: two lines.
  twoLines,
}

/// Tiles as a sliver, for a wide screen (a phone lists rows): as many columns as fit of at least the tile size (176
/// px, larger or smaller after a pinch: `MainViewModel.tileSize`), stretched to fill the row.
class TileGridSliver extends StatelessWidget {
  const TileGridSliver({super.key, required this.itemCount, required this.itemBuilder, this.kind = TileKind.album});

  static const double _gap = 14;

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final TileKind kind;

  /// The height of one line of text at [size] in the font the app uses, at the user's font size.
  static double _lineHeight(BuildContext context, double size, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Ág',
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: size, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final title = _lineHeight(context, 14, FontWeight.w700);
    final second = _lineHeight(context, 12.5, FontWeight.w500);
    final third = _lineHeight(context, 11, FontWeight.w500);
    return ValueListenableBuilder<double>(
      valueListenable: context.vm.tileSize,
      builder: (context, minTileWidth, _) => SliverWidthBuilder(
        builder: (context, width) {
          const padding = 20.0;
          final available = width - 2 * padding;
          final columns = ((available + _gap) / (minTileWidth + _gap)).floor().clamp(1, 1000);
          final tileWidth = (available - _gap * (columns - 1)) / columns;
          // The square cover, then the caption at the user's font size.
          final lines = kind == TileKind.album ? title + second + third + 4 : title + second + 2;
          const inset = 2 * _DesktopTile.padding;
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(padding, 4, padding, 4),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: inset + (tileWidth - inset) + _DesktopTile.captionGap + lines + 2,
                crossAxisSpacing: _gap,
                mainAxisSpacing: _gap,
              ),
              delegate: SliverChildBuilderDelegate(itemBuilder, childCount: itemCount),
            ),
          );
        },
      ),
    );
  }
}

/// The round play button of a tile: filled with a gradient of [color], over a glow of it. While the queue is [tracks]
/// (the tile's album, artist, playlist or track), it pauses and resumes it instead, as a list's Play does.
class TilePlayButton extends StatelessWidget {
  const TilePlayButton({
    super.key,
    required this.color,
    required this.onPressed,
    this.tracks = const [],
    this.size = 44,
  });

  final Color color;
  final VoidCallback? onPressed;
  final List<Track> tracks;
  final double size;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(listenable: player.nowPlaying, builder: (context, _) => _build(context, player));
  }

  Widget _build(BuildContext context, PlayerViewModel player) {
    final colors = context.colors;
    final current = onPressed != null && player.isQueueOf(tracks);
    final playing = current && player.isPlaying;
    final onTap = current ? player.togglePlayPause : onPressed;
    final enabled = onTap != null;
    return Tooltip(
      message: context.tr(playing ? 'Pause' : 'Play'),
      child: PopEffect(
        enabled: enabled,
        press: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: enabled ? null : colors.palette.modal,
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colors.palette.hoverOf(color), color],
                  )
                : null,
            boxShadow: [
              BoxShadow(
                color: enabled ? color.withValues(alpha: 0.5) : colors.palette.shadow,
                blurRadius: 16,
                spreadRadius: -2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(
                dimension: size,
                child: Center(
                  child: PlayPauseIcon(
                    playing: playing,
                    size: size * 0.58,
                    color: enabled ? colors.onAccent : colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
