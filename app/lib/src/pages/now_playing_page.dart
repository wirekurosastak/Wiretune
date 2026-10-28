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
/// or the tab ([PlayerSwipe]).
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
              borderRadius: BorderRadius.circular(Radii.pill),
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
                                  borderRadius: BorderRadius.circular(Radii.pill),
                                  border: Border.all(color: colors.glassBorder),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    segment(NowPlayingTab.track, 'TabTrack'),
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
                        child: _Tabs(tab: tab),
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
      child: KeyedSubtree(
        key: ValueKey(tab),
        child: switch (tab) {
          NowPlayingTab.track => const _TrackTab(),
          NowPlayingTab.queue => const _QueueTab(),
          NowPlayingTab.lyrics => const _LyricsTab(),
        },
      ),
    );
  }
}

class _TrackTab extends StatelessWidget {
  const _TrackTab();

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: context.vm.player, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    final track = player.currentTrack;
    // The queue and the lyrics scroll vertically themselves; here a drag down takes the player down.
    return PlayerSheetDrag(
      child: Column(
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
                        // The cover sits back a little while the music is paused, and springs forward when it plays.
                        child: AnimatedScale(
                          scale: player.isPlaying ? 1 : 0.86,
                          duration: const Duration(milliseconds: 520),
                          curve: player.isPlaying ? Curves.easeOutBack : Curves.easeOutCubic,
                          // Where the mini player's cover flies as the player opens, and back out of as it closes.
                          child: PlayerSheetCover(
                            own: true,
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
                              child: CoverImage(path: track?.coverArtPath, radius: Radii.panel, decodeWidth: 900),
                            ),
                          ),
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
                      // The artist in the artists' red, as on an album's page, whatever the section's colour.
                      if (track != null && track.artists.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                          child: ArtistLinks(
                            track.artistNames,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.palette.coral),
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
                              player.nowPlayingArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.palette.coral),
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
                lift: false,
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
