// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform.dart';

/// The parts of the wide layout a TV remote moves between.
enum TvArea { header, sidebar, content, player }

/// On a TV, gives the wide layout's [TvArea]s to the remote's arrows: within an area they move to the nearest item in
/// their direction, as anywhere; at an area's edge they go to the next area that way, to the item it had last (the
/// page's place, the sidebar's section), or its first. Flutter alone picks the nearest item on the whole screen, which
/// jumps from the sidebar into the middle of a list and back. Elsewhere [child] alone.
class TvFocusAreas extends StatefulWidget {
  const TvFocusAreas({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusAreas> createState() => _TvFocusAreasState();
}

class _TvFocusAreasState extends State<TvFocusAreas> {
  late final Map<TvArea, FocusScopeNode> _scopes = {
    for (final area in TvArea.values) area: FocusScopeNode(debugLabel: 'TV ${area.name}'),
  };

  @override
  void initState() {
    super.initState();
    if (AppPlatform.current.isTv) FocusManager.instance.addListener(_recover);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_recover);
    for (final scope in _scopes.values) {
      scope.dispose();
    }
    super.dispose();
  }

  /// The focused item went (a page opened or closed under it), and with it the focus, to its area: it goes on to the
  /// area's first item once the new page is there, so that something is always lit.
  void _recover() {
    final area = _scopes.entries.where((e) => e.value == FocusManager.instance.primaryFocus).firstOrNull?.key;
    if (area == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && FocusManager.instance.primaryFocus == _scopes[area]) _enter(area);
    });
  }

  /// Where an arrow leaves [area] for, in [direction]; null: it stays.
  static TvArea? _next(TvArea area, TraversalDirection direction) => switch ((area, direction)) {
    (TvArea.header, TraversalDirection.down) => TvArea.content,
    (TvArea.sidebar, TraversalDirection.right) => TvArea.content,
    (TvArea.sidebar, TraversalDirection.up) => TvArea.header,
    (TvArea.sidebar, TraversalDirection.down) => TvArea.player,
    (TvArea.content, TraversalDirection.left) => TvArea.sidebar,
    (TvArea.content, TraversalDirection.up) => TvArea.header,
    (TvArea.content, TraversalDirection.down) => TvArea.player,
    (TvArea.player, TraversalDirection.up) => TvArea.content,
    (TvArea.player, TraversalDirection.left) => TvArea.sidebar,
    _ => null,
  };

  /// Moves within [area], or on to the next area at its edge.
  void _move(TvArea area, TraversalDirection direction) {
    final current = FocusManager.instance.primaryFocus;
    if (current != null && current.focusInDirection(direction)) return;
    var next = _next(area, direction);
    // An area with nothing to focus (a page without buttons) is passed over.
    while (next != null && !_enter(next)) {
      next = _next(next, direction);
    }
  }

  /// Focuses the item [area] had last, else its first; false when it has none.
  bool _enter(TvArea area) {
    final scope = _scopes[area]!;
    final last = scope.focusedChild;
    final target = last != null && last.context != null && last.canRequestFocus
        ? last
        : ReadingOrderTraversalPolicy().findFirstFocus(scope, ignoreCurrentFocus: true);
    if (target == null || target == scope) return false;
    target.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) => _TvAreasScope(state: this, child: widget.child);
}

class _TvAreasScope extends InheritedWidget {
  const _TvAreasScope({required this.state, required super.child});

  final _TvFocusAreasState state;

  @override
  bool updateShouldNotify(_TvAreasScope oldWidget) => state != oldWidget.state;
}

/// One [TvArea] of the layout (see [TvFocusAreas]); off a TV, [child] alone.
class TvFocusArea extends StatelessWidget {
  const TvFocusArea({super.key, required this.area, required this.child});

  final TvArea area;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final areas = context.getInheritedWidgetOfExactType<_TvAreasScope>()?.state;
    if (areas == null || !AppPlatform.current.isTv) return child;
    return FocusScope(
      node: areas._scopes[area],
      child: Actions(
        actions: {
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (intent) {
              areas._move(area, intent.direction);
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

/// On a TV, lets the remote's arrows leave a text field: Up and Down always (a field is one line), Left and Right once
/// the cursor is at that end, so the button beside a field is in reach. The field keeps them for its cursor otherwise.
class TvTextFieldKeys extends StatelessWidget {
  const TvTextFieldKeys({super.key, required this.child});

  final Widget child;

  static KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (event is KeyUpEvent || focused == null) return KeyEventResult.ignored;
    final field = focused.findAncestorStateOfType<EditableTextState>();
    if (field == null) return KeyEventResult.ignored;
    // A selection is the field's to collapse; a cursor at an end (or none) lets the arrow out that way.
    final value = field.textEditingValue;
    final caret = value.selection.isCollapsed ? value.selection.baseOffset : null;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft when caret != null && caret <= 0 => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight when caret != null && (caret < 0 || caret >= value.text.length) =>
        TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    // From outside the field: its own action would move within the area alone, never on to the next.
    Actions.maybeInvoke(field.context, DirectionalFocusIntent(direction, ignoreTextFields: false));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: child);
}
