import 'package:flutter/widgets.dart';

import 'view_models/main_view_model.dart';

/// Hands the app's view model to every widget below it.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.vm, required super.child});

  final MainViewModel vm;

  static MainViewModel of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.vm;

  @override
  bool updateShouldNotify(AppScope oldWidget) => vm != oldWidget.vm;
}

extension AppScopeContext on BuildContext {
  MainViewModel get vm => AppScope.of(this);
}
