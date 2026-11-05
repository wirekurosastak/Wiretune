// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'page_parts.dart';

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
/// keyboard or a remote, it opens the main artist, which it then shows lit. One artist is a plain [LinkText]. On a
/// phone, where a finger would hit the name beside the one it meant, a tap opens the artists to choose from, as in
/// TIDAL.
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

  /// The artists, each with their picture where the library has it, to choose the one to open.
  Future<void> _choose(BuildContext context) async {
    final library = context.getInheritedWidgetOfExactType<AppScope>()?.vm.library;
    final chosen = await showChoiceSheet<String>(
      context,
      title: context.tr('ChooseArtist'),
      choices: [
        for (final name in widget.names)
          SheetChoice(
            name,
            name,
            picture: CoverImage(
              path: library?.getArtistByName(name)?.picturePath,
              size: 40,
              circle: true,
              placeholderIcon: Icons.person,
            ),
          ),
      ],
    );
    if (chosen != null) widget.onOpen(chosen);
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
    if (PhoneChrome.isPhone(context)) {
      return Pressable(
        onPressed: () => _choose(context),
        builder: (context, active) =>
            Text(names.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: active ? lit : base),
      );
    }
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
