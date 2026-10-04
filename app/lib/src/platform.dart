import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which kind of device the app runs on; decided once at start-up by [AppPlatform.detect].
class AppPlatform {
  AppPlatform._(this.isTizen, this.isTv);

  static late AppPlatform current;

  /// Samsung's Tizen (TVs). Dart reports it as Linux; the Tizen runner (tizen/App.cs) answers `isTizen`.
  final bool isTizen;

  /// A television: Android TV or a Tizen TV. Steered with a remote, always in the wide layout.
  final bool isTv;

  bool get isAndroid => !kIsWeb && Platform.isAndroid;
  bool get isIOS => !kIsWeb && Platform.isIOS;
  bool get isMacOS => !kIsWeb && Platform.isMacOS;
  bool get isWindows => !kIsWeb && Platform.isWindows;
  bool get isLinuxDesktop => !kIsWeb && Platform.isLinux && !isTizen;

  bool get isDesktop => isLinuxDesktop || isWindows || isMacOS;

  /// The window has no system title bar; the app's header moves it and carries the window buttons.
  bool get hasCustomWindowFrame => isLinuxDesktop || isWindows;
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
    var tizen = false;
    var tv = false;
    if (!kIsWeb && Platform.isLinux) tizen = await _ask('isTizen');
    if (tizen || (!kIsWeb && Platform.isAndroid)) tv = await _ask('isTelevision');
    return current = AppPlatform._(tizen, tv);
  }

  static Future<bool> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// For tests and previews.
  static AppPlatform forTesting({bool tizen = false, bool tv = false}) => current = AppPlatform._(tizen, tv);
}
