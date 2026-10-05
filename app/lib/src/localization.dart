// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/widgets.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Rebuilds the widgets that show text when the interface language changes. A widget that calls [tr] or [trf]
/// depends on it, so only those rebuild, and nothing loses its state.
class LanguageScope extends InheritedWidget {
  const LanguageScope({super.key, required this.language, required super.child});

  final String language;

  @override
  bool updateShouldNotify(LanguageScope oldWidget) => language != oldWidget.language;
}

extension Translate on BuildContext {
  /// The text of [key] in the active language.
  String tr(String key) {
    dependOnInheritedWidgetOfExactType<LanguageScope>();
    return Localizer.get(key);
  }

  /// The text of [key] with `{0}`, `{1}`… filled in from [args].
  String trf(String key, List<Object?> args) {
    dependOnInheritedWidgetOfExactType<LanguageScope>();
    return Localizer.format(key, args);
  }
}
