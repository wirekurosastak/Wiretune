// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'src/app.dart';
import 'src/audio/media_kit_driver.dart';
import 'src/audio/media_session.dart';
import 'src/audio/mobile_audio.dart';
import 'src/audio/tizen_driver.dart';
import 'src/debug/ui_automation_server.dart';
import 'src/platform.dart';
import 'src/view_models/main_view_model.dart';
import 'src/widgets/cover_image.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final platform = await AppPlatform.detect();

  // A desktop keeps its data in the user's application data folder (AppPaths); the others in the app's private support
  // folder. Android downloads into the music folder the system lets the app write to without a permission.
  if (!platform.isDesktop) AppPaths.platformDataRoot = (await getApplicationSupportDirectory()).path;
  AppPaths.platformMusicFolder = await platform.androidMusicDirectory();
  WiretuneLog.initialize();

  if (platform.isAndroid || platform.isIOS) {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  if (platform.isDesktop) await _prepareWindow(platform);
  // A TV is steered with the remote: the focused item is always highlighted, not only after a key press.
  if (platform.isTv) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  // Covers are decoded at the size they are shown; a TV's large grid needs more room than the default 100 MB.
  PaintingBinding.instance.imageCache.maximumSizeBytes = (platform.isTv ? 160 : 120) << 20;

  final AudioDriver driver;
  if (platform.isTizen) {
    driver = TizenAudioDriver();
  } else {
    MediaKit.ensureInitialized();
    driver = MediaKitAudioDriver(allowDeviceSelection: platform.isDesktop, enableSpectrum: platform.isDesktop);
  }

  final repository = LibraryRepository(DatabaseManager());
  final library = LibraryService(repository, MetadataScanner());
  final session = ServerSession(library, repository);
  final vm = MainViewModel(
    WiretuneAudioEngine(driver),
    library,
    session,
    onlineLyrics: OnlineLyrics.createDefault(),
    capabilities: DeviceCapabilities(
      supportsLocalFolder: platform.supportsLocalFolder,
      requestFolderAccess: platform.requestAudioAccess,
      kind: _deviceKind(platform),
      // A computer goes by its host name; a phone's is "localhost", so it goes by "Phone" until it is given a name.
      name: platform.isDesktop ? Platform.localHostname : '',
    ),
  );
  vm.onServerCredentialsChanged = (serverUrl, token) {
    CoverArt.serverUrl = serverUrl.isEmpty ? null : serverUrl;
    CoverArt.authToken = token;
  };
  CoverArt.localCopy = vm.downloadService.localCover;
  unawaited(platform.excludeFromBackup(vm.downloadService.directory));
  unawaited(platform.excludeFromBackup(vm.downloadService.workDirectory));

  // A failed command (locked database, full disk, ...) must not take the whole player down: log it with its stack
  // trace and show it in the player's error line instead. The line is updated after the frame that is being built,
  // never in the middle of it.
  void report(Object error, StackTrace? stack, {required bool show}) {
    WiretuneLog.error('App', 'Unhandled exception', error, stack);
    if (show) scheduleMicrotask(() => vm.player.showError(Localizer.format('UnexpectedError', ['$error'])));
  }

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // What a button or a gesture handler threw is a command that failed; a layout or painting slip is a bug to fix in
    // the code, and only logged.
    report(details.exception, details.stack, show: details.library == 'gesture library');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    report(error, stack, show: true);
    return true;
  };

  if (platform.isAndroid || platform.isIOS) {
    try {
      await MobileAudio.attach(vm.audioEngine);
    } catch (e, s) {
      WiretuneLog.error('App', 'Audio session set-up failed', e, s);
    }
  }
  if (platform.supportsMediaSession) {
    try {
      await WiretuneMediaSession.start(vm);
    } catch (e, s) {
      WiretuneLog.error('App', 'Media session set-up failed', e, s);
    }
  }

  if (platform.isDesktop) {
    await windowManager.setPreventClose(true);
    windowManager.addListener(_DesktopWindowListener(vm));
  }

  runApp(WiretuneApp(vm: vm));
  unawaited(vm.start());
  if (UiAutomationServer.isEnabled) unawaited(UiAutomationServer(vm).start());
}

class _DesktopWindowListener with WindowListener {
  _DesktopWindowListener(this._vm);
  final MainViewModel _vm;

  @override
  void onWindowClose() async {
    try {
      await _vm.player.saveSession();
      await _vm.audioEngine.dispose();
      _vm.dispose();
    } catch (e, s) {
      WiretuneLog.error('App', 'Error during desktop window close disposal', e, s);
    }
    await windowManager.destroy();
  }
}

/// What the account's other players see this one as. A phone or a tablet tells by its screen: a tablet's shorter side
/// is at least 600 points.
DeviceKind _deviceKind(AppPlatform platform) {
  if (platform.isTv) return DeviceKind.tv;
  if (!platform.isMobile) return DeviceKind.desktop;
  final view = PlatformDispatcher.instance.views.firstOrNull;
  final shortest = view == null ? 0 : view.physicalSize.shortestSide / view.devicePixelRatio;
  return shortest >= 600 ? DeviceKind.tablet : DeviceKind.phone;
}

/// The desktop window: on Linux and Windows without the system's title bar (the header is the title bar, with its own
/// window buttons) and maximized; on macOS with the usual title bar and traffic lights.
Future<void> _prepareWindow(AppPlatform platform) async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'Wiretune - Audiophile Streamer & Player',
      minimumSize: const Size(720, 560),
      titleBarStyle: platform.hasCustomWindowFrame ? TitleBarStyle.hidden : TitleBarStyle.normal,
    ),
    () async {
      if (platform.hasCustomWindowFrame) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
