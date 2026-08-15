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
    guard let window = mainFlutterWindow as? MainFlutterWindow,
      window.prepareToTerminate(completion: { shouldTerminate in
        if shouldTerminate {
          // Pop-outs only once quitting is real: their engines hold no
          // session state (bounds are frame-autosaved continuously), so a
          // synchronous teardown is safe — and a cancelled quit must not
          // have closed them (0009 M5).
          (self.mainFlutterWindow as? MainFlutterWindow)?
            .teardownAllSecondaryWindows()
        }
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
      })
    else {
      // Flutter channel not up (quit during launch), or Dart already ran a
      // confirmed teardown (terminateNow) — proceed immediately.
      (mainFlutterWindow as? MainFlutterWindow)?.teardownAllSecondaryWindows()
      return .terminateNow
    }
    return .terminateLater
  }

  /// Ventura+ retitles the Apple-menu "Preferences…" item to "Settings…" and
  /// enables it only when the responder chain implements this selector (or
  /// `showPreferencesWindow:`). Without it the item stays dimmed even though
  /// ⌘, and the command palette still open Settings.
  @objc func showSettingsWindow(_ sender: Any?) {
    (mainFlutterWindow as? MainFlutterWindow)?.openSettingsFromMenu()
  }

  @objc func showPreferencesWindow(_ sender: Any?) {
    showSettingsWindow(sender)
  }
}
