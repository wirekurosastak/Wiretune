// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/player_view_model.dart';

/// The tooltip of the shuffle button: what pressing it does.
String shuffleTip(PlayerViewModel player) => player.isShuffle ? 'TipShuffleOff' : 'TipShuffleOn';

/// The tooltip of the repeat button: the mode a press moves to (off → all → one → off).
String repeatTip(PlayerViewModel player) => switch (player.repeatMode) {
  RepeatMode.off => 'TipRepeatAll',
  RepeatMode.all => 'TipRepeatOne',
  RepeatMode.one => 'TipRepeatOff',
};

/// The repeat button's icon: repeat one, or repeat (the whole queue, or off).
IconData repeatIcon(PlayerViewModel player) =>
    player.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded;

/// A mode of the player (shuffle, repeat) as its button, alike in every player: the icon in the accent with a dot under
/// it while the mode is on, muted while it is off. No glow: that is the switch beside a list's Play ([ShuffleSwitch]).
class PlayerModeButton extends StatelessWidget {
  const PlayerModeButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.on,
    required this.onPressed,
    this.iconSize = 19,
  });

  final IconData icon;

  /// The key of the tooltip, which says what a press does next.
  final String tooltip;
  final bool on;
  final VoidCallback onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      tooltip: context.tr(tooltip),
      iconSize: iconSize,
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Icon(icon, color: on ? colors.accent : colors.textMuted),
          // Under the icon by 3/8 of its size: 7 px under the bar's 19 px icons, 9 under the phone player's 24.
          Positioned(
            bottom: -(iconSize * 3 / 8).roundToDouble(),
            child: AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shuffle, previous, play/pause, next, repeat. Shuffle and repeat take the accent and a dot under them while on.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        const skip = 24.0;
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PlayerModeButton(
              icon: Icons.shuffle_rounded,
              tooltip: shuffleTip(player),
              on: player.isShuffle,
              onPressed: player.toggleShuffle,
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: context.tr('TipPrevious'),
              iconSize: skip,
              onPressed: player.previousTrack,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            const SizedBox(width: 8),
            const PlayButton(),
            const SizedBox(width: 8),
            IconButton(
              tooltip: context.tr('TipNext'),
              iconSize: skip,
              onPressed: player.nextTrack,
              icon: const Icon(Icons.skip_next_rounded),
            ),
            const SizedBox(width: 4),
            PlayerModeButton(
              icon: repeatIcon(player),
              tooltip: repeatTip(player),
              on: player.repeatMode != RepeatMode.off,
              onPressed: player.toggleRepeat,
            ),
          ],
        );
      },
    );
  }
}

/// The round play/pause button, filled with the accent's gradient: it glows (brighter while playing), grows a little
/// under the mouse and gives under the finger, and its icon morphs between play and pause.
class PlayButton extends StatefulWidget {
  const PlayButton({super.key, this.size = 42});

  final double size;

  @override
  State<PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<PlayButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Tooltip(
        message: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : (_hover ? 1.06 : 1),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: colors.accentGradient,
              boxShadow: colors.accentGlow(player.isPlaying || _hover ? 1 : 0.5),
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                focusColor: colors.onAccent.withValues(alpha: 0.25),
                onTap: player.togglePlayPause,
                onHover: (value) => setState(() => _hover = value),
                onHighlightChanged: (value) => setState(() => _pressed = value),
                child: SizedBox.square(
                  dimension: widget.size,
                  child: Center(
                    child: PlayPauseIcon(playing: player.isPlaying, size: widget.size * 0.52, color: colors.onAccent),
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

/// The play icon, morphing into the pause icon (and back) when [playing] changes.
class PlayPauseIcon extends StatefulWidget {
  const PlayPauseIcon({super.key, required this.playing, this.size, this.color});

  final bool playing;
  final double? size;
  final Color? color;

  @override
  State<PlayPauseIcon> createState() => _PlayPauseIconState();
}

class _PlayPauseIconState extends State<PlayPauseIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(PlayPauseIcon old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) widget.playing ? _morph.forward() : _morph.reverse();
  }

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedIcon(
    icon: AnimatedIcons.play_pause,
    progress: CurvedAnimation(parent: _morph, curve: Curves.easeInOutCubic),
    size: widget.size,
    color: widget.color,
  );
}

/// A heart, filled for a favourite; it pops when it fills.
class HeartIcon extends StatefulWidget {
  const HeartIcon({super.key, required this.filled, required this.color, this.size});

  final bool filled;
  final Color color;
  final double? size;

  @override
  State<HeartIcon> createState() => _HeartIconState();
}

class _HeartIconState extends State<HeartIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.4).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 1.4, end: 0.9).chain(CurveTween(curve: Curves.easeInOut)), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 40),
  ]).animate(_pop);

  @override
  void didUpdateWidget(HeartIcon old) {
    super.didUpdateWidget(old);
    if (widget.filled && !old.filled) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Icon(
      widget.filled ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      color: widget.color,
      size: widget.size,
    ),
  );
}

/// What a progress bar follows: every position update, or on a phone or tablet only the whole seconds, so that it is
/// drawn once a second there.
Listenable progressOf(PlayerViewModel player) => AppPlatform.current.isMobile ? player.elapsedSeconds : player.position;

