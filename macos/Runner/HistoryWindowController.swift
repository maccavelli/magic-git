import Cocoa
import FlutterMacOS

/// Diagnostic trail for the History window machinery. NSLog alone is useless
/// here — the unified log redacts NSLog message content as <private> — so
/// every line is also appended to hw-debug.log in the app's home directory
/// (the sandbox container when sandboxed).
func hwDebugLog(_ message: String) {
  NSLog("Magic Git HW: %@", message)
  let line = "\(Date()) \(message)\n"
  let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("hw-debug.log")
  if let data = line.data(using: .utf8) {
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }
}

/// The native History window: a second NSWindow hosting a second FlutterEngine
/// (entrypoint `historyWindowMain`), plus the channel relay that lets the two
/// engines talk. Flutter 3.44 stable has no shared-isolate multi-window on
/// macOS, so the second window is a full engine whose git commands are proxied
/// back to the main isolate over `magicgit/history/hub`.
///
/// The relay is deliberately dumb — verbatim method/argument forwarding with
/// reply piping, no logic — so everything testable lives in Dart. A small
/// allowlist is handled natively instead of forwarded: `ready` (reveal the
/// window after Flutter's first frame), `setWindowTitle`, `closeSelf`, and
/// `openRecovery` (front the main window first, then forward).
class HistoryWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var engine: FlutterEngine?
  /// Hub endpoints: A = main engine, B = history engine. Each side's Dart
  /// `invokeMethod` lands on the same-named Swift channel here and is
  /// forwarded to the other engine's Dart handler.
  private var hubA: FlutterMethodChannel?
  private var hubB: FlutterMethodChannel?
  private var isTornDown = false

  private let mainMessenger: FlutterBinaryMessenger
  private let focusMain: () -> Void
  private let onClosed: () -> Void

  init(
    mainMessenger: FlutterBinaryMessenger,
    focusMain: @escaping () -> Void,
    onClosed: @escaping () -> Void
  ) {
    self.mainMessenger = mainMessenger
    self.focusMain = focusMain
    self.onClosed = onClosed
    super.init()
  }

  func open() {
    if window != nil {
      front()
      return
    }
    hwDebugLog("controller.open() — creating engine")

    // Order is load-bearing: FlutterEngine(name:project:) is the NON-headless
    // initializer, so the engine may only run once a view controller is
    // attached — FlutterViewController(engine:) attaches itself. Running
    // first (or ignoring run's result) leaves a dead engine: every later
    // step silently no-ops ("Failed to create a
    // FlutterPlatformMessageResponseHandle") and the window never appears.
    let engine = FlutterEngine(name: "magicgit-history", project: nil)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    hwDebugLog("engine + view controller created, running entrypoint")
    // The entrypoint must exist in lib/main.dart (the root library) — macOS
    // has no libraryURI variant of run(withEntrypoint:).
    guard engine.run(withEntrypoint: "historyWindowMain") else {
      hwDebugLog("engine failed to launch")
      engine.shutDownEngine()
      onClosed()
      return
    }
    hwDebugLog("engine running, registering plugins")
    self.engine = engine
    RegisterGeneratedPlugins(registry: viewController)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "History"
    window.minSize = NSSize(width: 720, height: 440)
    // The app is dark-only (AppTheme); a plain dark-aqua window matches it
    // without the main window's vibrancy machinery (WindowManipulator is
    // single-window and must never run in this engine).
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.contentViewController = viewController
    // Restore the last frame if one was saved, then keep autosaving. Falls
    // back to centering on first open.
    if !window.setFrameUsingName("HistoryWindow") {
      window.center()
    }
    window.setFrameAutosaveName("HistoryWindow")
    window.delegate = self
    // Shown transparent until Flutter's first frame (`ready`), so the user
    // never sees an empty white flash — same dance as the main window.
    window.alphaValue = 0
    self.window = window

    installRelay(historyMessenger: engine.binaryMessenger)

    hwDebugLog("ordering window front (alpha 0 until ready)")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Backstop reveal: if the `ready` message is ever lost, an invisible
    // window that accepts clicks would be far worse than a brief flash.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.reveal()
    }
  }

  func front() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// User-facing close: runs the normal windowWillClose path (engine
  /// shutdown + Dart-side notification).
  func close() {
    window?.close()
  }

  /// Quit-path teardown: everything close() does, but without notifying the
  /// main engine's Dart (the app is exiting; there is no one to tell).
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    window?.delegate = nil
    shutDown()
    window?.close()
    window = nil
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    guard !isTornDown else { return }
    isTornDown = true
    shutDown()
    window = nil
    onClosed()
  }

  // MARK: internals

  private func reveal() {
    hwDebugLog("revealing window")
    window?.alphaValue = 1
  }

  private func shutDown() {
    hubA?.setMethodCallHandler(nil)
    hubB?.setMethodCallHandler(nil)
    hubA = nil
    hubB = nil
    engine?.shutDownEngine()
    engine = nil
  }

  private func installRelay(historyMessenger: FlutterBinaryMessenger) {
    let hubA = FlutterMethodChannel(name: "magicgit/history/hub", binaryMessenger: mainMessenger)
    let hubB = FlutterMethodChannel(name: "magicgit/history/hub", binaryMessenger: historyMessenger)
    self.hubA = hubA
    self.hubB = hubB

    // Main Dart → history Dart (connectionChanged / repoTick / invalidateAll).
    hubA.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.isTornDown, let hubB = self.hubB else {
        result(FlutterError(code: "RELAY_DOWN", message: "history window closed", details: nil))
        return
      }
      hubB.invokeMethod(call.method, arguments: call.arguments) { [weak self] reply in
        guard let self, !self.isTornDown else { return }
        result(reply)
      }
    }

    // History Dart → native allowlist, else forward to main Dart
    // (execute / requestState / undoRecord / mutationPerformed / openRecovery).
    hubB.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.isTornDown else {
        result(FlutterError(code: "RELAY_DOWN", message: "history window closed", details: nil))
        return
      }
      switch call.method {
      case "ready":
        self.reveal()
        result(nil)
        return
      case "setWindowTitle":
        if let title = call.arguments as? String {
          self.window?.title = title
        }
        result(nil)
        return
      case "closeSelf":
        result(nil)
        // Asynchronously: closing tears the relay down; the reply must go
        // out first.
        DispatchQueue.main.async { [weak self] in self?.close() }
        return
      case "openRecovery":
        // Front the main window before the main isolate opens its sheet.
        self.focusMain()
      default:
        break
      }
      guard let hubA = self.hubA else {
        result(FlutterError(code: "RELAY_DOWN", message: "main engine unavailable", details: nil))
        return
      }
      hubA.invokeMethod(call.method, arguments: call.arguments) { [weak self] reply in
        guard let self, !self.isTornDown else { return }
        result(reply)
      }
    }
  }
}
