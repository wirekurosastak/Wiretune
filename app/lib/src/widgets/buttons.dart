// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/player_view_model.dart';
import 'page_parts.dart';
import 'player_controls.dart';

/// Something to press that isn't a Material button (a link, a column header, a back link, the player's cover): the
/// whole area [builder] draws takes the click, Tab or a TV remote's arrows reach it and Enter or select presses it,
/// and the keyboard's focus lights it up as the mouse does ([builder]'s `lit`).
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.onPressed, required this.builder});

  /// Null leaves it inert: no click, no focus.
  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, bool lit) builder;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    return FocusableActionDetector(
      enabled: onPressed != null,
      mouseCursor: onPressed != null ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (value) => setState(() => _hover = value),
      onShowFocusHighlight: (value) => setState(() => _focus = value),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: onPressed != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: widget.builder(context, onPressed != null && (_hover || _focus)),
        ),
      ),
    );
  }
}

/// Gives a little under the finger or the click, as a quick answer to the press: a Play ([PopEffect.press]) and the
/// filled buttons that start something (New playlist, Connect, a dialog's own). A finger that moves on (a scroll) lets
/// go of it. It takes no part in deciding what the touch is: the button under it still gets the tap.
class PressShrink extends StatefulWidget {
  const PressShrink({super.key, required this.child, this.scale = 0.96});

  final Widget child;

  /// How small it gets: a round Play gives more (0.92) than a wide button.
  final double scale;

  @override
  State<PressShrink> createState() => _PressShrinkState();
}

class _PressShrinkState extends State<PressShrink> {
  bool _pressed = false;
  Offset _down = Offset.zero;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      // A button that can't be pressed (a Save while it saves) doesn't give.
      final child = widget.child;
      if (child is ButtonStyleButton && !child.enabled) return;
      _down = event.position;
      setState(() => _pressed = true);
    },
    onPointerMove: (event) {
      if (_pressed && (event.position - _down).distance > kTouchSlop) setState(() => _pressed = false);
    },
    onPointerUp: (_) => setState(() => _pressed = false),
    onPointerCancel: (_) => setState(() => _pressed = false),
    child: AnimatedScale(
      scale: _pressed ? widget.scale : 1,
      // Quick to give, as a press is.
      duration: Duration(milliseconds: _pressed ? 110 : 200),
      curve: Curves.easeOutCubic,
      child: widget.child,
    ),
  );
}

/// Lifts [child] and makes it a little larger under the mouse; with a [glowColor], a pill of its glow rises behind it.
/// A Play ([press]) also gives under the finger or the click ([PressShrink]), as the players' round Play does.
class PopEffect extends StatefulWidget {
  const PopEffect({super.key, required this.child, this.enabled = true, this.glowColor, this.press = false});

  final Widget child;
  final bool enabled;
  final Color? glowColor;
  final bool press;

  @override
  State<PopEffect> createState() => _PopEffectState();
}

class _PopEffectState extends State<PopEffect> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final glow = widget.glowColor;
    final scale = _hover ? 1.05 : 1.0;
    final effect = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        transformAlignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(0.0, _hover ? -3.0 : 0.0, 0.0, 1.0)
          ..scaleByDouble(scale, scale, 1.0, 1.0),
        decoration: glow != null && _hover
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.pill),
                boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.45), blurRadius: 18, spreadRadius: -2)],
              )
            : null,
        child: widget.child,
      ),
    );
    return widget.press ? PressShrink(scale: 0.92, child: effect) : effect;
  }
}

