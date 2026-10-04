import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/player_view_model.dart';
import '../widgets/common.dart';
import '../widgets/cover_image.dart';
import '../widgets/equalizer_bars.dart';
import '../widgets/quality_tag.dart';

/// The queue: jump to an entry, drag entries (or use the arrows) to reorder them, remove them.
class QueueList extends StatelessWidget {
  const QueueList({super.key, this.padding = const EdgeInsets.all(16)});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final items = player.queueItems;
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.playlist_play_rounded,
            title: context.tr('QueueEmptyTitle'),
            hint: context.tr('QueueEmptyHint'),
          );
        }
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: padding,
          itemCount: items.length,
          onReorderItem: player.moveQueueTrack,
          itemBuilder: (context, index) => _QueueRow(
            key: ValueKey(items[index]),
            item: items[index],
            index: index,
            itemCount: items.length,
            // A remote or a keyboard cannot drag: they get buttons. A phone drags by the handle.
            showMoveButtons: !AppPlatform.current.isMobile,
          ),
        );
      },
    );
  }
}

/// A queue entry: a bordered card with the drag handle, the cover (with the entry's number, or the bouncing bars of the
/// current track), title and artist, format, length, the arrows and the remove button.
class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.item,
    required this.index,
    required this.itemCount,
    required this.showMoveButtons,
  });

  final QueueItem item;
  final int index;
  final int itemCount;
  final bool showMoveButtons;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    final item = widget.item;
    final track = item.track;
    final current = item.isCurrent;
    final highlighted = current || _hover;
    Widget small(IconData icon, String tip, VoidCallback? onPressed, {Color? color}) => SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        tooltip: context.tr(tip),
        padding: EdgeInsets.zero,
        iconSize: 16,
        onPressed: onPressed,
        icon: Icon(icon, color: color ?? colors.textMuted),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: current && _hover ? colors.palette.glassHighlight : (highlighted ? colors.surface2 : colors.surface1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: highlighted ? colors.accent : colors.glassBorder),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => player.playQueueTrack(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: Tooltip(
                      message: context.tr('TipDragToReorder'),
                      child: SizedBox(
                        width: 20,
                        child: Icon(Icons.drag_indicator_rounded, size: 16, color: colors.palette.textDisabled),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CoverImage(path: track.coverArtPath, radius: 6, decodeWidth: 76),
                        if (current)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xA0000000),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Center(child: EqualizerBars()),
                          )
                        else
                          Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                              decoration: const BoxDecoration(
                                color: Color(0x80000000),
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(6),
                                  bottomRight: Radius.circular(4),
                                ),
                              ),
                              child: Text(
                                '${item.displayIndex}',
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: colors.textMuted),
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
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.textMain),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  QualityTag(tier: track.format.tier, spec: track.format.tagSpec, compact: true),
                  const SizedBox(width: 12),
                  Text(track.formattedDuration, style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  const SizedBox(width: 12),
                  if (widget.showMoveButtons) ...[
                    small(
                      Icons.keyboard_arrow_up_rounded,
                      'TipMoveUp',
                      item.index > 0 ? () => player.moveQueueTrackUp(item) : null,
                    ),
                    const SizedBox(width: 4),
                    small(
                      Icons.keyboard_arrow_down_rounded,
                      'TipMoveDown',
                      item.index < widget.itemCount - 1 ? () => player.moveQueueTrackDown(item) : null,
                    ),
                    const SizedBox(width: 8),
                  ],
                  small(
                    Icons.close_rounded,
                    'TipRemoveFromQueue',
                    () => player.removeQueueTrack(track),
                    color: colors.danger,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The lyrics of the current track: synced lines that follow the song (tap one to jump there), plain text, or why
/// there are none. With [showHeader] it is titled with the track, as beside the queue.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, this.showHeader = true, this.centered = false});

  final bool showHeader;
  final bool centered;

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
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.currentTrack;
        final header = widget.showHeader
            ? Padding(
                padding: const EdgeInsets.only(bottom: 14),
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
                    if (player.hasLyrics && player.lyricsSourceText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          player.lyricsSourceText,
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
        if (player.isLoadingLyrics) {
          body = Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    color: colors.palette.cyan,
                    borderRadius: BorderRadius.circular(2),
                  ),
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
        } else if (player.showLyricsEmptyState) {
          body = Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.text_snippet_outlined, size: 40, color: colors.palette.textDisabled),
                const SizedBox(height: 10),
                Text(
                  player.lyricsEmptyText,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textMuted),
                ),
              ],
            ),
          );
        } else if (player.hasSyncedLyrics) {
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
              valueListenable: player.currentLyricIndex,
              builder: (context, current, _) {
                _follow(current);
                final lines = player.lyricLines;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(top: 24, bottom: 120),
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    final key = _lineKeys.putIfAbsent(i, GlobalKey.new);
                    if (line.isBlank) return SizedBox(key: key, height: 14);
                    return _LyricLine(
                      key: key,
                      text: line.text,
                      active: line.isActive,
                      past: line.isPast,
                      centered: widget.centered,
                      onTap: () => player.seekToLyric(line),
                    );
                  },
                );
              },
            ),
          );
        } else {
          body = SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 80),
            child: SelectableText(
              player.plainLyricsText ?? '',
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
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final opacity = widget.active ? 1.0 : (_hover ? 0.85 : (widget.past ? 0.35 : 0.55));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 16, 6),
          child: AnimatedOpacity(
            opacity: opacity,
            duration: const Duration(milliseconds: 330),
            child: AnimatedScale(
              scale: widget.active ? 1.06 : 1,
              alignment: widget.centered ? Alignment.center : Alignment.centerLeft,
              duration: const Duration(milliseconds: 330),
              curve: Curves.easeOutCubic,
              child: Text(
                widget.text,
                textAlign: widget.centered ? TextAlign.center : TextAlign.start,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 26 / 19,
                  color: context.colors.textMain,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The wide layout's queue page: the title with the number of tracks, Clear and Close, and a glass panel with the
/// queue on the left and the lyrics on the right.
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
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
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
                          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: colors.textMain),
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
                              TagBadge(context.tr('NowPlaying'), color: colors.accent),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: colors.danger),
                    onPressed: count == 0 ? null : player.clearQueue,
                    icon: Icon(Icons.delete_outline_rounded, size: 18, color: count == 0 ? null : colors.danger),
                    label: Text(context.tr('ClearQueue')),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: player.closeQueue,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: Text(context.tr('Close')),
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
                            Container(width: 1, color: colors.tagBackground),
                            const Expanded(
                              child: Padding(padding: EdgeInsets.fromLTRB(24, 20, 24, 0), child: LyricsView()),
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
