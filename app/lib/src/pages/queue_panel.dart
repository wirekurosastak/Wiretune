// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/player_view_model.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cover_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/equalizer_bars.dart';
import '../widgets/page_parts.dart';
import '../widgets/track_list.dart';

/// The queue: jump to an entry, drag entries (or use the arrows) to reorder them, remove them. Another device's queue
/// (remote control) shows as far as this library knows its tracks, and its changes go to that device.
class QueueList extends StatelessWidget {
  const QueueList({super.key, this.padding = const EdgeInsets.all(16), this.opensAtNext = false});

  final EdgeInsets padding;

  /// Opens at what comes after the playing track, numbered from it (Next, 2, 3 …), where the track is shown above the
  /// list (the phone's full-screen player); the tracks played before it are above, dimmed, scrolled back to.
  final bool opensAtNext;

  /// Where the list opens: what is still to come starts there, what was played goes on above it.
  static const Key _next = ValueKey('next');

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final items = player.queueItems;
        final current = items.indexWhere((item) => item.isCurrent);
        if (items.isEmpty || (opensAtNext && items.length == 1 && current == 0)) {
          return const _QueueEmpty();
        }
        // A TV's remote cannot drag: it gets buttons. Elsewhere a row moves by its handle (and on a phone also under a
        // long press anywhere on it).
        final moveButtons = AppPlatform.current.isTv;
        final proxy = liftedRow(context, const EdgeInsets.only(bottom: 4));
        if (!opensAtNext) {
          // Its rows fade towards the edges as the lyrics' lines do, where more of the queue goes on past them.
          return EdgeFade(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: padding,
              itemCount: items.length,
              onReorderItem: player.moveQueueTrack,
              // A tick as the row lifts, as a long press on any other row gives.
              onReorderStart: (_) => unawaited(Feedback.forLongPress(context)),
              proxyDecorator: proxy,
              itemBuilder: (context, index) => _QueueRow(
                key: ValueKey(items[index]),
                item: items[index],
                number: items[index].displayIndex,
                index: index,
                itemCount: items.length,
                isNext: current >= 0 && index == current + 1,
                showMoveButtons: moveButtons,
              ),
            ),
          );
        }
        final first = current + 1;
        final upcoming = items.length - first;
        return EdgeFade(
          child: CustomScrollView(
            center: _next,
            slivers: [
              // Above where it opens, the last played nearest.
              SliverPadding(
                padding: EdgeInsets.only(left: padding.left, right: padding.right),
                sliver: SliverList.builder(
                  itemCount: math.max(0, current),
                  itemBuilder: (context, index) {
                    final item = items[current - 1 - index];
                    return _QueueRow(
                      key: ValueKey(item),
                      item: item,
                      number: item.displayIndex,
                      index: index,
                      itemCount: current,
                      played: true,
                      showMoveButtons: false,
                    );
                  },
                ),
              ),
              SliverPadding(
                key: _next,
                padding: padding,
                sliver: upcoming == 0
                    ? const SliverFillRemaining(child: _QueueEmpty())
                    : SliverReorderableList(
                        itemCount: upcoming,
                        onReorderItem: (from, to) => player.moveQueueTrack(first + from, first + to),
                        onReorderStart: (_) => unawaited(Feedback.forLongPress(context)),
                        proxyDecorator: proxy,
                        itemBuilder: (context, index) => _QueueRow(
                          key: ValueKey(items[first + index]),
                          item: items[first + index],
                          number: index + 1,
                          index: index,
                          itemCount: upcoming,
                          isNext: current >= 0 && index == 0,
                          showMoveButtons: moveButtons,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The ≡ a queue row moves by.
class _Handle extends StatelessWidget {
  const _Handle({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Icon(Icons.drag_handle_rounded, size: size, color: context.colors.textMuted);
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty();

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.playlist_play_rounded,
    title: context.tr('QueueEmptyTitle'),
    hint: context.tr('QueueEmptyHint'),
  );
}

/// A queue entry: a rounded row with the cover (with the entry's number, "Next" on the one after the current track, or
/// the current one's bouncing bars), title and artist, format, length, the remove button and, at its right end, the
/// handle (≡, as in TIDAL) it moves by at once; a long press anywhere on it moves it too. On a computer its menu opens on
/// a right click. On a phone it is as large as the phone's other track rows, without the length or the ×: a swipe to
/// the left takes it away. A TV's remote cannot drag: there the row has arrows instead of the handle.
class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.item,
    required this.number,
    required this.index,
    required this.itemCount,
    required this.showMoveButtons,
    this.isNext = false,
    this.played = false,
  });

  final QueueItem item;

  /// The number on its cover: its place in the queue, or in what is still to come.
  final int number;
  final int index;
  final int itemCount;
  final bool showMoveButtons;

  /// The entry after the playing one.
  final bool isNext;

  /// Played before the playing one, above where the phone's queue opens: dimmed, without its number, and it stays in
  /// place (a tap plays it again, a swipe takes it out).
  final bool played;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  /// The row width from which the quality tag fits beside a title of about 160 px.
  static const double _tagRowWidth = 520;

  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    final item = widget.item;
    final track = item.track;
    final current = item.isCurrent;
    final phone = PhoneChrome.isPhone(context);
    final cover = phone ? 56.0 : 42.0;
    Widget small(
      IconData icon,
      String tip,
      VoidCallback? onPressed, {
      Color? color,
      double size = 28,
      double iconSize = 16,
    }) => SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: context.tr(tip),
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        onPressed: onPressed,
        icon: Icon(icon, color: color ?? colors.textMuted),
      ),
    );
    final radius = BorderRadius.circular(Radii.medium);
    void remove() {
      final undo = player.removeQueueItem(item);
      if (undo != null) context.vm.showNotice(context.trf('RemovedFromQueue', [track.title]), undo: undo);
    }

    final row = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: current
              ? colors.accent.withValues(alpha: _hover ? 0.2 : 0.14)
              : (_hover ? colors.surface1 : Colors.transparent),
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: current ? colors.accent.withValues(alpha: 0.45) : Colors.transparent),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: () => player.playQueueItem(item),
            // A right click opens the track's menu, as on a table's row; a long press grabs the row.
            onSecondaryTapUp: (details) =>
                showTrackContextMenu(context, details.globalPosition, item.track, TrackTableKind.tracks),
            // Built again when the tags come or go; between, a width that changes only lays the row out.
            child: KeyedLayoutBuilder<bool>(
              keyOf: (constraints) => constraints.maxWidth >= _tagRowWidth,
              builder: (context, tags) => Padding(
                padding: EdgeInsets.fromLTRB(10, phone ? 6 : 7, phone ? 0 : 10, phone ? 6 : 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: cover,
                      height: cover,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CoverImage(path: track.coverArtPath, radius: Radii.small, decodeWidth: (cover * 2).round()),
                          if (current)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0x99000000),
                                borderRadius: BorderRadius.circular(Radii.small),
                              ),
                              child: Center(
                                child: EqualizerBars(playing: player.isPlaying, color: Colors.white),
                              ),
                            )
                          else if (!widget.played)
                            Align(
                              alignment: Alignment.topLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                                decoration: const BoxDecoration(
                                  color: Color(0x99000000),
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(Radii.small),
                                    bottomRight: Radius.circular(Radii.tag),
                                  ),
                                ),
                                // The one after the playing track says so, rather than its number.
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: cover - 6),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      widget.isNext ? context.tr('QueueNextTag') : '${widget.number}',
                                      style: TextStyle(
                                        fontSize: phone ? 10 : 9,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: phone ? 16 : 13.5,
                              fontWeight: phone ? FontWeight.w600 : FontWeight.w700,
                              color: current ? colors.hover : colors.textMain,
                            ),
                          ),
                          SizedBox(height: phone ? 3 : 2),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: phone ? 13.5 : 11.5, color: colors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    // A narrow row (a phone's, a narrow window's) leaves the tag out: the title keeps the room.
                    if (tags) ...[
                      const SizedBox(width: 12),
                      QualityTag(tier: track.format.tier, spec: track.format.tagSpec),
                    ],
                    // A phone's row leaves the length out: the title keeps the room.
                    if (!phone) ...[
                      const SizedBox(width: 12),
                      Text(
                        track.formattedDuration,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: colors.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                    SizedBox(width: phone ? 4 : 12),
                    if (widget.showMoveButtons) ...[
                      small(
                        Icons.keyboard_arrow_up_rounded,
                        'MoveUp',
                        widget.index > 0 ? () => player.moveQueueTrackUp(item) : null,
                      ),
                      const SizedBox(width: 4),
                      small(
                        Icons.keyboard_arrow_down_rounded,
                        'MoveDown',
                        widget.index < widget.itemCount - 1 ? () => player.moveQueueTrackDown(item) : null,
                      ),
                      const SizedBox(width: 8),
                    ],
                    // A phone's row goes with a swipe to the left.
                    if (!phone) small(Icons.close_rounded, 'TipRemoveFromQueue', remove, color: colors.danger),
                    // The handle at the right end, a finger's width on a phone (where a held finger means a drag, not
                    // a tip). A played row stays in its place.
                    if (!AppPlatform.current.isTv && !widget.played)
                      ReorderableDragStartListener(
                        index: widget.index,
                        child: phone
                            ? const SizedBox.square(dimension: 48, child: _Handle(size: 22))
                            : Tooltip(
                                message: context.tr('TipDragToReorder'),
                                child: const SizedBox.square(dimension: 32, child: _Handle(size: 18)),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final shown = widget.played ? Opacity(opacity: 0.5, child: row) : row;
    return ReorderableDelayedDragStartListener(
      index: widget.index,
      enabled: !widget.played,
      child: !phone
          ? shown
          : _SwipeToRemove(
              key: ObjectKey(item),
              // Listening together the host takes it out, after the swipe: the row would stay where it went.
              enabled: !player.isFollowingHost,
              radius: radius,
              onRemove: remove,
              child: shown,
            ),
    );
  }
}

/// A phone's queue row, swiped to the left to take it out. What the swipe does shows as the row goes: the × on a wash
/// of the danger colour that deepens with the swipe, full where letting go takes the row out; there the × grows and
/// the phone ticks (again when the finger goes back).
class _SwipeToRemove extends StatefulWidget {
  const _SwipeToRemove({
    super.key,
    required this.enabled,
    required this.radius,
    required this.onRemove,
    required this.child,
  });

  final bool enabled;
  final BorderRadius radius;
  final VoidCallback onRemove;
  final Widget child;

  @override
  State<_SwipeToRemove> createState() => _SwipeToRemoveState();
}

class _SwipeToRemoveState extends State<_SwipeToRemove> {
  /// How far (of the row's width) it is swiped before letting go takes it out: [Dismissible]'s own.
  static const double _threshold = 0.4;

  /// How far it is swiped, up to [_threshold] (0–1), and whether letting go takes it out.
  final ValueNotifier<(double, bool)> _swipe = ValueNotifier((0, false));

  @override
  void dispose() {
    _swipe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dismissible(
      key: const ValueKey('swipe'),
      direction: widget.enabled ? DismissDirection.endToStart : DismissDirection.none,
      dismissThresholds: const {DismissDirection.endToStart: _threshold},
      onUpdate: (details) {
        if (details.reached != details.previousReached) unawaited(HapticFeedback.selectionClick());
        _swipe.value = ((details.progress / _threshold).clamp(0, 1), details.reached);
      },
      onDismissed: (_) {
        unawaited(HapticFeedback.lightImpact());
        widget.onRemove();
      },
      background: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ValueListenableBuilder<(double, bool)>(
          valueListenable: _swipe,
          builder: (context, swipe, _) {
            final (amount, reached) = swipe;
            return DecoratedBox(
              decoration: BoxDecoration(
                color: colors.danger.withValues(alpha: reached ? 1 : 0.12 + 0.5 * amount),
                borderRadius: widget.radius,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 22),
                  child: AnimatedScale(
                    scale: reached ? 1.25 : 1,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
                    child: Icon(Icons.close_rounded, color: reached ? Colors.white : colors.danger, size: 24),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      child: widget.child,
    );
  }
}

/// The lyrics of the current track: synced lines that follow the song (tap one to jump there), plain text, or why
/// there are none. With [showHeader] it is titled with the track, as beside the queue.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, this.showHeader = true, this.centered = false, this.sideInset = 0});

  final bool showHeader;
  final bool centered;

  /// The space at the lines' sides, inside the scrolling: the scrollbar stays at the edge of the frame.
  final double sideInset;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  int _scrolledTo = -2;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int index) {
    if (index == _scrolledTo) return;
    _scrolledTo = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _lineKeys[index < 0 ? 0 : index];
      final lineContext = key?.currentContext;
      if (lineContext != null) {
        Scrollable.ensureVisible(
          lineContext,
          alignment: 0.4,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final lyrics = context.vm.lyrics;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([player, lyrics]),
      builder: (context, _) {
        final track = player.currentTrack;
        final side = widget.sideInset;
        final header = widget.showHeader
            ? Padding(
                padding: EdgeInsets.fromLTRB(side, 0, side, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionLabel(context.tr('Lyrics'), padding: const EdgeInsets.only(bottom: 2)),
                    if (track != null) ...[
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: colors.textMain),
                      ),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ],
                    if (lyrics.hasLyrics && lyrics.sourceText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          lyrics.sourceText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: colors.textMuted),
                        ),
                      ),
                  ],
                ),
              )
            : const SizedBox.shrink();

        Widget body;
        if (lyrics.isLoading) {
          body = Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(minHeight: 3, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr('LyricsSearching'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textMuted),
                ),
              ],
            ),
          );
        } else if (lyrics.showEmptyState) {
          body = EmptyState(icon: Icons.lyrics_outlined, title: context.tr('NoLyricsTitle'), hint: lyrics.emptyHint);
        } else if (lyrics.isSynced) {
          body = ShaderMask(
            // The lines fade out towards the top and the bottom edge.
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.1, 0.9, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: ValueListenableBuilder<int>(
              valueListenable: lyrics.currentLine,
              builder: (context, current, _) {
                _follow(current);
                final lines = lyrics.lines;
                return ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(side, 24, side, 120),
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    final key = _lineKeys.putIfAbsent(i, GlobalKey.new);
                    if (line.isBlank) return SizedBox(key: key, height: 14);
                    return _LyricLine(
                      key: key,
                      text: line.text,
                      active: i == current,
                      past: i < current,
                      centered: widget.centered,
                      onTap: () {
                        // A tick under the finger: the song jumps there.
                        unawaited(HapticFeedback.selectionClick());
                        lyrics.seekTo(line);
                      },
                    );
                  },
                );
              },
            ),
          );
        } else {
          body = SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(side, 0, side, 80),
            child: SelectableText(
              lyrics.plainText ?? '',
              textAlign: widget.centered ? TextAlign.center : TextAlign.start,
              style: TextStyle(fontSize: 15, height: 26 / 15, color: colors.textMain),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(child: body),
          ],
        );
      },
    );
  }
}

