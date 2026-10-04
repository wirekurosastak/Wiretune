import 'package:flutter/material.dart' hide RepeatMode;
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/player_view_model.dart';

/// Shuffle, previous, play/pause, next, repeat.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final small = large ? 26.0 : 18.0;
        final skip = large ? 36.0 : 22.0;
        final main = large ? 40.0 : 24.0;
        Color toggle(bool on) => on ? colors.accent : colors.textMuted;
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: context.tr('TipShuffle'),
              iconSize: small,
              onPressed: player.toggleShuffle,
              icon: Icon(Icons.shuffle_rounded, color: toggle(player.isShuffle)),
            ),
            IconButton(
              tooltip: context.tr('TipPrevious'),
              iconSize: skip,
              onPressed: player.previousTrack,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            SizedBox(width: large ? 12 : 6),
            IconButton.filled(
              tooltip: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
              iconSize: large ? main : 20,
              padding: EdgeInsets.all(large ? 14 : 0),
              style: IconButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                // The desktop's play button is a 38 px square; the phone's big one stays round.
                fixedSize: large ? null : const Size(38, 38),
                minimumSize: large ? null : const Size(38, 38),
                shape: large ? const CircleBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: player.togglePlayPause,
              icon: Icon(player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            SizedBox(width: large ? 12 : 6),
            IconButton(
              tooltip: context.tr('TipNext'),
              iconSize: skip,
              onPressed: player.nextTrack,
              icon: const Icon(Icons.skip_next_rounded),
            ),
            IconButton(
              tooltip: context.tr('TipRepeat'),
              iconSize: small,
              onPressed: player.toggleRepeat,
              icon: Icon(
                player.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                color: toggle(player.repeatMode != RepeatMode.off),
              ),
            ),
          ],
        );
      },
    );
  }
}

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
      color: colors.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ListenableBuilder(
      listenable: Listenable.merge([player, player.position]),
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
              player.isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              color: player.isVolumeActive ? colors.accent : colors.textMuted,
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
  const FavoriteCurrentButton({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final favorite = player.currentTrack?.isFavorite ?? false;
        return IconButton(
          tooltip: context.tr(favorite ? 'TipRemoveFromFavorites' : 'TipFavorite'),
          iconSize: size,
          onPressed: player.currentTrack == null ? null : player.toggleFavoriteCurrent,
          icon: Icon(
            favorite ? Icons.favorite : Icons.favorite_border,
            color: favorite ? colors.palette.coral : colors.textMuted,
          ),
        );
      },
    );
  }
}

extension PlayerSignal on PlayerViewModel {
  bool get hasTrack => currentTrack != null;
}