/// A list's accent-filled, glowing "Play" and the player's shuffle switch beside it ([ShuffleSwitch]: Play starts
/// the list from its first track, or from any while shuffle is on), then the queue's two ([playNext], [addToQueue]), its
/// way into a playlist ([addToPlaylist]), the list's [download] and its hide or delete ([remove]): the order of its menu
/// (`ListMenu`). On a phone Play is round, the largest, at the right edge, and the rest follow it leftwards in that
/// order: shuffle beside it, then on an album's, an artist's or a playlist's page (the pages with a way into a
/// playlist) the queue's two, the playlist and the download, spread over the line to the left edge, as in Spotify;
/// hide or delete is in the top bar's ⋮ there (`ListMenu.topBarButton`). While the queue is [tracks], Play pauses and resumes it ([ListPlayButton]).
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({
    super.key,
    this.tracks = const [],
    this.onPlay,
    this.playNext,
    this.addToQueue,
    this.addToPlaylist,
    this.download,
    this.remove,
  });

  final List<Track> tracks;

  /// Null for a list with nothing to play: Play and the switch are then off.
  final VoidCallback? onPlay;
  final Widget? playNext;
  final Widget? addToQueue;
  final Widget? addToPlaylist;
  final Widget? download;
  final Widget? remove;

  @override
  Widget build(BuildContext context) {
    final play = ListPlayButton(tracks: tracks, onPlay: onPlay);
    final shuffle = ShuffleSwitch(enabled: onPlay != null);
    if (PhoneChrome.isPhone(context)) {
      final icons = [?download, ?addToPlaylist, ?addToQueue, ?playNext]; // leftwards from shuffle
      final page = addToPlaylist != null;
      return Row(
        mainAxisSize: page ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (page)
            // 10 apart, closer on a narrow phone, where the queue's two leave no room for more.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: icons.length * PhoneChrome.controlHeight + (icons.length - 1) * 10,
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: icons),
                ),
              ),
            )
          else if (download != null) ...[
            download!,
            const SizedBox(width: 10),
          ],
          shuffle,
          const SizedBox(width: 10),
          play,
        ],
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [play, shuffle, ?playNext, ?addToQueue, ?addToPlaylist, ?download, ?remove],
    );
  }

  static const TextStyle _labelStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.1);

  static Widget _label(String value) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(value, maxLines: 1, softWrap: false));
}

/// The player's shuffle, as a switch beside a list's Play (the same one as in the player): the icon alone, glowing in
/// the accent with a dot under it while it is on; muted while off, until the mouse is over it.
class ShuffleSwitch extends StatefulWidget {
  const ShuffleSwitch({super.key, this.enabled = true});

  final bool enabled;

  @override
  State<ShuffleSwitch> createState() => _ShuffleSwitchState();
}

class _ShuffleSwitchState extends State<ShuffleSwitch> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(listenable: player, builder: (context, _) => _build(context, player));
  }

  Widget _build(BuildContext context, PlayerViewModel player) {
    final colors = context.colors;
    final enabled = widget.enabled;
    final on = player.isShuffle && enabled;
    final color = !enabled
        ? colors.palette.textDisabled
        : (on ? colors.accent : (_hover ? colors.textMain : colors.textMuted));
    final glow = on || (_hover && enabled) ? [Shadow(color: color.withValues(alpha: 0.8), blurRadius: 14)] : null;
    // As tall as Play and the icons beside it.
    final dimension = PhoneChrome.isPhone(context) ? PhoneChrome.controlHeight : 46.0;
    return PopEffect(
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: SizedBox.square(
          dimension: dimension,
          child: IconButton(
            tooltip: context.tr(shuffleTip(player)),
            // No ripple or hover circle, which would make it look like a button again; a TV remote's focus still shows.
            style: ButtonStyle(
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused) ? Theme.of(context).focusColor : Colors.transparent,
              ),
            ),
            onPressed: enabled ? player.toggleShuffle : null,
            icon: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(Icons.shuffle_rounded, size: 24, color: color, shadows: glow),
                if (on)
                  Positioned(
                    bottom: -9,
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        boxShadow: colors.accentGlow(0.6),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A list's accent-filled, glowing Play button (round and [PhoneChrome.playSize] on a phone): plays the list with
/// [onPlay], or, while the queue is [tracks] (see `PlayerViewModel.isQueueOf`), pauses and resumes it, showing which it
/// will do.
class ListPlayButton extends StatelessWidget {
  const ListPlayButton({super.key, required this.tracks, required this.onPlay});

  final List<Track> tracks;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    return ListenableBuilder(listenable: player, builder: (context, _) => _build(context, player));
  }

  Widget _build(BuildContext context, PlayerViewModel player) {
    final colors = context.colors;
    final phone = PhoneChrome.isPhone(context);
    final size = phone ? const Size.square(PhoneChrome.playSize) : const Size(0, 46);
    final current = onPlay != null && player.isQueueOf(tracks);
    final playing = current && player.isPlaying;
    final onPressed = current ? player.togglePlayPause : onPlay;
    final label = context.tr(playing ? 'Pause' : 'Play');
    final icon = PlayPauseIcon(playing: playing, size: phone ? 26 : 22);
    final style = FilledButton.styleFrom(
      minimumSize: size,
      fixedSize: phone ? size : null,
      padding: phone ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 24),
      textStyle: PlayShuffleButtons._labelStyle,
      shape: phone ? const CircleBorder() : null,
      tapTargetSize: phone ? MaterialTapTargetSize.shrinkWrap : null,
    );
    return PopEffect(
      enabled: onPressed != null,
      press: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: onPressed == null ? const [] : colors.accentGlow(),
        ),
        child: phone
            ? Tooltip(
                message: label,
                child: FilledButton(style: style, onPressed: onPressed, child: icon),
              )
            : FilledButton.icon(
                style: style,
                onPressed: onPressed,
                icon: icon,
                label: PlayShuffleButtons._label(label),
              ),
      ),
    );
  }
}

