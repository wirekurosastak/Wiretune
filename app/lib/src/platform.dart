import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  /// drift, the breathing logo and cover, the status light): every frame costs battery, and such an animation draws
  /// them for as long as the music lasts.
  bool get isMobile => (isAndroid && !isTv) || isIOS;

  /// The players that can scan a folder of the device's own; the others play from a server.
  bool get supportsLocalFolder => isDesktop;

  /// The system's media controls through audio_service: the notification, lock screen and Android Auto (Android),
  /// Control Center (iOS, macOS) and MPRIS (Linux desktop, through audio_service_mpris).
  bool get supportsMediaSession => isAndroid || isIOS || isMacOS || isLinuxDesktop;

  static const MethodChannel _channel = MethodChannel('wiretune/platform');

  /// Asks the native side: the Android plugin and the Tizen runner answer on `wiretune/platform`; a desktop has no
  /// handler, which reads as "no".
  static Future<AppPlatform> detect() async {
    final system = _hostSystem;
    var tizen = false;
    var tv = false;
    if (system == 'linux') tizen = await _ask('isTizen');
    if (tizen || system == 'android') tv = await _ask('isTelevision');
    return current = AppPlatform._(system, tizen, tv);
  }

  static String get _hostSystem => kIsWeb ? 'web' : Platform.operatingSystem;

  static Future<bool> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// For tests and previews: [system] stands in for the operating system (`android`, `ios`, …); null keeps this
  /// machine's.
  static AppPlatform forTesting({String? system, bool tizen = false, bool tv = false}) =>
      current = AppPlatform._(system ?? _hostSystem, tizen, tv);
}
