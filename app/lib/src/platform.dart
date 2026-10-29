// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// Which kind of device the app runs on; decided once at start-up by [AppPlatform.detect].
class AppPlatform {
  AppPlatform._(this._system, this.isTizen, this.isTv);

  static late AppPlatform current;

  /// The operating system as `Platform.operatingSystem` names it: android, ios, linux, macos or windows.
  final String _system;

  /// Samsung's Tizen (TVs). Dart reports it as Linux; the Tizen runner (tizen/App.cs) answers `isTizen`.
  final bool isTizen;

  /// A television: Android TV or a Tizen TV. Steered with a remote, always in the wide layout.
  final bool isTv;

  bool get isAndroid => _system == 'android';
  bool get isIOS => _system == 'ios';
  bool get isMacOS => _system == 'macos';
  bool get isWindows => _system == 'windows';
  bool get isLinuxDesktop => _system == 'linux' && !isTizen;

  bool get isDesktop => isLinuxDesktop || isWindows || isMacOS;

  /// The window has no system title bar; the app's header moves it and carries the window buttons.
  bool get hasCustomWindowFrame => isLinuxDesktop || isWindows;

  /// A phone or tablet: steered by touch and running on its battery. Nothing animates there on its own (the backdrop's
  /// drift, the breathing logo, the status light): every frame costs battery, and such an animation draws
  /// them for as long as the music lasts.
  bool get isMobile => (isAndroid && !isTv) || isIOS;

  /// The players that can scan a folder of the device's own (computers and Android phones); the others play from a
  /// server.
  bool get supportsLocalFolder => isDesktop || (isAndroid && !isTv);

  /// The system's media controls through audio_service: the notification, lock screen and Android Auto (Android),
  /// Control Center (iOS, macOS) and MPRIS (Linux desktop, through audio_service_mpris).
  bool get supportsMediaSession => isAndroid || isIOS || isMacOS || isLinuxDesktop;

  /// Who answers what on it: the Android plugin (packages/wiretune_platform) `isTelevision`, `musicDirectory`,
  /// `requestAudioAccess` and `installUpdate`; the Tizen runner (tizen/App.cs) `isTizen` and
  /// `isTelevision`; the iOS runner (ios/Runner/AppDelegate.swift) `excludeFromBackup`. Elsewhere a call finds no
  /// handler.
  static const MethodChannel _channel = MethodChannel('wiretune/platform');

  /// Asks the native side ([_channel]); a platform without a handler, such as a desktop, reads as "no".
  static Future<AppPlatform> detect() async {
    final system = _hostSystem;
    var tizen = false;
    var tv = false;
    if (system == 'linux') tizen = await _ask('isTizen');
    if (tizen || system == 'android') tv = await _ask('isTelevision');
    return current = AppPlatform._(system, tizen, tv);
  }

  /// Keeps [folder] (created if need be) and everything in it out of the device's backups, on iOS (the runner's
  /// AppDelegate answers); elsewhere nothing happens. The app's support folder is backed up to iCloud by default, and
  /// Apple's storage guidelines keep what can be downloaded again out of it.
  Future<void> excludeFromBackup(String folder) async {
    if (!isIOS) return;
    try {
      await Directory(folder).create(recursive: true);
      await _channel.invokeMethod<void>('excludeFromBackup', folder);
    } catch (e, s) {
      WiretuneLog.error('Platform', 'Could not keep $folder out of backups', e, s);
    }
  }

  /// The music folder Android puts downloads in (the Android plugin knows which one the system lets the app write to
  /// without asking); null elsewhere, or when there is none.
  Future<String?> androidMusicDirectory() async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('musicDirectory');
    } on PlatformException catch (e) {
      WiretuneLog.warn('Platform', 'No music folder: $e');
    } on MissingPluginException {
      // An engine without the plugin: the app's own storage then.
    }
    return null;
  }

  /// Whether the app may read the audio files on an Android device, asking the user first if it hasn't been allowed
  /// yet; elsewhere always true. Asked only when a folder is scanned, not at start.
  Future<bool> requestAudioAccess() async => !isAndroid || await _ask('requestAudioAccess');

  /// Hands the APK at [path] to Android's installer, which asks the user before it installs it over this app.
  Future<void> installAndroidUpdate(String path) => _channel.invokeMethod<void>('installUpdate', path);

  static String get _hostSystem => Platform.operatingSystem;

  static Future<bool> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      // A failed answer is no. Not logged: at start ([detect]) the log isn't set up yet, and would open in the wrong
      // folder.
      return false;
    } on MissingPluginException {
      // No handler, as on a computer's Linux (no Tizen side): no.
      return false;
    }
  }

  /// For tests and previews: [system] stands in for the operating system (`android`, `ios`, …); null keeps this
  /// machine's.
  static AppPlatform forTesting({String? system, bool tizen = false, bool tv = false}) =>
      current = AppPlatform._(system ?? _hostSystem, tizen, tv);
}
