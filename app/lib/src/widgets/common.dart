import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';

/// A page's title block: a big title, a line of details, and the page's actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.leading});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    if (PhoneChrome.isPhone(context)) return _PhonePageHeader(title: title, subtitle: subtitle, actions: actions);
    return _wide(context);
  }

  Widget _wide(BuildContext context) {
    final colors = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, narrow ? 12 : 24, narrow ? 16 : 28, 20),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: colors.textMain),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: colors.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) Wrap(spacing: 10, runSpacing: 8, children: actions),
        ],
      ),
    );
  }
}

/// The accent-filled "Play" button and its outlined "Shuffle" partner.
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({
    super.key,
    required this.playLabel,
    required this.shuffleLabel,
    this.onPlay,
    this.onShuffle,
  });

  final String playLabel;
  final String shuffleLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    if (PhoneChrome.isPhone(context)) {
      // The phone's two full-width buttons.
      const size = Size(0, 46);
      return Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: size),
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: Text(playLabel),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: size),
              onPressed: onShuffle,
              icon: const Icon(Icons.shuffle_rounded, size: 20),
              label: Text(shuffleLabel),
            ),
          ),
        ],
      );
    }
    return _wide(context);
  }

  Widget _wide(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 8,
    children: [
      FilledButton.icon(
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow_rounded, size: 18),
        label: Text(playLabel),
      ),
      OutlinedButton.icon(
        onPressed: onShuffle,
        icon: Icon(Icons.shuffle_rounded, size: 18, color: context.colors.accent),
        label: Text(shuffleLabel),
      ),
    ],
  );
}

/// A message in place of a list that has nothing to show.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Buttons under the message, side by side (wrapping on a narrow screen).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Scrolls when a short screen (a phone held sideways, a large font) has less room than the message needs.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: colors.surface1, shape: BoxShape.circle),
                child: Icon(icon, size: 40, color: colors.accent),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.textMain),
              ),
              if (hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textMuted),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(spacing: 12, runSpacing: 10, alignment: WrapAlignment.center, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded card on the glass surface.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(24), this.hoverColor});

  final Widget child;
  final EdgeInsets padding;

  /// The border's colour under the mouse (the section's accent); none keeps it unchanged.
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final card = _HoverBorder(
      hoverColor: hoverColor,
      builder: (border) => Material(
        // A Material (not a decorated box), so the ink of the tiles and buttons inside is painted on the card.
        color: colors.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
    return card;
  }
}

/// A small heading over a group of items ("ALBUMS", "LIBRARY").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(4, 16, 4, 12)});

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text.toUpperCase(),
      style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w900, color: context.colors.textMuted),
    ),
  );
}

/// A text that acts as a link (artist and album names in lists).
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, this.onTap, this.style});

  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? TextStyle(fontSize: 13, color: context.colors.textMuted);
    final label = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
    if (onTap == null) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: label),
    );
  }
}

/// A small label on the tag background: "ARTIST", "ALBUM", "TRACK", a counter.
class TagBadge extends StatelessWidget {
  const TagBadge(this.text, {super.key, required this.color, this.fontSize = 10});

  final String text;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: context.colors.tagBackground, borderRadius: BorderRadius.circular(4)),
    child: Text(
      text,
      maxLines: 1,
      style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, color: color),
    ),
  );
}

/// An album, artist or playlist tile: a framed card that rises a little and takes the [accent] border under the mouse.
class MetricCard extends StatefulWidget {
  const MetricCard({super.key, required this.child, required this.accent, required this.onTap, this.padding = 16});

  final Widget child;
  final Color accent;
  final VoidCallback onTap;
  final double padding;

  @override
  State<MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<MetricCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        transformAlignment: Alignment.center,
        transform: _hover
            ? (Matrix4.translationValues(0, -5, 0)..multiply(Matrix4.diagonal3Values(1.035, 1.035, 1)))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: colors.surface1,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _hover ? widget.accent : colors.glassBorder),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: widget.accent.withValues(alpha: 0.25),
                    blurRadius: 40,
                    spreadRadius: -10,
                    offset: const Offset(0, 20),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            child: Padding(padding: EdgeInsets.all(widget.padding), child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] with the border colour for the mouse's state.
class _HoverBorder extends StatefulWidget {
  const _HoverBorder({required this.hoverColor, required this.builder});

  final Color? hoverColor;
  final Widget Function(Color border) builder;

  @override
  State<_HoverBorder> createState() => _HoverBorderState();
}

class _HoverBorderState extends State<_HoverBorder> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final border = _hover && widget.hoverColor != null ? widget.hoverColor! : context.colors.glassBorder;
    if (widget.hoverColor == null) return widget.builder(border);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(border),
    );
  }
}

/// The square, accent-filled play button of a tile (32 px, 4 px corners).
class TilePlayButton extends StatelessWidget {
  const TilePlayButton({
    super.key,
    required this.color,
    required this.onPressed,
    required this.tooltip,
    this.size = 32,
  });

  final Color color;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: SizedBox(
      width: size,
      height: size,
      child: Material(
        color: onPressed == null ? context.colors.surface2 : color,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onPressed,
          child: Icon(Icons.play_arrow_rounded, size: size * 0.55, color: context.colors.onAccent),
        ),
      ),
    ),
  );
}

/// Marks the phone layout, whose pages draw the phone's headers and full-width buttons.
class PhoneChrome extends InheritedWidget {
  const PhoneChrome({super.key, required super.child});

  static bool isPhone(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PhoneChrome>() != null;

  @override
  bool updateShouldNotify(PhoneChrome oldWidget) => false;
}

/// A phone page's header: the title (28 px) and its details, the search and the account buttons, and the page's
/// buttons below.
class _PhonePageHeader extends StatelessWidget {
  const _PhonePageHeader({required this.title, required this.subtitle, required this.actions});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: colors.textMain),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: colors.textMuted),
                        ),
                    ],
                  ),
                ),
                if (vm.selectedSection != AppSection.settings)
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      tooltip: context.tr('SearchPlaceholderShort'),
                      onPressed: vm.openSearch,
                      icon: Icon(Icons.search_rounded, size: 24, color: colors.textMain),
                    ),
                  ),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    tooltip: context.tr('TipAccountSettings'),
                    onPressed: () => vm.navigateTo(AppSection.settings),
                    icon: Icon(
                      vm.isUserLoggedIn ? Icons.account_circle : Icons.account_circle_outlined,
                      size: 26,
                      color: vm.isUserLoggedIn ? colors.accent : colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: actions.length == 1 ? actions.first : Wrap(spacing: 10, runSpacing: 8, children: actions),
          ),
      ],
    );
  }
}
