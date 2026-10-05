import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import 'devices.dart';

/// A page's title block: a big title, a line of details, and the page's actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (PhoneChrome.isPhone(context)) return _PhonePageHeader(title: title, subtitle: subtitle, actions: actions);
    return _wide(context);
  }

  Widget _wide(BuildContext context) {
    final colors = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 30, narrow ? 14 : 28, narrow ? 16 : 30, 20),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 34,
                  height: 1.1,
                  letterSpacing: -1.0,
                  fontWeight: FontWeight.w800,
                  color: colors.textMain,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: colors.textMuted),
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

/// The accent-filled, glowing "Play" pill and its glass "Shuffle" partner, and after them [trailing] (a list's
/// download button).
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({
    super.key,
    required this.playLabel,
    required this.shuffleLabel,
    this.onPlay,
    this.onShuffle,
    this.trailing,
  });

  final String playLabel;
  final String shuffleLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final phone = PhoneChrome.isPhone(context);
    // The phone's two full-width buttons are a little taller.
    final size = Size(0, phone ? 48 : 46);
    const text = TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.1);
    const padding = EdgeInsets.symmetric(horizontal: 26);
    final play = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: onPlay == null ? const [] : colors.accentGlow(),
      ),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: size, padding: padding, textStyle: text),
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow_rounded, size: 22),
        label: Text(playLabel),
      ),
    );
    final shuffle = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: size, padding: padding, textStyle: text),
      onPressed: onShuffle,
      icon: Icon(Icons.shuffle_rounded, size: 20, color: onShuffle == null ? null : colors.accent),
      label: Text(shuffleLabel),
    );
    if (phone) {
      return Row(
        children: [
          Expanded(child: play),
          const SizedBox(width: 10),
          Expanded(child: shuffle),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      );
    }
    return Wrap(spacing: 12, runSpacing: 8, children: [play, shuffle, ?trailing]);
  }
}

/// A message in place of a list that has nothing to show.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.hint, this.actions = const []});

  final IconData icon;
  final String title;
  final String? hint;

  /// Buttons under the message, side by side (wrapping on a narrow screen).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Scrolls when a short screen (a phone held sideways, a large font) has less room than the message needs.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32).copyWith(bottom: 32 + MediaQuery.paddingOf(context).bottom),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The icon in an orb of the accent: a soft halo, a glass disc and a thin ring.
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [colors.accent.withValues(alpha: 0.28), colors.accent.withValues(alpha: 0)],
                  ),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.palette.panel,
                    border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
                    boxShadow: colors.accentGlow(0.8),
                  ),
                  child: Icon(icon, size: 34, color: colors.accent),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: colors.textMain,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, height: 1.45, color: colors.textMuted),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 22),
                Wrap(spacing: 12, runSpacing: 10, alignment: WrapAlignment.center, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded card of glass: a faint sheen from its top-left corner and a hairline edge.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding, this.hoverColor});

  final Widget child;

  /// The space inside the card: 24 px, 18 on a phone, unless given.
  final EdgeInsets? padding;

  /// The border's colour under the mouse (the section's accent); none keeps it unchanged.
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(Radii.card + 4);
    return _HoverBorder(
      hoverColor: hoverColor,
      builder: (border) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.surface2, colors.surface1, colors.palette.glassBackground],
            stops: const [0, 0.35, 1],
          ),
        ),
        // A Material, so the ink of the tiles and buttons inside is painted on the card.
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding ?? EdgeInsets.all(PhoneChrome.isPhone(context) ? 18 : 24), child: child),
        ),
      ),
    );
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
      style: TextStyle(
        fontSize: 11.5,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w800,
        color: context.colors.textMuted,
      ),
    ),
  );
}

/// The space at the end of a page: a little air, and the room the phone's floating bars cover.
class PageEndSpace extends StatelessWidget {
  const PageEndSpace({super.key});

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom));
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

/// A small pill tinted with its colour: "ARTIST", "ALBUM", "TRACK", a counter.
class TagBadge extends StatelessWidget {
  const TagBadge(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      text,
      maxLines: 1,
      style: TextStyle(fontSize: 10, letterSpacing: 0.8, height: 1.4, fontWeight: FontWeight.w800, color: color),
    ),
  );
}

/// A framed glass card that rises a little, takes the [accent] edge and glows in it under the mouse.
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
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: _hover ? colors.surface2 : colors.surface1,
          borderRadius: BorderRadius.circular(Radii.card + 2),
          border: Border.all(color: _hover ? widget.accent.withValues(alpha: 0.7) : colors.glassBorder),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: widget.accent.withValues(alpha: 0.28),
                    blurRadius: 36,
                    spreadRadius: -10,
                    offset: const Offset(0, 16),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.card + 2),
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

/// The round play button of a tile: filled with a gradient of [color], over a glow of it.
class TilePlayButton extends StatelessWidget {
  const TilePlayButton({
    super.key,
    required this.color,
    required this.onPressed,
    required this.tooltip,
    this.size = 44,
  });

  final Color color;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? null : colors.palette.modal,
          gradient: enabled
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [colors.palette.hoverOf(color), color],
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: enabled ? color.withValues(alpha: 0.5) : colors.palette.shadow,
              blurRadius: 16,
              spreadRadius: -2,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Icon(
                Icons.play_arrow_rounded,
                size: size * 0.58,
                color: enabled ? colors.onAccent : colors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
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
                        style: TextStyle(
                          fontSize: 30,
                          letterSpacing: -0.8,
                          fontWeight: FontWeight.w800,
                          color: colors.textMain,
                        ),
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
                // The way to another device also while nothing plays here (no mini player then).
                const DevicesButton(dimension: 44, iconSize: 23),
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
