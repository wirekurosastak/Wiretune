// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

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
                    child: vm.startupError != null
                        ? _StartupErrorPage(message: vm.startupError!)
                        : Stack(
                            children: [
                              const Positioned.fill(child: _LayoutSwitch()),
                              _NoticeHost(vm: vm),
                            ],
                          ),
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

/// Shows the latest [AppNotice] at the top of the screen for a few seconds (an error a little longer), over either
/// layout. It takes no focus, so a TV remote stays where it was; a tap or its close button dismisses it.
class _NoticeHost extends StatefulWidget {
  const _NoticeHost({required this.vm});

  final MainViewModel vm;

  @override
  State<_NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<_NoticeHost> {
  AppNotice? _notice;
  Timer? _hide;

  void Function()? _unsubscribe;

  @override
  void initState() {
    super.initState();
    _unsubscribe = widget.vm.notices.listen(_show);
  }

  @override
  void didUpdateWidget(_NoticeHost old) {
    super.didUpdateWidget(old);
    if (identical(old.vm, widget.vm)) return;
    _unsubscribe?.call();
    _unsubscribe = widget.vm.notices.listen(_show);
  }

  void _show(AppNotice notice) {
    _hide?.cancel();
    setState(() => _notice = notice);
    _hide = Timer(Duration(seconds: notice.isError ? 7 : 4), _dismiss);
  }

  void _dismiss() {
    _hide?.cancel();
    if (mounted) setState(() => _notice = null);
  }

  @override
  void dispose() {
    _hide?.cancel();
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    final colors = context.colors;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: notice == null
                ? const SizedBox.shrink()
                : Padding(
                    key: ObjectKey(notice),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Semantics(
                        liveRegion: true,
                        child: ExcludeFocus(
                          child: Material(
                            color: colors.palette.panel,
                            elevation: 6,
                            borderRadius: BorderRadius.circular(Radii.card),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(Radii.card),
                              onTap: _dismiss,
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(Radii.card),
                                  border: Border.all(
                                    color: (notice.isError ? colors.danger : colors.glassBorder).withValues(alpha: 0.6),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      notice.isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                                      size: 20,
                                      color: notice.isError ? colors.danger : colors.palette.lime,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        notice.message,
                                        style: TextStyle(fontSize: 13, color: colors.textMain),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: context.tr('TipDismissNotice'),
                                      onPressed: _dismiss,
                                      iconSize: 16,
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// All the player shows when it could not start: why, and where the log is.
class _StartupErrorPage extends StatelessWidget {
  const _StartupErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final log = WiretuneLog.logPath;
    return Material(
      color: colors.palette.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 40, color: colors.danger),
                  const SizedBox(height: 12),
                  Text(
                    context.tr('StartupFailedTitle'),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: colors.textMain),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(message, style: TextStyle(fontSize: 14, color: colors.textMain)),
                  if (log != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(
                      context.trf('StartupFailedLog', [log]),
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
