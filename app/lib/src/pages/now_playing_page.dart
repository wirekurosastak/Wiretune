// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/main_view_model.dart';
import '../view_models/player_view_model.dart';
import '../widgets/ambient.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/dialogs.dart';
import '../widgets/links.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_sheet.dart';
import '../widgets/track_list.dart';
import 'queue_panel.dart';

/// The phone's full-screen player, over the colours of the cover: the track (its cover with the quality tag), the queue
/// or the lyrics on top (three tabs), and the seek bar and the transport below, whatever the tab. The track's tab has
/// its menu (a playlist, the download, the album, the artist); a drag down over the header, or over the track's tab,
/// takes the player down with the finger ([PlayerSheetDrag]), and a swipe left or right over the tabs changes the track
/// or the tab ([PlayerSwipe]), following the finger ([_PlayerSwipe]).
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  /// How far a swipe between the tabs has pulled the page, in tabs (towards the next one when positive): the tab
  /// switch's drop follows it.
  final ValueNotifier<double> _pull = ValueNotifier(0);

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

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
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: ColoredBox(color: colors.palette.background.withValues(alpha: 0.55)),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    PlayerSheetDrag(
                      child: Column(
                        children: [
                          SizedBox(
                            height: 60,
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
                                  // As wide as the sleep timer on the other side, so the title stays centred.
                                  const SizedBox(width: 44),
                                  Expanded(
                                    child: ListenableBuilder(
                                      listenable: vm.player,
                                      builder: (context, _) => vm.player.isRemote
                                          ? const Center(child: PlayingOnLabel(fontSize: 12))
                                          : Text(
                                              context.tr('NowPlaying').toUpperCase(),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                letterSpacing: 2,
                                                fontWeight: FontWeight.w800,
                                                color: colors.textMain.withValues(alpha: 0.75),
                                              ),
                                            ),
                                    ),
                                  ),
                                  const SleepTimerButton(),
                                  const SizedBox(width: 44, child: DevicesButton(dimension: 44)),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            // Scaled down rather than cut off on a narrow screen with a large font.
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: colors.surface1,
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                  border: Border.all(color: colors.glassBorder),
                                ),
                                child: _TabSwitch(
                                  tab: tab,
                                  pull: _pull,
                                  onSelected: (value) => vm.nowPlayingTab = value,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _PlayerSwipe(tab: tab, pull: _pull),
                    ),
                    const _Transport(),
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

/// The three tabs as one segmented glass pill, the chosen one under a drop of the accent that slides to the next one
/// chosen, on a spring: it stretches a little with its speed (and thins a little), runs a touch past the tab and
/// settles into it. The labels turn dark exactly where it is. It moves only when the tab changes, and with the finger
/// of a swipe between the tabs ([pull]).
class _TabSwitch extends StatefulWidget {
  const _TabSwitch({required this.tab, required this.pull, required this.onSelected});

  final NowPlayingTab tab;

  /// How far a swipe pulls the page towards the next tab or the one before, in tabs.
  final ValueListenable<double> pull;
  final ValueChanged<NowPlayingTab> onSelected;

  @override
  State<_TabSwitch> createState() => _TabSwitchState();
}

class _TabSwitchState extends State<_TabSwitch> with SingleTickerProviderStateMixin {
  static const Map<NowPlayingTab, String> _labels = {
    NowPlayingTab.track: 'TabTrack',
    NowPlayingTab.queue: 'Queue',
    NowPlayingTab.lyrics: 'TabLyrics',
  };

  static const TextStyle _style = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700);

  /// The drop's slide: quick, a touch past the tab, settling in about half a second.
  static const SpringDescription _spring = SpringDescription(mass: 1, stiffness: 380, damping: 30);

  /// How much the drop stretches for its speed (in tabs a second), and the most it does.
  static const double _stretchPerSpeed = 0.02, _maxStretch = 0.35;

  /// Where the drop is, in tabs (0 is the first one), and how fast it goes there.
  late final AnimationController _flow = AnimationController.unbounded(vsync: this, value: widget.tab.index.toDouble());

  /// The finger's pull as last shown, in tabs, on top of [_flow].
  double _pulled = 0;

  @override
  void initState() {
    super.initState();
    widget.pull.addListener(_onPull);
  }

  /// With the finger while it pulls; let go, from where it left the drop into the tab it is now on (the one the swipe
  /// went to, or back).
  void _onPull() {
    final pull = widget.pull.value;
    if (pull != 0) {
      _flow.stop();
      setState(() => _pulled = pull);
      return;
    }
    if (_pulled == 0) return;
    _flow.value += _pulled;
    _pulled = 0;
    _slideTo(context.vm.nowPlayingTab.index.toDouble());
  }

  void _slideTo(double target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _flow.value = target;
    } else {
      // From wherever it is and as fast as it goes, even still sliding to the tab before.
      _flow.animateWith(SpringSimulation(_spring, _flow.value, target, _flow.velocity));
    }
  }

  @override
  void didUpdateWidget(_TabSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab == oldWidget.tab) return;
    _flow.value += _pulled;
    _pulled = 0;
    _slideTo(widget.tab.index.toDouble());
  }

  @override
  void dispose() {
    widget.pull.removeListener(_onPull);
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final labels = [for (final tab in NowPlayingTab.values) context.tr(_labels[tab]!)];
    // The segments as wide as the widest label, so the drop is one size in each.
    final scaler = MediaQuery.textScalerOf(context);
    final measured = DefaultTextStyle.of(context).style.merge(_style);
    var widest = 0.0, line = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: measured),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout();
      widest = math.max(widest, painter.width);
      line = math.max(line, painter.height);
      painter.dispose();
    }
    final segment = widest + 36;
    final height = line + 18;
    final count = labels.length;
    final width = segment * count;
    return AnimatedBuilder(
      animation: _flow,
      builder: (context, child) {
        // Longer the faster it goes, and thinner as it stretches, as a drop is; kept within the pill at its ends.
        final stretch = (_flow.velocity.abs() * _stretchPerSpeed).clamp(0.0, _maxStretch);
        final middle = ((_flow.value + _pulled).clamp(0.0, count - 1.0) + 0.5) * segment;
        final half = segment * (1 + stretch) / 2;
        final left = (middle - half).clamp(0.0, width);
        final right = (middle + half).clamp(0.0, width);
        final inset = height * 0.25 * stretch;
        final drop = Rect.fromLTRB(left, inset, right, height - inset);
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: drop,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: colors.accentGradient,
                    borderRadius: BorderRadius.circular(Radii.pill),
                    boxShadow: colors.accentGlow(0.6),
                  ),
                ),
              ),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) {
                  final from = left / width, to = right / width;
                  return LinearGradient(
                    colors: [
                      colors.textMain,
                      colors.textMain,
                      colors.onAccent,
                      colors.onAccent,
                      colors.textMain,
                      colors.textMain,
                    ],
                    stops: [0, from, from, to, to, 1],
                  ).createShader(rect);
                },
                child: child,
              ),
            ],
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            for (final (i, tab) in NowPlayingTab.values.indexed)
              Semantics(
                selected: tab == widget.tab,
                button: true,
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  onTap: () => widget.onSelected(tab),
                  child: SizedBox(
                    width: segment,
                    height: height,
                    child: Center(
                      child: Text(labels[i], maxLines: 1, style: _style.copyWith(color: colors.textMain)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The tabs under the finger: a swipe left or right moves the page with it, and what it leads to comes in beside it (the
/// next tab or the one before, or that track's own page, as the user chose: [PlayerSwipe]). A tick tells the finger
/// when letting go would go there: past a third of the way, or flung; else the page goes back. Past an end, or before
/// the user has chosen, the page only gives a little.
class _PlayerSwipe extends StatefulWidget {
  const _PlayerSwipe({required this.tab, required this.pull});

  final NowPlayingTab tab;

  /// Set to how far the page is pulled, in tabs, while a swipe goes between the tabs.
  final ValueNotifier<double> pull;

  @override
  State<_PlayerSwipe> createState() => _PlayerSwipeState();
}

class _PlayerSwipeState extends State<_PlayerSwipe> with SingleTickerProviderStateMixin {
  /// How far the page is off its place, in pixels (left when negative).
  late final AnimationController _offset = AnimationController.unbounded(vsync: this)..addListener(_follow);

  /// How far the finger has gone, in pixels: the page goes as far, or a third of it where nothing comes in beside.
  double _finger = 0;
  double _width = 1;

  /// Whether letting go now would go: the tick is given as it turns true.
  bool _past = false;

  /// One more each time a swipe has brought a tab into place: the tabs start anew with it, without their own slide.
  int _generation = 0;

  MainViewModel get _vm => context.vm;
  PlayerViewModel? _player;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_player != null) return;
    _player = _vm.player..addListener(_readAhead);
    _readAhead();
  }

  @override
  void dispose() {
    _player?.removeListener(_readAhead);
    _offset.dispose();
    super.dispose();
  }

  /// While a swipe goes between the tracks, the covers of the tracks beside the playing one are decoded ahead, at the
  /// size their pages show them, so that one comes in with its cover rather than an empty place.
  void _readAhead() {
    if (!mounted || _vm.playerSwipe != PlayerSwipe.tracks) return;
    for (final next in const [true, false]) {
      final provider = CoverArt.provider(
        _trackBeside(next: next)?.coverArtPath,
        decodeWidth: _TrackTab.coverDecodeWidth,
      );
      if (provider != null) unawaited(precacheImage(provider, context, onError: (_, _) {}));
    }
  }

  /// What a swipe towards the [next] (to the left) brings in: a tab or a track; null at an end, or before the user has
  /// chosen.
  Object? _beside({required bool next}) => switch (_vm.playerSwipe) {
    PlayerSwipe.tabs => _tabBeside(next: next),
    PlayerSwipe.tracks => _trackBeside(next: next),
    null => null,
  };

  /// The tab after this one, or ([next] false) the one before; none at an end.
  NowPlayingTab? _tabBeside({required bool next}) {
    final index = widget.tab.index + (next ? 1 : -1);
    return index >= 0 && index < NowPlayingTab.values.length ? NowPlayingTab.values[index] : null;
  }

  /// The track after the playing one in the queue, or ([next] false) the one before; none at an end the queue doesn't
  /// go round.
  Track? _trackBeside({required bool next}) {
    final player = _vm.player;
    final queue = player.queueTracks;
    final current = player.currentTrack;
    final index = current == null ? -1 : queue.indexWhere((t) => identical(t, current));
    if (index < 0) return null;
    final at = index + (next ? 1 : -1);
    if (at >= 0 && at < queue.length) return queue[at];
    return player.repeatMode == RepeatMode.all && queue.length > 1 ? queue[at % queue.length] : null;
  }

  /// The tab switch's drop goes with the page while the swipe is between the tabs.
  void _follow() {
    final pull = _vm.playerSwipe == PlayerSwipe.tabs ? (-_offset.value / _width).clamp(-1.0, 1.0) : 0.0;
    widget.pull.value = pull;
  }

  void _drag(double delta) {
    _finger += delta;
    final next = _finger < 0;
    // Over the queue or the lyrics a track's swipe has no page to bring: there the page only gives, as at an end.
    final shows =
        _beside(next: next) != null && (_vm.playerSwipe == PlayerSwipe.tabs || widget.tab == NowPlayingTab.track);
    _offset.value = shows ? _finger : _finger / 3;
    final past = _finger.abs() > _width / 3 && _goes(next: next);
    if (past && !_past) unawaited(HapticFeedback.selectionClick());
    if (past != _past) setState(() => _past = past);
  }

  /// Whether a swipe towards the [next] can go anywhere: to the user's question first, else to a tab or a track.
  bool _goes({required bool next}) => switch (_vm.playerSwipe) {
    null => true,
    PlayerSwipe.tabs => _beside(next: next) != null,
    PlayerSwipe.tracks => _trackBeside(next: next) != null,
  };

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
        (flung ? velocity.sign == _finger.sign || _finger == 0 : _finger.abs() > _width / 3) && _goes(next: next);
    if (!go) return _back();
    final mode = _vm.playerSwipe;
    final beside = _beside(next: next);
    final carried = beside != null && (mode == PlayerSwipe.tabs || widget.tab == NowPlayingTab.track);
    if (!carried) {
      // Nothing came in with it (the question first, or a track's swipe over the queue or the lyrics): back into
      // place, and then it goes.
      await _back();
      if (mounted) unawaited(_swipe(context, forward: next));
      return;
    }
    // On out the way it went, the other in place.
    await _offset.animateTo(
      next ? -_width : _width,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    unawaited(HapticFeedback.lightImpact());
    if (mode == PlayerSwipe.tabs) _generation++;
    _vm.swipeNowPlaying(forward: next);
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
              final beside = offset == 0 ? null : _beside(next: next);
              final Widget? coming = switch (beside) {
                final NowPlayingTab tab => _tabPage(tab),
                final Track track when widget.tab == NowPlayingTab.track => _TrackTab(preview: track),
                _ => null,
              };
              Widget at(double x, Widget child) => Opacity(
                opacity: (1 - x.abs() / _width).clamp(0.0, 1.0),
                child: Transform.translate(offset: Offset(x, 0), child: child),
              );
              // How far the playing track's page is from its place, in a swipe between the tracks.
              final away = _vm.playerSwipe == PlayerSwipe.tracks ? (offset.abs() / _width).clamp(0.0, 1.0) : 0.0;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (coming != null)
                    KeyedSubtree(
                      key: ValueKey(('coming', beside)),
                      child: _SwipeAway(
                        away: 1 - away,
                        child: IgnorePointer(child: at(offset + (next ? _width : -_width), coming)),
                      ),
                    ),
                  KeyedSubtree(
                    key: ValueKey(('current', _generation)),
                    child: _SwipeAway(
                      away: away,
                      child: at(offset, _Tabs(tab: widget.tab)),
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

/// How far a track's page is from its place in a swipe between the tracks ([_PlayerSwipe]): 0 in place, 1 a page away.
class _SwipeAway extends InheritedWidget {
  const _SwipeAway({required this.away, required super.child});

  final double away;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SwipeAway>()?.away ?? 0;

  @override
  bool updateShouldNotify(_SwipeAway oldWidget) => away != oldWidget.away;
}

Widget _tabPage(NowPlayingTab tab) => switch (tab) {
  NowPlayingTab.track => const _TrackTab(),
  NowPlayingTab.queue => const _QueueTab(),
  NowPlayingTab.lyrics => const _LyricsTab(),
};

/// A swipe left or right over the tabs: what the user chose it to do, asked at the first one.
Future<void> _swipe(BuildContext context, {required bool forward}) async {
  final vm = context.vm;
  if (vm.playerSwipe == null) {
    final choice = await askPlayerSwipe(context);
    if (choice == null || !context.mounted) return;
    vm.playerSwipe = choice;
  }
  // A tick under the finger: the swipe took.
  unawaited(HapticFeedback.selectionClick());
  vm.swipeNowPlaying(forward: forward);
}

/// The tab on show, the new one sliding in from the side it lies on (a swipe brings it from where the finger went)
/// as the old one fades out to the other.
class _Tabs extends StatefulWidget {
  const _Tabs({required this.tab});

  final NowPlayingTab tab;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  late AnimatedSwitcherTransitionBuilder _transition = _slideTo(widget.tab, forward: true);

  @override
  void didUpdateWidget(_Tabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab == oldWidget.tab) return;
    _transition = _slideTo(widget.tab, forward: widget.tab.index > oldWidget.tab.index);
  }

  /// The new [tab] comes in from the right going [forward], from the left going back; the switcher builds the old
  /// tab's transition again with it (a new builder), so that one leaves the other way.
  static AnimatedSwitcherTransitionBuilder _slideTo(NowPlayingTab tab, {required bool forward}) => (child, animation) {
    final side = (forward ? 1.0 : -1.0) * (child.key == ValueKey(tab) ? 1 : -1);
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(begin: Offset(0.2 * side, 0), end: Offset.zero).animate(animation),
        child: child,
      ),
    );
  };

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) =>
          Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
      transitionBuilder: _transition,
      child: KeyedSubtree(key: ValueKey(tab), child: _tabPage(tab)),
    );
  }
}

class _TrackTab extends StatelessWidget {
  const _TrackTab({this.preview});

  /// The cover's size while the music is paused, of its size while it plays.
  static const double _pausedScale = 0.86;

  /// How wide the cover is decoded: the swipe between the tracks decodes the next ones at it too.
  static const int coverDecodeWidth = 900;

  /// A track beside the playing one, as a swipe brings its page in ([_PlayerSwipe]): as it will look, but nothing in
  /// it pressed, and its cover not the one the mini player's flies into.
  final Track? preview;

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
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The cover at its size while playing (paused, it sits back within the same room), centred above the
                // title with at least [below] under it; a track's tags sit midway between that edge and the title,
                // under the cover rather than on it.
                final below = track != null ? 48.0 : 16.0;
                final side = math.max(
                  0.0,
                  math.min(420.0, math.min(constraints.maxWidth, constraints.maxHeight - below)),
                );
                final spare = math.max(0.0, constraints.maxHeight - side - below);
                return Column(
                  children: [
                    SizedBox(height: spare / 2),
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
                              child: preview != null ? cover : PlayerSheetCover(own: true, child: cover),
                            ),
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: Center(child: track == null ? null : PlayerTags(track: track, fontSize: 11)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview?.title ?? player.nowPlayingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        letterSpacing: -0.6,
                        fontWeight: FontWeight.w800,
                        color: colors.textMain,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // The artist in the accent, as on an album's page.
                    if (track != null && track.artists.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                        child: ArtistLinks(
                          track.artistNames,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.accent),
                          onOpen: vm.openArtistByName,
                        ),
                      )
                    else
                      InkWell(
                        borderRadius: BorderRadius.circular(Radii.tag),
                        onTap: track == null ? null : () => vm.openArtistByName(track.artist),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                          child: Text(
                            preview?.artist ?? player.nowPlayingArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.accent),
                          ),
                        ),
                      ),
                    if (preview == null && player.hasError)
                      Text(player.errorMessage!, style: TextStyle(fontSize: 12, color: colors.danger)),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 48,
                    child: preview == null
                        ? const FavoriteCurrentButton(size: 28)
                        : Center(
                            child: HeartIcon(
                              filled: vm.library.isFavorite(preview.id),
                              color: vm.library.isFavorite(preview.id) ? colors.palette.favorite : colors.textMuted,
                              size: 28,
                            ),
                          ),
                  ),
                  if (track != null)
                    TrackMenu(track: track, kind: TrackTableKind.tracks, width: 44, color: colors.textMain),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    // The queue and the lyrics scroll vertically themselves; here a drag down takes the player down.
    return preview != null ? IgnorePointer(child: page) : PlayerSheetDrag(child: page);
  }
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
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
          child: Row(
            children: [
              // How many: the tab above already says it is the queue (the wide layout's queue says it so too).
              Expanded(
                child: Text(
                  context.trf('TrackCount', [player.queueItems.length]),
                  style: TextStyle(fontSize: 13, color: colors.textMuted),
                ),
              ),
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
        const Expanded(child: QueueList(padding: EdgeInsets.fromLTRB(8, 0, 8, 12))),
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

/// The seek bar with its times, and the five transport buttons with the big round play button.
class _Transport extends StatelessWidget {
  const _Transport();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final player = context.vm.player;
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SeekBar(timesBelow: true),
          SizedBox(
            height: 84,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                mode(Icons.shuffle_rounded, shuffleTip(player), player.isShuffle, player.toggleShuffle),
                icon(Icons.skip_previous_rounded, 'TipPrevious', player.previousTrack),
                const PlayButton(size: 70),
                icon(Icons.skip_next_rounded, 'TipNext', player.nextTrack),
                mode(repeatIcon(player), repeatTip(player), player.repeatMode != RepeatMode.off, player.toggleRepeat),
              ],
            ),
          ),
          // Another device's volume, which the phone's own buttons don't reach.
          if (player.isRemote) const VolumeControl.fill(),
        ],
      ),
    );
  }
}