/// The position slider with the elapsed and total time.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, this.timesBelow = false});

  /// Phone layout: the times under the slider instead of beside it.
  final bool timesBelow;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    final timeStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: colors.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ListenableBuilder(
      listenable: Listenable.merge([player, progressOf(player)]),
      builder: (context, _) {
        final total = player.durationSeconds;
        final value = (_dragValue ?? player.positionSeconds).clamp(0.0, total > 0 ? total : 1.0);
        final slider = SizedBox(
          height: 28,
          child: Slider(
            value: value,
            max: total > 0 ? total : 1.0,
            onChanged: player.currentTrack == null ? null : (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              player.seekTo(Duration(milliseconds: (v * 1000).round()));
              setState(() => _dragValue = null);
            },
          ),
        );
        final elapsed = Text(formatClock(Duration(milliseconds: (value * 1000).round())), style: timeStyle);
        final length = Text(formatClock(player.duration), style: timeStyle);
        if (widget.timesBelow) {
          return Column(
            children: [
              slider,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [elapsed, length]),
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              width: 46,
              child: Align(alignment: Alignment.centerRight, child: elapsed),
            ),
            Expanded(child: slider),
            SizedBox(width: 46, child: length),
          ],
        );
      },
    );
  }
}

/// Mute button and volume slider; locked at 100 % in bit-perfect mode.
class VolumeControl extends StatelessWidget {
  const VolumeControl({super.key, this.sliderWidth = 100});

  final double sliderWidth;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: player.volumeToolTip,
            iconSize: 20,
            onPressed: player.isVolumeLocked ? null : player.toggleMute,
            icon: Icon(
              player.isMuted
                  ? Icons.volume_off_rounded
                  : (player.volume < 50 && !player.isVolumeLocked
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded),
              color: player.isVolumeDisabledOrMuted ? colors.textMuted : colors.accent,
            ),
          ),
          SizedBox(
            width: sliderWidth,
            child: Slider(
              // Grey while muted.
              activeColor: player.isMuted ? colors.textMuted : null,
              value: player.isVolumeLocked ? 100 : (player.isMuted ? 0 : player.volume),
              max: 100,
              onChanged: player.isVolumeDisabledOrMuted ? null : player.setVolume,
            ),
          ),
        ],
      ),
    );
  }
}

/// The heart of the current track.
/// The sleep timer: a menu of times after which the music pauses (or the end of the track), and the moon lit while one
/// is set. Its tooltip and the menu's title say when.
class SleepTimerButton extends StatelessWidget {
  const SleepTimerButton({super.key, this.iconSize = 22, this.dimension = 44});

  final double iconSize;
  final double dimension;

  static const List<int> _minutes = [15, 30, 45, 60];

  // The menu's values: minutes, or these two.
  static const int _trackEnd = -1;
  static const int _off = 0;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final at = player.sleepAt;
        final status = at != null
            ? context.trf('SleepTimerAt', [
                MaterialLocalizations.of(context).formatTimeOfDay(
                  TimeOfDay.fromDateTime(at),
                  alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
                ),
              ])
            : (player.sleepsAtTrackEnd ? context.tr('SleepTimerAtTrackEnd') : null);
        return SizedBox.square(
          dimension: dimension,
          child: PopupMenuButton<int>(
            tooltip: status ?? context.tr('SleepTimer'),
            iconSize: iconSize,
            icon: Icon(
              status != null ? Icons.bedtime_rounded : Icons.bedtime_outlined,
              color: status != null ? colors.accent : colors.textMain,
            ),
            onSelected: (value) => switch (value) {
              _trackEnd => player.sleepAtTrackEnd(),
              _off => player.setSleepTimer(null),
              _ => player.setSleepTimer(Duration(minutes: value)),
            },
            itemBuilder: (context) => [
              PopupMenuItem<int>(
                enabled: false,
                height: 32,
                child: Text(
                  (status ?? context.tr('SleepTimer')).toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                    color: colors.textMuted,
                  ),
                ),
              ),
              for (final minutes in _minutes)
                PopupMenuItem(value: minutes, child: Text(context.trf('SleepTimerMinutes', [minutes]))),
              // A track's end is this device's to see; another one is paused by time only.
              if (!player.isRemote) PopupMenuItem(value: _trackEnd, child: Text(context.tr('SleepTimerTrackEnd'))),
              if (status != null) PopupMenuItem(value: _off, child: Text(context.tr('SleepTimerOff'))),
            ],
          ),
        );
      },
    );
  }
}

class FavoriteCurrentButton extends StatelessWidget {
  const FavoriteCurrentButton({super.key, this.size = 20, this.visualDensity});

  final double size;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.currentTrack;
        final favorite = track != null && vm.library.isFavorite(track.id);
        return IconButton(
          visualDensity: visualDensity,
          tooltip: context.tr(favorite ? 'TipRemoveFromFavorites' : 'TipFavorite'),
          iconSize: size,
          onPressed: player.currentTrack == null ? null : player.toggleFavoriteCurrent,
          icon: HeartIcon(filled: favorite, color: favorite ? colors.palette.coral : colors.textMuted),
        );
      },
    );
  }
}

/// Calls [onSwipe] when a horizontal swipe over [child] goes far or fast enough: `forward` for one to the left (towards
/// what comes next), else to the right. Taps, and vertical drags such as a list's, still reach the child.
class HorizontalSwipe extends StatefulWidget {
  const HorizontalSwipe({super.key, required this.onSwipe, required this.child});

  final void Function({required bool forward}) onSwipe;
  final Widget child;

  @override
  State<HorizontalSwipe> createState() => _HorizontalSwipeState();
}

class _HorizontalSwipeState extends State<HorizontalSwipe> {
  double _distance = 0;

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_distance.abs() > 60 || velocity.abs() > 400) {
      widget.onSwipe(forward: (velocity.abs() > 400 ? velocity : _distance) < 0);
    }
    _distance = 0;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: (_) => _distance = 0,
    onHorizontalDragUpdate: (details) => _distance += details.delta.dx,
    onHorizontalDragEnd: _onDragEnd,
    child: widget.child,
  );
}
