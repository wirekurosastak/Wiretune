// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/player_view_model.dart';
import '../widgets/ambient.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cover_flight.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/dialogs.dart';
import '../widgets/links.dart';
import '../widgets/page_parts.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_sheet.dart';
import '../widgets/scrolling_text.dart';
import '../widgets/spectrum_visualizer.dart';
import '../widgets/track_info.dart';
import '../widgets/track_list.dart';
import 'queue_panel.dart';

/// The phone's full-screen player, over the colours of the cover: the track's own page (its cover, a swipe over which
/// changes the track), or the queue or the lyrics almost the whole height ([_PlayerBody]); below, the seek bar and the
/// transport (on the track's page only) and the buttons of the lyrics and the queue ([_Transport]). The track's page
/// has its menu (a playlist, the download, the album, the artist). A drag down over the header, or over the track,
/// takes the player down with the finger ([PlayerSheetDrag]); one up over the track brings the queue up, as in YouTube
/// Music, and one down over the row above the queue or the lyrics brings the track back.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    // Only the tab: the parts below are const, so a rebuild here passes them by, and each follows the player itself.
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final tab = vm.nowPlayingTab;
        return Material(
          color: colors.palette.background,
          child: Stack(
            children: [
              const Positioned.fill(child: AmbientBackdrop(colour: 1, nowPlaying: true)),
              // The queue and the lyrics are read on a layer of the background's colour, so their grey text holds on a
              // bright cover; the track's tab keeps the cover's colours at full strength.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: tab == NowPlayingTab.track ? 0 : 1,
                    duration: _PlayerBody.duration,
                    curve: Curves.easeInOutCubic,
                    child: ColoredBox(color: colors.palette.background.withValues(alpha: 0.55)),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    // Not uncovered by the opening player's rising edge: once the edge is past them, they fade in.
                    _ShownOpen(
                      past: _topRowHeight,
                      child: PlayerSheetDrag(
                        child: SizedBox(
                          height: _topRowHeight,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                SizedBox.square(
                                  dimension: 44,
                                  child: IconButton(
                                    tooltip: context.tr('Close'),
                                    onPressed: vm.closeNowPlaying,
                                    icon: Icon(Icons.keyboard_arrow_down_rounded, size: 28, color: colors.textMain),
                                  ),
                                ),
                                // A sleep timer that is set shows its moon beside the way down; it is chosen from the
                                // ⋮ at the bottom. Its place stays when it isn't, as wide as the lyrics' on the other
                                // side, so the title stays centred.
                                const SizedBox(width: 44, child: SleepTimerButton(onlyWhileSet: true)),
                                Expanded(
                                  child: ListenableBuilder(
                                    listenable: vm.player,
                                    builder: (context, _) {
                                      if (vm.player.isRemote) {
                                        return const Center(child: PlayingOnLabel(fontSize: 12));
                                      }
                                      // What the queue was played from, as Spotify and TIDAL say it; else only that it
                                      // plays.
                                      final from = vm.player.playingFrom;
                                      final column = Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            context.tr(from == null ? 'NowPlaying' : 'PlayingFrom'),
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: colors.textMain.withValues(alpha: 0.75),
                                            ),
                                          ),
                                          if (from != null) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              from,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: colors.textMain,
                                              ),
                                            ),
                                          ],
                                        ],
                                      );
                                      if (from == null || vm.player.playingSource == null) return column;
                                      // A tap leads to it, as in Spotify.
                                      return Semantics(
                                        button: true,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(Radii.small),
                                          onTap: vm.openPlayingSource,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            child: column,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 44, child: _LyricsButton()),
                                const SizedBox(width: 44, child: DevicesButton(dimension: 44)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The controls come on the last part of the way open, as the player grows out of the mini player.
                    Expanded(
                      child: _ShownOpen(child: _PlayerBody(tab: tab)),
                    ),
                    const _ShownOpen(child: _Transport()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The height of the player's top row: the way down, what it plays from, the sleep timer and the devices.
const double _topRowHeight = 60;

/// [child] as the player opens: unseen until it is half way open, then coming on; or, [past] that far under the
/// screen's top, unseen until the player's rising edge is past it, then coming on over the rest of the way.
class _ShownOpen extends StatelessWidget {
  const _ShownOpen({this.past, required this.child});

  final double? past;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.maybeOf(context);
    if (sheet == null) return child;
    final past = this.past;
    var from = 0.5;
    if (past != null) {
      final travel = sheet.travel(MediaQuery.sizeOf(context).height);
      from = (1 - (MediaQuery.paddingOf(context).top + past) / travel).clamp(0.5, 0.95);
    }
    return FadeTransition(
      opacity: sheet.position.drive(CurveTween(curve: Interval(from, 1, curve: Curves.easeOut))),
      child: child,
    );
  }
}

/// The player's middle: the track's own page ([_TrackSwipe]), or the queue or the lyrics almost the whole height under a
/// row of the track with its cover small ([_NowPlayingRow]), which leads back to it. Between the two the cover flies,
/// shrinking into that row or growing back out of it, as the rest fades over and the list rises: at a button's press,
/// or with the finger (up over the track, down over the row: [_BodyDrag]). Between the queue and the lyrics the list
/// alone fades over.
class _PlayerBody extends StatefulWidget {
  const _PlayerBody({required this.tab});

  final NowPlayingTab tab;

  static const Duration duration = Duration(milliseconds: 420);

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> with SingleTickerProviderStateMixin {
  /// 0 on the track's page, 1 on the queue or the lyrics.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: _PlayerBody.duration,
    value: widget.tab == NowPlayingTab.track ? 0 : 1,
  );

  /// The list shown, or last shown while the track's page comes back.
  late NowPlayingTab _list = widget.tab == NowPlayingTab.track ? NowPlayingTab.queue : widget.tab;

  final GlobalKey _body = GlobalKey();
  final GlobalKey _largeCover = GlobalKey();
  final GlobalKey _smallCover = GlobalKey();

  /// Where the cover flies between, in the body: from the track's page to the row; null while it doesn't.
  Rect? _from, _to;

  /// While a finger drags the list in or the track back.
  bool _dragging = false;

  /// From a finger's drag until the cover lands: it keeps with the finger, so it isn't eased (that would jump).
  bool _followed = false;

  bool get _flying => _from != null && _to != null && (_open.isAnimating || _dragging);

  /// Up over the track's page, down over the row; how far is half the body's height.
  late final OtherDrag _drag = OtherDrag(
    takes: (delta) => widget.tab == NowPlayingTab.track ? delta < 0 : delta > 0,
    move: _dragMove,
    end: _dragEnd,
  );

  @override
  void initState() {
    super.initState();
    // Both places move while it flies (the transport goes or comes below), so each frame it heads for where they are.
    _open.addListener(() {
      if (!_dragging && !_followed && (_from == null || _to == null)) return;
      _from = _rectOf(_largeCover) ?? _from;
      _to = _rectOf(_smallCover) ?? _to;
    });
  }

  void _dragMove(double delta) {
    if (!_dragging) {
      setState(() {
        _dragging = _followed = true;
        // Up from the track comes the queue.
        if (widget.tab == NowPlayingTab.track) _list = NowPlayingTab.queue;
      });
      _open.stop();
    }
    final travel = math.max(1.0, (_body.currentContext?.size?.height ?? 600) / 2);
    final before = _open.value > 0.5;
    _open.value = (_open.value - delta / travel).clamp(0.0, 1.0);
    // Past half the way (where letting go goes on) a tick tells the finger so, as the player's own drag does.
    if ((_open.value > 0.5) != before) unawaited(HapticFeedback.selectionClick());
  }

  void _dragEnd(double velocity) {
    setState(() => _dragging = false);
    final open = velocity.abs() > 600 ? velocity < 0 : _open.value > 0.5;
    final tab = open ? _list : NowPlayingTab.track;
    // A new tab flies on from here (didUpdateWidget); the same one goes back.
    if (tab != widget.tab) {
      context.vm.nowPlayingTab = tab;
    } else {
      _fly();
    }
  }

  /// Flies the cover the rest of the way to the tab's place, and puts it there once landed.
  void _fly() {
    final opening = widget.tab != NowPlayingTab.track;
    // From a finger it takes the whole time all the same, as the transport below goes or comes in that time.
    final done = _followed
        ? _open.animateTo(opening ? 1 : 0, duration: _PlayerBody.duration, curve: Curves.easeOutCubic)
        : (opening ? _open.forward() : _open.reverse());
    // Landed; not when turned round half-way, or taken by a finger (the other way flies on, from where it is).
    done.whenCompleteOrCancel(() {
      if (mounted && !_open.isAnimating && !_dragging) {
        setState(() {
          _from = _to = null;
          _followed = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(_PlayerBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tab = widget.tab;
    if (tab == oldWidget.tab) return;
    if (tab != NowPlayingTab.track) _list = tab;
    if ((tab == NowPlayingTab.track) == (oldWidget.tab == NowPlayingTab.track)) return; // between the lists
    // On its way already (let go by a finger, or turned round): on from where it is.
    if (_from != null && _to != null) return _fly();
    // Both are built in this frame; once laid out, the cover's two places are measured and it flies.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _from = _rectOf(_largeCover);
      _to = _rectOf(_smallCover);
      _fly();
    });
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    final body = _body.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || body == null || !box.hasSize || !box.attached) return null;
    // As painted: the cover sits back while the music is paused.
    final rect = MatrixUtils.transformRect(box.getTransformTo(body), Offset.zero & box.size);
    return rect.isFinite ? rect : null;
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.tab == NowPlayingTab.track;
    return AnimatedBuilder(
      animation: _open,
      builder: (context, _) {
        final t = _open.value;
        // Each is built while on show and while it goes or comes.
        final showsPage = track || t < 1 || _open.isAnimating;
        final showsList = !track || t > 0 || _open.isAnimating;
        final flying = _flying;
        // The track's page goes over the first half, the list comes over the second, rising a little.
        final pageShown = 1 - const Interval(0, 0.55, curve: Curves.easeOut).transform(t);
        final listShown = const Interval(0.35, 1, curve: Curves.easeOut).transform(t);
        return _BodyDrag(
          drag: _drag,
          child: Stack(
            key: _body,
            fit: StackFit.expand,
            children: [
              // Keyed: each keeps its state (a finger's drag on it, the queue's scroll) as the other comes or goes.
              if (showsPage)
                IgnorePointer(
                  key: const ValueKey('page'),
                  ignoring: !track,
                  child: Opacity(
                    opacity: pageShown,
                    child: _TrackSwipe(coverKey: _largeCover, coverHidden: flying),
                  ),
                ),
              if (showsList)
                IgnorePointer(
                  key: const ValueKey('list'),
                  ignoring: track,
                  child: Opacity(
                    opacity: listShown,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // In its place from the start: the cover lands in it.
                        _NowPlayingRow(coverKey: _smallCover, coverHidden: flying || t < 1),
                        Expanded(
                          child: Transform.translate(
                            offset: Offset(0, 24 * (1 - listShown)),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              child: KeyedSubtree(
                                key: ValueKey(_list),
                                child: _list == NowPlayingTab.lyrics ? const _LyricsTab() : const _QueueTab(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (flying)
                CoverFlightBetween(
                  progress: _followed ? t : Curves.easeInOutCubic.transform(t),
                  from: _from!,
                  to: _to!,
                  fromRadius: Radii.panel,
                  toRadius: Radii.small,
                  // The playing track's cover, as the track's page shows it.
                  image: CoverArt.provider(
                    context.vm.player.currentTrack?.coverArtPath,
                    decodeWidth: _TrackTab.coverDecodeWidth,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Where the [_PlayerBody]'s drag is reached from: the track's page and the row over the lists.
class _BodyDrag extends InheritedWidget {
  const _BodyDrag({required this.drag, required super.child});

  final OtherDrag drag;

  static OtherDrag? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_BodyDrag>()?.drag;

  @override
  bool updateShouldNotify(_BodyDrag oldWidget) => drag != oldWidget.drag;
}

/// The track over the queue or the lyrics, as the mini player shows it: its cover small, the title and the artists, and
/// Play, the title given the rest of the row (the heart and the menu are on the track's own page). A tap on the cover or
/// the title, or a drag down, leads back to the track's own page.
class _NowPlayingRow extends StatelessWidget {
  const _NowPlayingRow({required this.coverKey, required this.coverHidden});

  final GlobalKey coverKey;

  /// While the cover flies into it or out of it.
  final bool coverHidden;

  static const double coverSize = 56;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final track = player.currentTrack;
    return PlayerSheetDrag(
      other: _BodyDrag.of(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(PhoneChrome.edge, 4, PhoneChrome.edge, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => vm.nowPlayingTab = NowPlayingTab.track,
                      child: Row(
                        children: [
                          Opacity(
                            opacity: coverHidden ? 0 : 1,
                            // Where the mini player's cover flies as the player opens or closes over the queue or the
                            // lyrics.
                            child: PlayerSheetCover(
                              own: true,
                              child: CoverImage(
                                key: coverKey,
                                path: track?.coverArtPath,
                                size: coverSize,
                                radius: Radii.small,
                                decodeWidth: _TrackTab.coverDecodeWidth,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // A list row's sizes, as the queue's under it, the title bolder: it is the one playing.
                                Text(
                                  player.nowPlayingTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    letterSpacing: -0.2,
                                    fontWeight: FontWeight.w700,
                                    color: colors.textMain,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  player.nowPlayingArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: colors.accent),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Over the queue or the lyrics the controls are covered: Play stays here, where the mini player has it.
                const SizedBox(width: 12),
                const PlayButton(size: 40),
              ],
            ),
            const SizedBox(height: 12),
            const SongProgressLine(),
          ],
        ),
      ),
    );
  }
}

/// The track's own page under the finger: a swipe left or right moves it with it, the next track's page (left) or the
/// one before's coming in beside it, its cover growing from a paused one's size as it comes while the playing one's
/// shrinks to it as it goes. A tick tells the finger when letting go would go there: past a third of the way, or
/// flung; else the page goes back. Past an end of the queue the page only gives a little.
class _TrackSwipe extends StatefulWidget {
  const _TrackSwipe({required this.coverKey, required this.coverHidden});

  final GlobalKey coverKey;
  final bool coverHidden;

  @override
  State<_TrackSwipe> createState() => _TrackSwipeState();
}

class _TrackSwipeState extends State<_TrackSwipe> with SingleTickerProviderStateMixin {
  /// How far the page is off its place, in pixels (left when negative).
  late final AnimationController _offset = AnimationController.unbounded(vsync: this);

  /// How far the finger has gone, in pixels: the page goes as far, or a third of it where nothing comes in beside.
  double _finger = 0;
  double _width = 1;

  /// Whether letting go now would go: the tick is given as it turns true.
  bool _past = false;

  late final PlayerViewModel _player = context.vm.player;

  @override
  void initState() {
    super.initState();
    _player.addListener(_readAhead);
    WidgetsBinding.instance.addPostFrameCallback((_) => _readAhead());
  }

  @override
  void dispose() {
    _player.removeListener(_readAhead);
    _offset.dispose();
    super.dispose();
  }

  /// The covers of the tracks beside the playing one, decoded ahead at the size their pages show them, so that one
  /// comes in with its cover rather than an empty place.
  void _readAhead() {
    if (!mounted) return;
    for (final next in const [true, false]) {
      final provider = CoverArt.provider(_beside(next: next)?.coverArtPath, decodeWidth: _TrackTab.coverDecodeWidth);
      if (provider != null) unawaited(precacheImage(provider, context, onError: (_, _) {}));
    }
  }

  /// The track after the playing one in the queue, or ([next] false) the one before; none at an end the queue doesn't
  /// go round.
  Track? _beside({required bool next}) {
    final queue = _player.queueTracks;
    final current = _player.currentTrack;
    final index = current == null ? -1 : queue.indexWhere((t) => identical(t, current));
    if (index < 0) return null;
    final at = index + (next ? 1 : -1);
    if (at >= 0 && at < queue.length) return queue[at];
    return _player.repeatMode == RepeatMode.all && queue.length > 1 ? queue[at % queue.length] : null;
  }

  void _drag(double delta) {
    _finger += delta;
    final next = _finger < 0;
    final goes = _beside(next: next) != null;
    _offset.value = goes ? _finger : _finger / 3;
    final past = goes && _finger.abs() > _width / 3;
    if (past && !_past) unawaited(HapticFeedback.selectionClick());
    if (past != _past) setState(() => _past = past);
  }

  Future<void> _back() async {
    _finger = 0;
    _past = false;
    await _offset.animateTo(0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
    if (mounted) setState(() {});
  }

  Future<void> _release(double velocity) async {
    final flung = velocity.abs() > 600;
    final next = flung ? velocity < 0 : _finger < 0;
    final go =
        (flung ? velocity.sign == _finger.sign || _finger == 0 : _finger.abs() > _width / 3) &&
        _beside(next: next) != null;
    if (!go) return _back();
    // On out the way it went, the other in place.
    await _offset.animateTo(
      next ? -_width : _width,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    next ? _player.nextTrack() : _player.previousTrack(restart: false);
    _finger = 0;
    _past = false;
    _offset.value = 0;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = math.max(1, constraints.maxWidth);
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          _offset.stop();
          _finger = _offset.value;
        },
        onHorizontalDragUpdate: (details) => _drag(details.primaryDelta ?? 0),
        onHorizontalDragEnd: (details) => unawaited(_release(details.primaryVelocity ?? 0)),
        onHorizontalDragCancel: () => unawaited(_back()),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, _) {
              final offset = _offset.value;
              final next = offset < 0;
              final coming = offset == 0 ? null : _beside(next: next);
              Widget at(double x, Widget child) => Opacity(
                opacity: (1 - x.abs() / _width).clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset(x, 0), child: child),
              );
              // How far the playing track's page is from its place.
              final away = (offset.abs() / _width).clamp(0.0, 1.0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (coming != null)
                    KeyedSubtree(
                      key: ValueKey(('coming', coming)),
                      child: _SwipeAway(
                        away: 1 - away,
                        child: IgnorePointer(child: at(offset + (next ? _width : -_width), _TrackTab(preview: coming))),
                      ),
                    ),
                  KeyedSubtree(
                    key: const ValueKey('current'),
                    child: _SwipeAway(
                      away: away,
                      child: at(offset, _TrackTab(coverKey: widget.coverKey, coverHidden: widget.coverHidden)),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

/// How far a track's page is from its place in a swipe between the tracks ([_TrackSwipe]): 0 in place, 1 a page away.
class _SwipeAway extends InheritedWidget {
  const _SwipeAway({required this.away, required super.child});

  final double away;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SwipeAway>()?.away ?? 0;

  @override
  bool updateShouldNotify(_SwipeAway oldWidget) => away != oldWidget.away;
}

class _TrackTab extends StatelessWidget {
  const _TrackTab({this.preview, this.coverKey, this.coverHidden = false});

  /// The cover's size while the music is paused, of its size while it plays.
  static const double _pausedScale = 0.86;

  /// The space at the sides of the cover, the title, the seek bar and its times: one edge, as TIDAL's and Spotify's.
  static const double edge = 24;

  /// The heart's square, to press it by, and the heart in it.
  static const double _heartBox = 48, _heartSize = 28;

  /// How wide the cover is decoded: the swipe between the tracks decodes the next ones at it too.
  static const int coverDecodeWidth = 900;

  /// A track beside the playing one, as a swipe brings its page in ([_TrackSwipe]): as it will look, but nothing in
  /// it pressed, and its cover not the one the mini player's flies into.
  final Track? preview;

  /// The cover, for its flight into the row over the queue or the lyrics ([_PlayerBody]), and whether it is hidden
  /// while it flies.
  final GlobalKey? coverKey;
  final bool coverHidden;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final preview = this.preview;
    final track = preview ?? player.currentTrack;
    final cover = AnimatedContainer(
      key: coverKey,
      duration: const Duration(milliseconds: 520),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.panel),
        boxShadow: [
          BoxShadow(
            color: const Color(0x8C000000),
            blurRadius: player.isPlaying ? 50 : 24,
            spreadRadius: -10,
            offset: Offset(0, player.isPlaying ? 28 : 14),
          ),
        ],
      ),
      child: CoverImage(path: track?.coverArtPath, radius: Radii.panel, decodeWidth: coverDecodeWidth),
    );
    final page = Column(
      children: [
        Expanded(
          child: Padding(
            // The edge the title, the seek bar and its times keep too.
            padding: const EdgeInsets.symmetric(horizontal: _TrackTab.edge),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The cover at its size while playing (paused, it sits back within the same room), as far under the
                // header as over the title, with at least [below] under it; a track's tags sit midway between that edge
                // and the title, under the cover rather than on it.
                final below = track != null ? 48.0 : 16.0;
                final side = math.max(
                  0.0,
                  math.min(420.0, math.min(constraints.maxWidth, constraints.maxHeight - below)),
                );
                final spare = math.max(0.0, constraints.maxHeight - side);
                final under = math.max(below, spare / 2);
                return Column(
                  children: [
                    SizedBox(height: spare - under),
                    SizedBox.square(
                      dimension: side,
                      child: Builder(
                        builder: (context) {
                          // A page away in a swipe between the tracks the cover is a paused one's size, and grows to its
                          // own as its page comes in (the one going out shrinks to it).
                          final rest = player.isPlaying ? 1.0 : _pausedScale;
                          final away = _SwipeAway.of(context);
                          return Transform.scale(
                            scale: 1 + (_pausedScale / rest - 1) * away,
                            // The cover sits back a little while the music is paused, and springs forward when it plays.
                            child: AnimatedScale(
                              scale: rest,
                              duration: const Duration(milliseconds: 520),
                              curve: player.isPlaying ? Curves.easeOutBack : Curves.easeOutCubic,
                              // Where the mini player's cover flies as the player opens, and back out of as it closes.
                              child: Opacity(
                                opacity: coverHidden ? 0 : 1,
                                child: preview != null ? cover : PlayerSheetCover(own: true, child: cover),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: track == null
                            ? null
                            : preview != null
                            ? PlayerTags(track: track, fontSize: 11)
                            // A tap tells more: the file and the way it takes to the speakers.
                            : Semantics(
                                button: true,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => showTrackInfo(context),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: PlayerTags(track: track, fontSize: 11),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Padding(
          // The heart (in the middle of its box) ends at the edge, as the cover and the seek bar do.
          padding: const EdgeInsets.fromLTRB(_TrackTab.edge, 0, _TrackTab.edge - (_heartBox - _heartSize) / 2, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // The title over the artist, as large as TIDAL's and Spotify's; a title too long for its room scrolls
                  // through, as theirs do. The heart beside the two, in the middle of their height, as in Spotify.
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (preview != null)
                          Text(preview.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle(colors))
                        else
                          ScrollingText(player.nowPlayingTitle, style: _titleStyle(colors)),
                        const SizedBox(height: 2),
                        // The artist in the accent, as on an album's page.
                        if (track != null && track.artists.isNotEmpty)
                          ArtistLinks(track.artistNames, style: _artistStyle(colors), onOpen: vm.openArtistByName)
                        else
                          InkWell(
                            borderRadius: BorderRadius.circular(Radii.tag),
                            onTap: track == null ? null : () => vm.openArtistByName(track.artist),
                            child: Text(
                              preview?.artist ?? player.nowPlayingArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _artistStyle(colors),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox.square(
                    dimension: _heartBox,
                    child: preview == null
                        ? const FavoriteCurrentButton(size: _heartSize)
                        : Center(
                            child: HeartIcon(
                              filled: vm.library.isFavorite(preview.id),
                              color: vm.library.isFavorite(preview.id) ? colors.palette.favorite : colors.textMuted,
                              size: _heartSize,
                            ),
                          ),
                  ),
                ],
              ),
              if (preview == null && player.hasError)
                Padding(
                  padding: const EdgeInsets.only(right: _TrackTab.edge),
                  child: Text(player.errorMessage!, style: TextStyle(fontSize: 12, color: colors.danger)),
                ),
            ],
          ),
        ),
      ],
    );
    // The queue and the lyrics scroll vertically themselves; here a drag down takes the player down, one up brings the
    // queue up.
    return preview != null ? IgnorePointer(child: page) : PlayerSheetDrag(other: _BodyDrag.of(context), child: page);
  }

  static TextStyle _titleStyle(WiretuneColors colors) =>
      TextStyle(fontSize: 21, letterSpacing: -0.5, fontWeight: FontWeight.w800, color: colors.textMain);

  static TextStyle _artistStyle(WiretuneColors colors) =>
      TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.accent);
}

class _QueueTab extends StatelessWidget {
  const _QueueTab();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PhoneChrome.edge, 0, 8, 4),
          child: LayoutBuilder(
            builder: (context, row) => Row(
              children: [
                // How many are still to come, as the list below holds: the tab above already says it is the queue.
                Expanded(
                  child: Text(
                    context.trf('TrackCount', [player.queueItems.length - player.upcomingQueueStart]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.textMuted),
                  ),
                ),
                // With a large font and long words the two buttons shrink to the row's width.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: row.maxWidth),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SaveQueueButton(),
                        PopEffect(
                          enabled: player.queueItems.isNotEmpty,
                          glowColor: colors.danger,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: colors.danger,
                              minimumSize: const Size(0, 40),
                              overlayColor: Colors.transparent,
                            ),
                            onPressed: player.queueItems.isEmpty ? null : () => confirmClearQueue(context),
                            icon: const Icon(Icons.clear_all_rounded, size: 20),
                            label: Text(
                              context.tr('ClearQueue'),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // The rows' covers under the playing track's, 16 from the edge (a row keeps 10 inside it).
        const Expanded(
          child: QueueList(padding: EdgeInsets.fromLTRB(PhoneChrome.edge - 10, 0, 6, 12), opensAtNext: true),
        ),
      ],
    );
  }
}

class _LyricsTab extends StatelessWidget {
  const _LyricsTab();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.lyrics, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final lyrics = context.vm.lyrics;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: LyricsView(showHeader: false, centered: true)),
          if (lyrics.hasLyrics && lyrics.sourceText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                lyrics.sourceText,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The seek bar with its times, the five transport buttons with the big round play button, and under shuffle and
/// repeat the lyrics' and the queue's: each shows its list over the track, as its mode does (the accent and a dot
/// while it is open), and leads back to the track.
class _Transport extends StatelessWidget {
  const _Transport();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([context.vm, context.vm.player]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    Widget icon(IconData data, String tip, VoidCallback onPressed) => SizedBox.square(
      dimension: 52,
      child: IconButton(
        tooltip: context.tr(tip),
        onPressed: onPressed,
        iconSize: 34,
        icon: Icon(data, color: colors.textMain),
      ),
    );
    // Shuffle and repeat as in every player: the accent and a dot while on.
    Widget mode(IconData data, String tip, bool on, VoidCallback onPressed) => SizedBox.square(
      dimension: 52,
      child: PlayerModeButton(icon: data, tooltip: tip, on: on, onPressed: onPressed, iconSize: 24),
    );
    Widget list(IconData data, String tip, NowPlayingTab tab) {
      final open = vm.nowPlayingTab == tab;
      return mode(data, tip, open, () => vm.nowPlayingTab = open ? NowPlayingTab.track : tab);
    }

    // The seek bar's track and times at the page's edge, under the title (the slider keeps its ends in from its sides);
    // the buttons further in.
    const buttons = EdgeInsets.symmetric(horizontal: 20 - (_TrackTab.edge - SeekBar.inset));
    return Padding(
      padding: const EdgeInsets.fromLTRB(_TrackTab.edge - SeekBar.inset, 0, _TrackTab.edge - SeekBar.inset, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Over the queue or the lyrics only the two buttons stay: the list takes the room. They fade out, then their
          // room closes (and the other way round), so nothing has to be cut off: the play button's glow reaches past
          // them. (Not an AnimatedSize: that runs its animation again at every layout, which the seek bar's time asks
          // for each second.)
          TweenAnimationBuilder<double>(
            tween: Tween(end: vm.nowPlayingTab == NowPlayingTab.track ? 1 : 0),
            duration: _PlayerBody.duration,
            // Shown, it neither cuts nor adds a layer (an opacity of 1 paints straight through).
            builder: (context, shown, child) => Align(
              alignment: Alignment.topCenter,
              heightFactor: Curves.easeInOutCubic.transform(const Interval(0, 0.7).transform(shown)),
              child: shown == 0
                  ? null
                  : Opacity(opacity: Curves.easeOut.transform(const Interval(0.5, 1).transform(shown)), child: child),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SeekBar(timesBelow: true),
                Padding(
                  padding: buttons,
                  child: SizedBox(
                    height: 84,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        mode(Icons.shuffle_rounded, shuffleTip(player), player.isShuffle, player.toggleShuffle),
                        icon(Icons.skip_previous_rounded, 'TipPrevious', player.previousTrack),
                        const PlayButton(size: 70),
                        icon(Icons.skip_next_rounded, 'TipNext', player.nextTrack),
                        mode(
                          repeatIcon(player),
                          repeatTip(player),
                          player.repeatMode != RepeatMode.off,
                          player.toggleRepeat,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // The queue and the menu under shuffle and repeat (the transport's row shares its room out evenly around its
          // five buttons), and between them the spectrum, as the computer's player bar has it; while another device
          // plays, whose music isn't analysed here, that device's volume, which the phone's own buttons don't reach.
          Padding(
            padding: buttons,
            child: LayoutBuilder(
              builder: (context, box) {
                final side = math.max(0.0, (box.maxWidth - 52 * 4 - 70) / 6);
                return Row(
                  children: [
                    SizedBox(width: side),
                    list(Icons.format_list_bulleted_rounded, 'Queue', NowPlayingTab.queue),
                    Expanded(child: player.isRemote ? const VolumeControl.fill() : const _PlayerSpectrum()),
                    const SizedBox.square(dimension: 52, child: _PlayerMenu()),
                    SizedBox(width: side),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The lyrics at the top right, beside the devices: lit while they are open; pressed again, back to the track.
class _LyricsButton extends StatelessWidget {
  const _LyricsButton();

  // It follows the tab itself: as a const child it isn't rebuilt with the player.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    final open = vm.nowPlayingTab == NowPlayingTab.lyrics;
    return IconButton(
      tooltip: context.tr('TabLyrics'),
      isSelected: open,
      icon: Icon(Icons.lyrics_outlined, color: open ? colors.accent : colors.textMain),
      onPressed: () => vm.nowPlayingTab = open ? NowPlayingTab.track : NowPlayingTab.lyrics,
    );
  }
}

/// The things to do with what plays, from the ⋮ at the player's bottom right: the sleep timer, and the track's own menu
/// (but its heart, which is beside the title).
class _PlayerMenu extends StatelessWidget {
  const _PlayerMenu();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: vm.player,
      builder: (context, _) {
        final track = vm.player.currentTrack;
        return IconButton(
          tooltip: context.tr('TipMore'),
          iconSize: 24,
          icon: Icon(Icons.more_vert_rounded, color: colors.textMain),
          onPressed: track == null ? null : () => _open(context, track),
        );
      },
    );
  }

  static Future<void> _open(BuildContext context, Track track) async {
    final colors = context.colors;
    final sleep = SleepTimerButton.statusOf(context);
    PopupMenuItem<Object> entry(_PlayerEntry value, IconData icon, String text, {bool lit = false}) => PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: lit ? colors.accent : colors.textMuted),
          const SizedBox(width: 14),
          Flexible(child: Text(text)),
        ],
      ),
    );
    final chosen = await showMenuSheet<Object>(
      context,
      cover: CoverImage(path: track.coverArtPath, size: menuSheetCoverSize, placeholderIcon: Icons.music_note),
      title: track.title,
      subtitle: track.artist,
      items: [
        entry(
          _PlayerEntry.sleepTimer,
          sleep != null ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          sleep ?? context.tr('SleepTimer'),
          lit: sleep != null,
        ),
        const PopupMenuDivider(),
        ...TrackMenu.buildMenuItems(context, track, TrackTableKind.tracks),
      ],
    );
    if (!context.mounted) return;
    switch (chosen) {
      case _PlayerEntry.sleepTimer:
        await SleepTimerButton.showSheet(context);
      case final TrackAction action:
        TrackMenu.handleAction(context, action, track);
    }
  }
}

enum _PlayerEntry { sleepTimer }

/// The spectrum between the queue's button and the menu. It is there only while the app is on screen: as long as it
/// is, the phone decodes the track a second time and analyses it ([PlayerViewModel.spectrum]), which costs battery.
class _PlayerSpectrum extends StatefulWidget {
  const _PlayerSpectrum();

  @override
  State<_PlayerSpectrum> createState() => _PlayerSpectrumState();
}

class _PlayerSpectrumState extends State<_PlayerSpectrum> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (_) => setState(() {}));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = WidgetsBinding.instance.lifecycleState;
    return SizedBox(
      height: SpectrumVisualizer.height,
      // The screen off or another app in front: nothing listens, so nothing is analysed.
      child: state != null && state != AppLifecycleState.resumed
          ? null
          : LayoutBuilder(
              builder: (context, box) => Center(
                child: SpectrumVisualizer(
                  bands: context.vm.player.spectrum,
                  color: colors.accent,
                  highlight: colors.hover,
                  width: math.max(0, box.maxWidth - 16),
                ),
              ),
            ),
    );
  }
}
