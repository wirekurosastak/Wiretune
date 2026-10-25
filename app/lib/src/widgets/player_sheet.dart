// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../theme/app_theme.dart';
import 'cover_flight.dart';

/// The phone's full-screen player as a sheet over the pages: [position] runs from 0 (down, closed) to 1 (up, open). It
/// goes where the view model opens or closes it ([follow]), and in between it follows the finger that drags it, up from
/// the mini player or down from the player's top, as in TIDAL and Spotify ([PlayerSheetDrag]). It moves only then.
class PlayerSheet {
  PlayerSheet({required TickerProvider vsync, required bool open})
    : position = AnimationController(vsync: vsync, duration: _duration, value: open ? 1 : 0) {
    // A soft knock when it lands open.
    position.addStatusListener((status) {
      if (status == AnimationStatus.completed) unawaited(HapticFeedback.lightImpact());
    });
  }

  /// The whole way up or down; a part of the way takes that part of it. About a page cover's flight over as far.
  static const Duration _duration = Duration(milliseconds: 360);

  /// A finger that lets go faster than this (logical pixels a second) opens or closes the player, wherever it is.
  static const double _flingVelocity = 700;

  final AnimationController position;

  /// The mini player's cover, out of which the full-screen player's flies as it opens, and back into it ([RisingPlayer]).
  final GlobalKey miniCover = GlobalKey();

  /// The full-screen player's cover, where the mini player's flies to ([PlayerSheetCover.own]).
  _PlayerSheetCoverState? _artwork;

  /// Whether the cover is on its way between the two: the sheet between closed and open, both covers there. Both are
  /// hidden meanwhile ([PlayerSheetCover]), the flying one showing for them.
  bool get coverFlies =>
      position.value > 0 && position.value < 1 && miniCover.currentContext != null && (_artwork?.mounted ?? false);
  bool _dragging = false;
  double? _target;

  /// The view model opened or closed the player (a tap, Back, a page opened from it): the sheet goes there from where
  /// it is, unless a finger holds it; from rest, it sets off and arrives gently, as the covers fly (a whole screen
  /// moving off at a throw's speed judders, even at 120 Hz).
  void follow({required bool open}) {
    if (!_dragging) _settle(open, curve: Curves.easeInOut);
  }

  /// Up or down the rest of the way along [curve]: by default at once, slowing down to rest, as a finger's throw would.
  void _settle(bool open, {Curve curve = Curves.easeOutCubic}) {
    final target = open ? 1.0 : 0.0;
    if (_target == target && position.isAnimating) return;
    _target = target;
    final distance = (target - position.value).abs();
    if (distance == 0) return;
    final duration = _duration * distance;
    if (open) {
      position.animateTo(target, duration: duration, curve: curve);
    } else {
      // A reverse run, which ends dismissed: the closed player is then left out.
      position.animateBack(target, duration: duration, curve: curve);
    }
  }

  void _start() {
    _dragging = true;
    _target = null;
    position.stop();
  }

  /// The finger moved [delta] down (up when negative); [travel] is how far the player's top goes from closed to open.
  /// Past half the way (where letting go opens or closes it) a tick tells the finger so.
  void _move(double delta, double travel) {
    final before = position.value > 0.5;
    position.value -= delta / travel;
    if ((position.value > 0.5) != before) unawaited(HapticFeedback.selectionClick());
  }

  /// The finger let go at [velocity] (down when positive): flung, the sheet goes that way, else to the nearer end.
  /// True when that is open.
  bool _release(double velocity) {
    _dragging = false;
    final open = velocity.abs() > _flingVelocity ? velocity < 0 : position.value > 0.5;
    _settle(open);
    return open;
  }

  void dispose() => position.dispose();
}

/// Makes the phone layout's [PlayerSheet] reachable from the parts that drag it.
class PlayerSheetScope extends InheritedWidget {
  const PlayerSheetScope({super.key, required this.sheet, required super.child});

  final PlayerSheet sheet;

  /// The phone layout's sheet, if [context] is in it.
  static PlayerSheet? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerSheetScope>()?.sheet;

  @override
  bool updateShouldNotify(PlayerSheetScope oldWidget) => sheet != oldWidget.sheet;
}

