import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    windowFrame.size = NSSize(width: 1280, height: 820)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Wiretune"
    // The smallest window the layout is made for.
    self.contentMinSize = NSSize(width: 720, height: 560)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