/// A round icon button beside a detail page's play and shuffle (download, hide, delete), named by its tooltip; [color]
/// tints it (the accent for a kept download, the danger colour for a deletion), else it is muted until the mouse is
/// over it. With a [progress] (0 to 1) a ring around it fills up.
class HeaderIconButton extends StatefulWidget {
  const HeaderIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    this.progress,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
  final double? progress;

  @override
  State<HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<HeaderIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // As tall as the play and shuffle pills beside it.
    final dimension = PhoneChrome.isPhone(context) ? PhoneChrome.controlHeight : 46.0;
    final iconColor = widget.color ?? (_hover ? colors.textMain : colors.textMuted);
    final progress = widget.progress;
    final button = IconButton(
      tooltip: widget.tooltip,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      focusColor: Colors.transparent,
      style: IconButton.styleFrom(
        side: BorderSide.none,
        backgroundColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
      onPressed: widget.onPressed,
      icon: Icon(
        widget.icon,
        size: 22,
        color: iconColor,
        shadows: _hover ? [BoxShadow(color: iconColor.withValues(alpha: 0.7), blurRadius: 14)] : null,
      ),
    );
    return PopEffect(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: SizedBox.square(
          dimension: dimension,
          child: progress == null
              ? button
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.square(
                      dimension: dimension,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 2.5,
                        color: colors.accent,
                        backgroundColor: colors.glassBorder,
                      ),
                    ),
                    button,
                  ],
                ),
        ),
      ),
    );
  }
}

/// A sort button's label ("ABC ↑"): the name, and the active one's direction as an arrow that turns round when the
/// order does.
class SortLabel extends StatelessWidget {
  const SortLabel(this.label, {super.key, required this.style});

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final up = label.endsWith(' ↑'), down = label.endsWith(' ↓');
    final name = up || down ? label.substring(0, label.length - 2) : label;
    final text = Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (!up && !down) return text;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: text),
          const SizedBox(width: 4),
          SortArrow(descending: down, size: (style.fontSize ?? 13) + 1, color: style.color),
        ],
      ),
    );
  }
}

/// The arrow of a sort's direction: up, turning round to point down when the order does.
class SortArrow extends StatelessWidget {
  const SortArrow({super.key, required this.descending, required this.size, this.color, this.shadows});

  final bool descending;
  final double size;
  final Color? color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: descending ? 0.5 : 0,
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutBack,
    child: Icon(Icons.north_rounded, size: size, color: color, shadows: shadows),
  );
}
