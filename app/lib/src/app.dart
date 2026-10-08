// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_scope.dart';
import 'debug/ui_automation_server.dart';
import 'layouts/phone_layout.dart';
import 'layouts/wide_layout.dart';
import 'localization.dart';
import 'platform.dart';
import 'theme/app_theme.dart';
import 'view_models/app_section.dart';
import 'view_models/main_view_model.dart';

/// The root widget: theme, language, the keyboard and remote shortcuts, the back button, and the layout for the screen.
class WiretuneApp extends StatefulWidget {
  const WiretuneApp({super.key, required this.vm});

  final MainViewModel vm;

  /// Below this width (or on a phone held upright) the phone layout is used; a TV always gets the wide one.
  static const double phoneLayoutWidth = 720;

  @override
  State<WiretuneApp> createState() => _WiretuneAppState();
}

class _WiretuneAppState extends State<WiretuneApp> {
  final Map<(bool, AppSection, bool), ThemeData> _themes = {};

  // The accent follows the section, so a theme is built once per (light, section) and reused.
  ThemeData _theme(bool light, AppSection section, bool isTv) => _themes.putIfAbsent((
    light,
    section,
    isTv,
  ), () => buildTheme(light: light, section: section, isTv: isTv, desktopFonts: AppPlatform.current.isDesktop));

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final platform = AppPlatform.current;
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final light = vm.isLight;
        return LanguageScope(
          language: vm.language,
          child: AppScope(
            vm: vm,
            child: RepaintBoundary(
              key: UiAutomationServer.screenshotKey,
              child: MaterialApp(
                title: 'Wiretune',
                debugShowCheckedModeBanner: false,
                showPerformanceOverlay: vm.showPerformanceStats,
                theme: _theme(light, vm.selectedSection, platform.isTv),
                themeAnimationDuration: const Duration(milliseconds: 350),
                shortcuts: {
                  ...WidgetsApp.defaultShortcuts,
                  // TV remotes: the centre button and the media keys.
                  const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
                  const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
                  const SingleActivator(LogicalKeyboardKey.mediaPlayPause): const _MediaIntent(_MediaCommand.toggle),
                  const SingleActivator(LogicalKeyboardKey.mediaPlay): const _MediaIntent(_MediaCommand.play),
                  const SingleActivator(LogicalKeyboardKey.mediaPause): const _MediaIntent(_MediaCommand.pause),
                  const SingleActivator(LogicalKeyboardKey.mediaStop): const _MediaIntent(_MediaCommand.stop),
                  const SingleActivator(LogicalKeyboardKey.mediaTrackNext): const _MediaIntent(_MediaCommand.next),
                  const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): const _MediaIntent(
                    _MediaCommand.previous,
                  ),
                  const SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(),
                },
                actions: {
                  ...WidgetsApp.defaultActions,
                  _MediaIntent: CallbackAction<_MediaIntent>(onInvoke: (intent) => _runMedia(intent.command)),
                  _BackIntent: CallbackAction<_BackIntent>(onInvoke: (_) => _goBack()),
                },
                home: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: (light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light).copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                    systemNavigationBarContrastEnforced: false,
                  ),
                  child: PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) _goBack();
                    },
                    child: const _LayoutSwitch(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _runMedia(_MediaCommand command) {
    final player = widget.vm.player;
    switch (command) {
      case _MediaCommand.toggle:
        player.togglePlayPause();
      case _MediaCommand.play:
        player.play();
      case _MediaCommand.pause:
        player.pause();
      case _MediaCommand.stop:
        player.stop();
      case _MediaCommand.next:
        player.nextTrack();
      case _MediaCommand.previous:
        player.previousTrack();
    }
  }

  /// The view model closes a dialog, the full-screen player, a detail page or returns to the previous tab; when nothing
  /// is left, a phone or TV leaves the app (playback goes on in the background), a desktop window stays.
  void _goBack() {
    if (widget.vm.tryNavigateBack()) return;
    if (!AppPlatform.current.isDesktop) SystemNavigator.pop();
  }
}

class _LayoutSwitch extends StatelessWidget {
  const _LayoutSwitch();

  @override
  Widget build(BuildContext context) {
    final platform = AppPlatform.current;
    final size = MediaQuery.sizeOf(context);
    final phone =
        !platform.isTv && (size.width < WiretuneApp.phoneLayoutWidth || (platform.isMobile && size.shortestSide < 600));
    return phone ? const PhoneLayout() : const WideLayout();
  }
}

enum _MediaCommand { toggle, play, pause, stop, next, previous }

class _MediaIntent extends Intent {
  const _MediaIntent(this.command);

  final _MediaCommand command;
}

class _BackIntent extends Intent {
  const _BackIntent();
}