/// A synced lyrics line: dim before and after its time, full and a little larger while it is sung.
class _LyricLine extends StatefulWidget {
  const _LyricLine({
    super.key,
    required this.text,
    required this.active,
    required this.past,
    required this.centered,
    required this.onTap,
  });

  final String text;
  final bool active;
  final bool past;
  final bool centered;
  final VoidCallback onTap;

  @override
  State<_LyricLine> createState() => _LyricLineState();
}

class _LyricLineState extends State<_LyricLine> {
  /// How much larger the line being sung is drawn.
  static const double _activeScale = 1.06;

  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final opacity = widget.active ? 1.0 : (_hover ? 0.85 : (widget.past ? 0.35 : 0.55));
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, // between the words too, not only on their pixels
        onTap: widget.onTap,
        child: Padding(
          // Room at the sides for the glow of the line being sung.
          padding: EdgeInsets.fromLTRB(widget.centered ? 10 : 0, 6, widget.centered ? 10 : 16, 6),
          child: AnimatedOpacity(
            opacity: opacity,
            duration: const Duration(milliseconds: 330),
            child: AnimatedScale(
              scale: widget.active ? _activeScale : 1,
              alignment: widget.centered ? Alignment.center : Alignment.centerLeft,
              duration: const Duration(milliseconds: 330),
              curve: Curves.easeOutCubic,
              // Every line is laid out narrower by the scale, so the one being sung still fits the width when it grows,
              // and it wraps the same way whether it is being sung or not.
              child: FractionallySizedBox(
                widthFactor: 1 / _activeScale,
                alignment: widget.centered ? Alignment.center : Alignment.centerLeft,
                child: Text(
                  widget.text,
                  textAlign: widget.centered ? TextAlign.center : TextAlign.start,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 27 / 20,
                    color: context.colors.textMain,
                    // The line being sung glows softly in the accent.
                    shadows: widget.active
                        ? [Shadow(color: context.colors.accent.withValues(alpha: 0.6), blurRadius: 18)]
                        : null,
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

/// The wide layout's queue page: the title with the number of tracks, Clear, and a glass panel with the queue on the
/// left and the lyrics on the right. The player bar's cover (or Back) closes it.
class QueueLyricsPanel extends StatelessWidget {
  const QueueLyricsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final count = player.queueItems.length;
        return Padding(
          // The card about as far in from the page's bottom as from its sides.
          padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('Queue'),
                          style: TextStyle(
                            fontSize: 34,
                            height: 1.1,
                            letterSpacing: -1,
                            fontWeight: FontWeight.w800,
                            color: colors.textMain,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              context.trf('TrackCount', [count]),
                              style: TextStyle(fontSize: 13, color: colors.textMuted),
                            ),
                            if (player.currentTrack != null) ...[
                              const SizedBox(width: 8),
                              Text('•', style: TextStyle(color: colors.textMuted)),
                              const SizedBox(width: 8),
                              TagBadge(context.tr('NowPlaying').toUpperCase(), color: colors.accent),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopEffect(
                    enabled: count > 0,
                    glowColor: colors.danger,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: colors.danger,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        overlayColor: Colors.transparent,
                      ),
                      onPressed: count == 0 ? null : () => confirmClearQueue(context),
                      icon: Icon(Icons.clear_all_rounded, size: 18, color: count == 0 ? null : colors.danger),
                      label: Text(context.tr('ClearQueue')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: GlassCard(
                  padding: EdgeInsets.zero,
                  hoverColor: colors.accent,
                  child: count == 0
                      ? const QueueList()
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Expanded(child: QueueList()),
                            Container(width: 1, color: colors.glassBorder),
                            const Expanded(
                              child: Padding(padding: EdgeInsets.only(top: 20), child: LyricsView(sideInset: 24)),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
