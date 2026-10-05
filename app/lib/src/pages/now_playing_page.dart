import 'package:flutter/material.dart' hide RepeatMode;
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../widgets/ambient.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/player_controls.dart';
import '../widgets/quality_tag.dart';
import 'queue_panel.dart';

/// The phone's full-screen player, over the colours of the cover: the cover (with its quality tag), the queue or the
/// lyrics on top (three tabs), and the seek bar and the transport below, whatever the tab.
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
        // The three tabs as one segmented glass pill; the selected segment is filled with the accent.
        Widget segment(int index, String key) {
          final selected = tab == index;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: selected ? colors.accent : colors.accent.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(999),
              boxShadow: selected ? colors.accentGlow(0.6) : const [],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => vm.nowPlayingTab = index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  child: Text(
                    context.tr(key),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: selected ? colors.onAccent : colors.textMain,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Material(
          color: colors.palette.background,
          child: Stack(
            children: [
              const Positioned.fill(child: AmbientBackdrop(colour: 1)),
              SafeArea(
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
                                style: IconButton.styleFrom(backgroundColor: colors.surface1),
                                onPressed: vm.closeNowPlaying,
                                icon: Icon(Icons.keyboard_arrow_down_rounded, size: 28, color: colors.textMain),
                              ),
                            ),
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
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: colors.glassBorder),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [segment(0, 'TabPlayer'), segment(1, 'Queue'), segment(2, 'TabLyrics')],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: KeyedSubtree(
                          key: ValueKey(tab),
                          child: switch (tab) {
                            1 => const _QueueTab(),
                            2 => const _LyricsTab(),
                            _ => const _PlayerTab(),
                          },
                        ),
                      ),
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

class _PlayerTab extends StatelessWidget {
  const _PlayerTab();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final track = player.currentTrack;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
                child: AspectRatio(
                  aspectRatio: 1,
                  // The cover sits back a little while the music is paused, and springs forward when it plays.
                  child: AnimatedScale(
                    scale: player.isPlaying ? 1 : 0.86,
                    duration: const Duration(milliseconds: 520),
                    curve: player.isPlaying ? Curves.easeOutBack : Curves.easeOutCubic,
                    child: AnimatedContainer(
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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Hero(
                            tag: 'now-playing-cover',
                            child: CoverImage(path: track?.coverArtPath, radius: Radii.panel, decodeWidth: 900),
                          ),
                          // On the cover, as on the album tiles.
                          if (player.currentTagSpec.isNotEmpty)
                            Positioned(
                              left: 14,
                              top: 14,
                              child: QualityTag(tier: player.currentTier, spec: player.currentTagSpec, fontSize: 12),
                            ),
                        ],
                      ),
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
                      style: TextStyle(
                        fontSize: 24,
                        letterSpacing: -0.6,
                        fontWeight: FontWeight.w800,
                        color: colors.textMain,
                      ),
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
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.hover),
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
              if (player.canEditQueue)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.palette.coral, minimumSize: const Size(0, 40)),
                  onPressed: player.queueItems.isEmpty ? null : player.clearQueue,
                  icon: const Icon(Icons.playlist_remove_rounded, size: 20),
                  label: Text(
                    context.tr('ClearQueue'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                )
              else
                const SizedBox(height: 40),
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
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
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

/// The seek bar with its times, and the five transport buttons with the big square play button.
class _Transport extends StatelessWidget {
  const _Transport();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    Color toggle(bool on) => on ? colors.hover : colors.textMuted;
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
          const SeekBar(timesBelow: true),
          SizedBox(
            height: 84,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                icon(Icons.shuffle_rounded, 24, 'TipShuffle', player.toggleShuffle, color: toggle(player.isShuffle)),
                icon(Icons.skip_previous_rounded, 34, 'TipPrevious', player.previousTrack),
                const PlayButton(size: 70),
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
