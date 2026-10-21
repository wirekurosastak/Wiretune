// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

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

/// Lifts [child] and makes it a little larger under the mouse; with a [glowColor], a pill of its glow rises behind it.
class PopEffect extends StatefulWidget {
  const PopEffect({super.key, required this.child, this.enabled = true, this.glowColor});

  final Widget child;
  final bool enabled;
  final Color? glowColor;

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
    return MouseRegion(
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
                borderRadius: BorderRadius.circular(999),
                boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.45), blurRadius: 18, spreadRadius: -2)],
              )
            : null,
        child: widget.child,
      ),
    );
  }
}

/// A list's accent-filled, glowing "Play" and the player's shuffle switch beside it ([ShuffleSwitch]: Play starts
/// the list from its first track, or from any while shuffle is on), then the list's [download] and [menu]. On a phone
/// Play is round, the largest, at the right edge and shuffle beside it; an album's, an artist's or a
/// playlist's (the pages with a [menu]) spread over the line, the menu and the download at the left edge, as in
/// Spotify. While the queue is [tracks], Play pauses and resumes it ([ListPlayButton]).
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({super.key, this.tracks = const [], this.onPlay, this.download, this.menu});

  final List<Track> tracks;

  /// Null for a list with nothing to play: Play and the switch are then off.
  final VoidCallback? onPlay;
  final Widget? download;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final play = ListPlayButton(tracks: tracks, onPlay: onPlay);
    final shuffle = ShuffleSwitch(enabled: onPlay != null);
    if (PhoneChrome.isPhone(context)) {
      final left = [?menu, ?download];
      return Row(
        mainAxisSize: menu == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (menu != null) ...[
            for (final (i, button) in left.indexed) ...[if (i > 0) const SizedBox(width: 10), button],
            const Spacer(),
          ] else
            for (final button in left) ...[button, const SizedBox(width: 10)],
          shuffle,
          const SizedBox(width: 10),
          play,
        ],
      );
    }
    return Wrap(spacing: 12, runSpacing: 8, children: [play, shuffle, ?download, ?menu]);
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
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
