import 'package:flutter/material.dart' hide RepeatMode;
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/player_controls.dart';
import '../widgets/quality_tag.dart';
import 'queue_panel.dart';

/// The phone's full-screen player: the cover, the queue or the lyrics on top (three tabs), and the quality, the seek
/// bar and the transport below, whatever the tab.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([vm, vm.player]),
      builder: (context, _) {
        final tab = vm.nowPlayingTab;
        Widget pill(int index, String key) {
          final selected = tab == index;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              height: 40,
              child: selected
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      onPressed: () => vm.nowPlayingTab = index,
                      child: Text(context.tr(key)),
                    )
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        backgroundColor: colors.surface1,
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      onPressed: () => vm.nowPlayingTab = index,
                      child: Text(context.tr(key)),
                    ),
            ),
          );
        }

        return Material(
          color: colors.palette.background,
          child: Container(
            decoration: BoxDecoration(gradient: colors.windowGradient),
            child: SafeArea(
              child: Column(
                children: [
                  SizedBox(
                    height: 60,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 44,
                            child: IconButton(
                              tooltip: context.tr('Close'),
                              onPressed: vm.closeNowPlaying,
                              icon: Icon(Icons.keyboard_arrow_down_rounded, size: 30, color: colors.textMain),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              context.tr('NowPlaying'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                letterSpacing: 1.6,
                                fontWeight: FontWeight.w900,
                                color: colors.textMuted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 44),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    // Scaled down rather than cut off on a narrow screen with a large font.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [pill(0, 'TabPlayer'), pill(1, 'Queue'), pill(2, 'TabLyrics')],
                      ),
                    ),
                  ),
                  Expanded(
                    child: switch (tab) {
                      1 => const _QueueTab(),
                      2 => const _LyricsTab(),
                      _ => const _PlayerTab(),
                    },
                  ),
                  const _Transport(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayerTab extends StatelessWidget {
  const _PlayerTab();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final track = player.currentTrack;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    // The soft glow of the accent behind the cover.
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(color: colors.accent.withValues(alpha: 0.25), blurRadius: 60, spreadRadius: -6),
                      ],
                    ),
                    child: Hero(
                      tag: 'now-playing-cover',
                      child: CoverImage(path: track?.coverArtPath, radius: 8, decodeWidth: 900),
                    ),
                  ),
                ),
              ),
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
                      player.nowPlayingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: colors.textMain),
                    ),
                    const SizedBox(height: 2),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: track == null ? null : () => vm.openArtistByName(track.artist),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                        child: Text(
                          player.nowPlayingArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.accent),
                        ),
                      ),
                    ),
                    if (player.hasError)
                      Text(player.errorMessage!, style: TextStyle(fontSize: 12, color: colors.danger)),
                  ],
                ),
              ),
              const SizedBox.square(dimension: 52, child: FavoriteCurrentButton(size: 28)),
            ],
          ),
        ),
      ],
    );
  }
}

class _QueueTab extends StatelessWidget {
  const _QueueTab();

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.tr('Queue'),
                  style: TextStyle(
                    fontSize: 13,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                    color: colors.textMuted,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.palette.coral, minimumSize: const Size(0, 40)),
                onPressed: player.queueItems.isEmpty ? null : player.clearQueue,
                icon: const Icon(Icons.playlist_remove_rounded, size: 20),
                label: Text(
                  context.tr('ClearQueue'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: LyricsView(showHeader: false, centered: true)),
          if (player.hasLyrics && player.lyricsSourceText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                player.lyricsSourceText,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The quality, the seek bar with its times, and the five transport buttons with the big square play button.
class _Transport extends StatelessWidget {
  const _Transport();

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    Color toggle(bool on) => on ? colors.accent : colors.textMuted;
    Widget icon(IconData data, double size, String tip, VoidCallback onPressed, {Color? color}) => SizedBox.square(
      dimension: 52,
      child: IconButton(
        tooltip: context.tr(tip),
        onPressed: onPressed,
        iconSize: size,
        icon: Icon(data, color: color ?? colors.textMain),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.currentTagSpec.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: QualityTag(tier: player.currentTier, spec: player.currentTagSpec, fontSize: 11),
            ),
          const SeekBar(timesBelow: true),
          SizedBox(
            height: 76,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                icon(Icons.shuffle_rounded, 24, 'TipShuffle', player.toggleShuffle, color: toggle(player.isShuffle)),
                icon(Icons.skip_previous_rounded, 34, 'TipPrevious', player.previousTrack),
                SizedBox.square(
                  dimension: 68,
                  child: IconButton.filled(
                    tooltip: context.tr(player.isPlaying ? 'TipPause' : 'TipPlay'),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    iconSize: 36,
                    onPressed: player.togglePlayPause,
                    icon: Icon(player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  ),
                ),
                icon(Icons.skip_next_rounded, 34, 'TipNext', player.nextTrack),
                icon(
                  player.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  24,
                  'TipRepeat',
                  player.toggleRepeat,
                  color: toggle(player.repeatMode != RepeatMode.off),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