/// A vertical drag over [child] moves the full-screen player with the finger: up from the mini player, down from the
/// player itself. Let go, it opens or closes the rest of the way (and tells the view model), or goes back. Taps, and
/// horizontal drags such as a slider's, still reach the child.
class PlayerSheetDrag extends StatelessWidget {
  const PlayerSheetDrag({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.maybeOf(context);
    if (sheet == null) return child;
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => sheet._start(),
      // The player's top goes the screen's whole height, so it keeps with the finger.
      onVerticalDragUpdate: (details) => sheet._move(details.primaryDelta ?? 0, height),
      onVerticalDragEnd: (details) {
        final vm = context.vm;
        sheet._release(details.primaryVelocity ?? 0) ? vm.openNowPlaying() : vm.closeNowPlaying();
      },
      child: child,
    );
  }
}

/// The full-screen player as it opens and closes: it rises from the screen's bottom as far as the [sheet] is open
/// (under a finger, as far as the finger has taken it), the corners of its top rounded while it moves, as a window's;
/// and its cover flies out of the mini player's into its place, and back into it as the player goes down
/// ([CoverFlightBetween]).
class RisingPlayer extends StatefulWidget {
  const RisingPlayer({super.key, required this.sheet, required this.cover, required this.child});

  final PlayerSheet sheet;

  /// What flies: the picture of the cover of the track that plays (none: its placeholder's colour).
  final ImageProvider? cover;
  final Widget child;

  @override
  State<RisingPlayer> createState() => _RisingPlayerState();
}

class _RisingPlayerState extends State<RisingPlayer> {
  /// The player itself, unmoved: where its cover's place is measured in.
  final GlobalKey _player = GlobalKey();

  /// The corners of its top while it moves, as a window's.
  static const double _radius = 32;

  /// The last part of the way open, over which they straighten (where the screen's own rounded corners are).
  static const double _straighten = 0.15;

  /// Where [context]'s box is in [within]'s, as drawn (smaller, for a paused track's cover); null while it isn't laid
  /// out.
  static Rect? _rectOf(BuildContext? context, RenderObject? within) {
    final box = context?.findRenderObject() as RenderBox?;
    if (box == null || within == null || !box.attached || !box.hasSize || !within.attached) return null;
    return MatrixUtils.transformRect(box.getTransformTo(within), Offset.zero & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final t = sheet.position.value;
    final corner = Radius.circular(_radius * ((1 - t) / _straighten).clamp(0.0, 1.0));
    // The mini player's cover where it is now; the player's own where it is once open (until the player is laid out,
    // the mini player's: the first frame's flight hasn't left it).
    final from = sheet.coverFlies ? _rectOf(sheet.miniCover.currentContext, context.findRenderObject()) : null;
    final to = from == null
        ? null
        : _rectOf(sheet._artwork?.context, _player.currentContext?.findRenderObject()) ?? from;
    return Stack(
      fit: StackFit.expand,
      children: [
        FractionalTranslation(
          translation: Offset(0, 1 - t),
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(top: corner),
            // Always there (the player under it stays as it is), clipping only while the corners are round.
            clipBehavior: corner == Radius.zero ? Clip.none : Clip.antiAlias,
            child: RepaintBoundary(key: _player, child: widget.child),
          ),
        ),
        if (from != null && to != null)
          CoverFlightBetween(
            progress: t,
            from: from,
            to: to,
            fromRadius: Radii.small,
            toRadius: Radii.panel,
            image: widget.cover,
          ),
      ],
    );
  }
}

/// [child], a cover the full-screen player's flies out of or into: the mini player's, or the player's [own], where it
/// lands. Hidden while the flying one shows for it ([PlayerSheet.coverFlies]); just [child] outside the phone layout.
class PlayerSheetCover extends StatefulWidget {
  const PlayerSheetCover({super.key, this.own = false, required this.child});

  /// The full-screen player's own cover; else the mini player's.
  final bool own;
  final Widget child;

  @override
  State<PlayerSheetCover> createState() => _PlayerSheetCoverState();
}

class _PlayerSheetCoverState extends State<PlayerSheetCover> {
  late final PlayerSheet? _sheet = PlayerSheetScope.maybeOf(context);

  @override
  void initState() {
    super.initState();
    // The latest is the one on show: a tab sliding in, while the one sliding out still holds its own.
    if (widget.own) _sheet?._artwork = this;
  }

  @override
  void dispose() {
    if (_sheet?._artwork == this) _sheet!._artwork = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    if (sheet == null) return widget.child;
    return ListenableBuilder(
      listenable: sheet.position,
      builder: (context, child) => Opacity(opacity: sheet.coverFlies ? 0 : 1, child: child),
      child: widget.child,
    );
  }
}
