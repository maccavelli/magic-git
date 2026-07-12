import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// ⌘Q (and every other terminate path that doesn't go through the window's
  /// close button) used to kill the process with the SSH socket still open —
  /// the red-button path runs a clean disconnect via `onWindowClose`, but
  /// AppKit termination never fires a window-close event. Hold termination
  /// open just long enough for Flutter to disconnect, with a native timeout
  /// backstop so quit can never hang on a wedged connection.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // The History window first: its engine holds no session state (bounds
    // are frame-autosaved continuously), so a synchronous teardown is safe
    // and keeps its engine from outliving the main one mid-quit.
    (mainFlutterWindow as? MainFlutterWindow)?.teardownAllSecondaryWindows()
    guard let window = mainFlutterWindow as? MainFlutterWindow,
      window.prepareToTerminate(completion: {
        NSApp.reply(toApplicationShouldTerminate: true)
      })
    else {
      // Flutter channel not up (quit during launch) — nothing to clean.
      return .terminateNow
    }
    return .terminateLater
  }
}
