// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../localization.dart';
import '../theme/app_theme.dart';
import 'page_parts.dart';

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

/// The accent-filled, glowing "Play" pill and its glass "Shuffle" partner, and after them [trailing] (a list's
/// download button); on a phone the two are round and show their icons alone.
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({super.key, this.onPlay, this.onShuffle, this.trailing});

  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playLabel = context.tr('Play');
    final shuffleLabel = context.tr('Shuffle');
    // On a phone the same buttons as round icons, as tall as the header's other buttons (the tooltips name them), so
    // that those fit beside.
    final phone = PhoneChrome.isPhone(context);
    final size = phone ? const Size.square(PhoneChrome.controlHeight) : const Size(0, 46);
    final padding = phone ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 24);
    final OutlinedBorder? round = phone ? const CircleBorder() : null;
    const text = TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.1);
    Widget label(String value) => FittedBox(fit: BoxFit.scaleDown, child: Text(value, maxLines: 1, softWrap: false));
    const playIcon = Icon(Icons.play_arrow_rounded, size: 22);
    final shuffleIcon = Icon(Icons.shuffle_rounded, size: 20, color: onShuffle == null ? null : colors.accent);
    final playStyle = FilledButton.styleFrom(
      minimumSize: size,
      fixedSize: phone ? size : null,
      padding: padding,
      textStyle: text,
      shape: round,
      tapTargetSize: phone ? MaterialTapTargetSize.shrinkWrap : null,
    );
    final shuffleStyle = OutlinedButton.styleFrom(
      minimumSize: size,
      fixedSize: phone ? size : null,
      padding: padding,
      textStyle: text,
      shape: round,
      tapTargetSize: phone ? MaterialTapTargetSize.shrinkWrap : null,
    );
    final play = PopEffect(
      enabled: onPlay != null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: onPlay == null ? const [] : colors.accentGlow(),
        ),
        child: phone
            ? Tooltip(
                message: playLabel,
                child: FilledButton(style: playStyle, onPressed: onPlay, child: playIcon),
              )
            : FilledButton.icon(style: playStyle, onPressed: onPlay, icon: playIcon, label: label(playLabel)),
      ),
    );
    final shuffle = PopEffect(
      enabled: onShuffle != null,
      child: phone
          ? Tooltip(
              message: shuffleLabel,
              child: OutlinedButton(style: shuffleStyle, onPressed: onShuffle, child: shuffleIcon),
            )
          : OutlinedButton.icon(
              style: shuffleStyle,
              onPressed: onShuffle,
              icon: shuffleIcon,
              label: label(shuffleLabel),
            ),
    );
    if (phone) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          play,
          const SizedBox(width: 10),
          shuffle,
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      );
    }
    return Wrap(spacing: 12, runSpacing: 8, children: [play, shuffle, ?trailing]);
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
