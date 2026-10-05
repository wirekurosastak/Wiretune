import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WiretunePlatform") {
      registerPlatformChannel(registrar.messenger())
    }
  }

  /// `wiretune/platform`: "excludeFromBackup" keeps a folder (and everything in it) out of iCloud and computer backups.
  /// Downloads can be fetched from the server again, and Apple's storage guidelines keep such data out of backups.
  private func registerPlatformChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "wiretune/platform", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      var url = URL(fileURLWithPath: path, isDirectory: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "backup", message: error.localizedDescription, details: path))
      }
    }
  }
}
