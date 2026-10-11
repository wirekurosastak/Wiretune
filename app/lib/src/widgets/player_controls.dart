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

/// Shuffle, previous, play/pause, next, repeat. Shuffle and repeat take the accent and a dot under them while on.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        const small = 19.0;
        const skip = 24.0;
        Widget toggle(IconData icon, String tip, bool on, VoidCallback onPressed) => IconButton(
          tooltip: context.tr(tip),
          iconSize: small,
          onPressed: onPressed,
          icon: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(icon, color: on ? colors.accent : colors.textMuted),
              Positioned(
                bottom: -7,
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            toggle(Icons.shuffle_rounded, shuffleTip(player), player.isShuffle, player.toggleShuffle),
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
            toggle(
              player.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
              repeatTip(player),
              player.repeatMode != RepeatMode.off,
              player.toggleRepeat,
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
class FavoriteCurrentButton extends StatelessWidget {
  const FavoriteCurrentButton({super.key, this.size = 20, this.visualDensity});

  final double size;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final favorite = player.currentTrack?.isFavorite ?? false;
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
