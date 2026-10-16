// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'buttons.dart';

/// A text that acts as a link (artist and album names): [hoverColor] under the mouse or the keyboard's focus, else
/// underlined.
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, this.onTap, this.style, this.hoverColor});

  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    final base = style ?? TextStyle(fontSize: 13, color: context.colors.textMuted);
    Text label(TextStyle style) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (onTap == null) return label(base);
    return Pressable(
      onPressed: onTap,
      builder: (context, lit) => label(
        !lit
            ? base
            : hoverColor != null
            ? base.copyWith(color: hoverColor)
            : base.copyWith(decoration: TextDecoration.underline, decorationColor: base.color),
      ),
    );
  }
}

/// A track's artists as links, one per name ("Future, Lil Durk"): the one under the mouse opens. Focused by the
/// keyboard or a remote, it opens the main artist, which it then shows lit. One artist is a plain [LinkText].
class ArtistLinks extends StatefulWidget {
  const ArtistLinks(this.names, {super.key, required this.onOpen, this.style, this.hoverColor});

  final List<String> names;
  final ValueChanged<String> onOpen;
  final TextStyle? style;
  final Color? hoverColor;

  @override
  State<ArtistLinks> createState() => _ArtistLinksState();
}

class _ArtistLinksState extends State<ArtistLinks> {
  int? _hovered;
  List<TapGestureRecognizer> _taps = const [];

  @override
  void dispose() {
    for (final tap in _taps) {
      tap.dispose();
    }
    super.dispose();
  }

  List<TapGestureRecognizer> _recognizers() {
    if (_taps.length != widget.names.length) {
      for (final tap in _taps) {
        tap.dispose();
      }
      _taps = [for (var i = 0; i < widget.names.length; i++) TapGestureRecognizer()];
    }
    for (final (i, tap) in _taps.indexed) {
      tap.onTap = () => widget.onOpen(widget.names[i]);
    }
    return _taps;
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    if (names.length < 2) {
      return LinkText(
        names.firstOrNull ?? '',
        onTap: names.isEmpty ? null : () => widget.onOpen(names.first),
        style: widget.style,
        hoverColor: widget.hoverColor,
      );
    }
    final base = widget.style ?? TextStyle(fontSize: 13, color: context.colors.textMuted);
    final lit = widget.hoverColor != null
        ? base.copyWith(color: widget.hoverColor)
        : base.copyWith(decoration: TextDecoration.underline, decorationColor: base.color);
    final taps = _recognizers();
    return Pressable(
      onPressed: () => widget.onOpen(names.first),
      builder: (context, active) => Text.rich(
        TextSpan(
          children: [
            for (final (i, name) in names.indexed) ...[
              if (i > 0) const TextSpan(text: ', '),
              TextSpan(
                text: name,
                style: (_hovered ?? (active ? 0 : null)) == i ? lit : null,
                recognizer: taps[i],
                onEnter: (_) => setState(() => _hovered = i),
                onExit: (_) => setState(() => _hovered = _hovered == i ? null : _hovered),
              ),
            ],
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      ),
    );
  }
}
