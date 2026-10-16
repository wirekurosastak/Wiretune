// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import 'buttons.dart';
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 20),
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
          if (actions.isNotEmpty)
            Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
        ],
      ),
    );
  }
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
    return SafeArea(
      bottom: false,
      child: Column(
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
                        tooltip: context.tr('Search'),
                        onPressed: vm.openSearch,
                        icon: Icon(Icons.search_rounded, size: 24, color: colors.textMain),
                      ),
                    ),
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      tooltip: context.tr('NavSettings'),
                      onPressed: () => vm.navigateTo(AppSection.settings),
                      icon: Icon(
                        vm.isUserLoggedIn ? Icons.account_circle : Icons.account_circle_outlined,
                        size: 26,
                        color: vm.isUserLoggedIn ? colors.textMain : colors.textMuted,
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
              // One line, all one height: the play and shuffle pills (with a list's download) at their size, the other
              // buttons (the sort first, a genre filter, a new playlist) sharing the rest.
              child: SizedBox(
                height: PhoneChrome.controlHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, action) in actions.indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      if (action is PlayShuffleButtons) Center(child: action) else Expanded(child: action),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Marks the phone layout, whose pages draw the phone's headers and full-width buttons.
class PhoneChrome extends InheritedWidget {
  const PhoneChrome({super.key, required super.child});

  static bool isPhone(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PhoneChrome>() != null;

  /// The height of every button in a phone's page and detail headers (play, shuffle, the sort, a filter, a download,
  /// hide or delete), so a line of them is even and the lists below start at the same place.
  static const double controlHeight = 44;

  @override
  bool updateShouldNotify(PhoneChrome oldWidget) => false;
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
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // Centers the empty state block naturally on the screen.
    // Anchoring to a consistent reference height (260px) guarantees that:
    // 1. Every empty page (Favorites, Playlists, Albums, etc.) has its icon, title and hint at the exact same vertical level.
    // 2. The block sits comfortably in the true visual center of the window instead of sinking towards the bottom.
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight;
        final usableHeight = availableHeight - bottomInset;
        final topSpacing = usableHeight.isFinite ? math.max(20.0, (usableHeight - 260.0) / 2) : 48.0;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(32, topSpacing, 32, 32 + bottomInset),
          child: Align(
            alignment: Alignment.topCenter,
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
      },
    );
  }
}

/// The space at the end of a page: a little air, and the room the phone's floating bars cover.
class PageEndSpace extends StatelessWidget {
  const PageEndSpace({super.key});

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom));
}

/// A rounded card of glass: a faint sheen from its top-left corner and a hairline edge.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding, this.hoverColor, this.opaque = false});

  final Widget child;

  /// The space inside the card: 24 px, 18 on a phone, unless given.
  final EdgeInsets? padding;

  /// The border's colour under the mouse (the section's accent); none keeps it unchanged.
  final Color? hoverColor;

  /// A solid card with the panels' edge (the settings), rather than translucent glass.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(Radii.card + 4);
    return _HoverBorder(
      hoverColor: hoverColor,
      builder: (border) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: opaque ? colors.palette.modal : null,
          gradient: opaque
              ? null
              : LinearGradient(
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
            side: BorderSide(color: opaque ? colors.palette.panelBorder : border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding ?? EdgeInsets.all(PhoneChrome.isPhone(context) ? 18 : 24), child: child),
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
