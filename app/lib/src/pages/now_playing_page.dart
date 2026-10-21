// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../widgets/ambient.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cover_image.dart';
import '../widgets/devices.dart';
import '../widgets/dialogs.dart';
import '../widgets/links.dart';
import '../widgets/player_controls.dart';
import '../widgets/track_list.dart';
import 'queue_panel.dart';

/// The phone's full-screen player, over the colours of the cover: the cover (with its quality tag), the queue or the
/// lyrics on top (three tabs), and the seek bar and the transport below, whatever the tab. The header has the track's
/// menu (a playlist, the download, the album, the artist); a swipe down over the header, or over the player tab, closes
/// it, and a swipe left or right over the tabs changes the track or the tab ([PlayerSwipe]).
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
        Widget segment(NowPlayingTab value, String key) {
          final selected = tab == value;
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
                onTap: () => vm.nowPlayingTab = value,
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
                    VerticalSwipe(
                      upwards: false,
                      onSwipe: vm.closeNowPlaying,
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
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: colors.glassBorder),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    segment(NowPlayingTab.player, 'TabPlayer'),
                                    segment(NowPlayingTab.queue, 'Queue'),
                                    segment(NowPlayingTab.lyrics, 'TabLyrics'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: HorizontalSwipe(
                        onSwipe: ({required forward}) => _swipe(context, forward: forward),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: KeyedSubtree(
                            key: ValueKey(tab),
                            child: switch (tab) {
                              NowPlayingTab.player => const _PlayerTab(),
                              NowPlayingTab.queue => const _QueueTab(),
                              NowPlayingTab.lyrics => const _LyricsTab(),
                            },
                          ),
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

/// A swipe left or right over the tabs: what the user chose it to do, asked at the first one.
Future<void> _swipe(BuildContext context, {required bool forward}) async {
  final vm = context.vm;
  if (vm.playerSwipe == null) {
    final choice = await askPlayerSwipe(context);
    if (choice == null || !context.mounted) return;
    vm.playerSwipe = choice;
  }
  vm.swipeNowPlaying(forward: forward);
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
    final bpm = switch (track?.bpm) {
      final value? when value > 0 => value,
      _ => null,
    };
    // The queue and the lyrics scroll vertically themselves; here a swipe down closes the player.
    return VerticalSwipe(
      upwards: false,
      onSwipe: vm.closeNowPlaying,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // The cover at its size while playing (paused, it sits back within the same room), centred above the
                  // title with at least [below] under it; a track's BPM sits midway between that edge and the title.
                  final below = bpm != null ? 48.0 : 16.0;
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
                                CoverImage(path: track?.coverArtPath, radius: Radii.panel, decodeWidth: 900),
                                // On the cover, as on the album tiles.
                                if (player.currentTagSpec.isNotEmpty)
                                  Positioned(
                                    left: 14,
                                    bottom: 14,
                                    child: QualityTag(
                                      tier: player.currentTier,
                                      spec: player.currentTagSpec,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: bpm == null
                            ? const SizedBox.shrink()
                            : Center(child: PlayerMetaBadge(text: '$bpm BPM', fontSize: 11)),
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
                      if (track != null && track.artists.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                          child: ArtistLinks(
                            track.artistNames,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.hover),
                            onOpen: vm.openArtistByName,
                          ),
                        )
                      else
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(dimension: 48, child: FavoriteCurrentButton(size: 28)),
                    if (track != null)
                      TrackMenu(track: track, kind: TrackTableKind.tracks, width: 44, color: colors.textMain),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
              PopEffect(
                enabled: player.queueItems.isNotEmpty,
                glowColor: colors.palette.coral,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: colors.palette.coral,
                    minimumSize: const Size(0, 40),
                    overlayColor: Colors.transparent,
                  ),
                  onPressed: player.queueItems.isEmpty ? null : player.clearQueue,
                  icon: const Icon(Icons.playlist_remove_rounded, size: 20),
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
                icon(
                  Icons.shuffle_rounded,
                  24,
                  shuffleTip(player),
                  player.toggleShuffle,
                  color: toggle(player.isShuffle),
                ),
                icon(Icons.skip_previous_rounded, 34, 'TipPrevious', player.previousTrack),
                const PlayButton(size: 70),
                icon(Icons.skip_next_rounded, 34, 'TipNext', player.nextTrack),
                icon(
                  player.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  24,
                  repeatTip(player),
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
