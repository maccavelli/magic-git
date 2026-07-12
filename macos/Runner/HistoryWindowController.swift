import Cocoa
import FlutterMacOS

/// Diagnostic trail for the History window machinery. NSLog alone is useless
/// here — the unified log redacts NSLog message content as <private> — so
/// every line is also appended to hw-debug.log in the app's home directory
/// (the sandbox container when sandboxed). One lazily-opened handle for the
/// process lifetime; the OS flushes and closes it at exit.
///
/// Rotated at open: if a prior session left the file past the cap it is
/// truncated to a fresh empty file, so the log can never grow without bound
/// across launches (the per-launch volume is tiny once the Dart-side
/// diagnostics flag is off — only lifecycle breadcrumbs and real errors).
private let hwDebugLogMaxBytes: UInt64 = 1_000_000

private let hwDebugLogHandle: FileHandle? = {
  let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("hw-debug.log")
  let fm = FileManager.default
  let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
  if !fm.fileExists(atPath: url.path) || (size ?? 0) > hwDebugLogMaxBytes {
    fm.createFile(atPath: url.path, contents: nil)
  }
  let handle = try? FileHandle(forWritingTo: url)
  handle?.seekToEndOfFile()
  return handle
}()

func hwDebugLog(_ message: String) {
  NSLog("Magic Git HW: %@", message)
  if let data = "\(Date()) \(message)\n".data(using: .utf8) {
    hwDebugLogHandle?.write(data)
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
/// `debugLog` (the history engine's error trail → hw-debug.log).
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
  private let onClosed: () -> Void

  init(
    mainMessenger: FlutterBinaryMessenger,
    onClosed: @escaping () -> Void
  ) {
    self.mainMessenger = mainMessenger
    self.onClosed = onClosed
    super.init()
  }

  func open() {
    if window != nil {
      front()
      return
    }
    hwDebugLog("controller.open() — creating engine")

    // Order is load-bearing, twice over. (1) FlutterEngine(name:project:) is
    // the NON-headless initializer, so the engine may only run once a view
    // controller is attached — FlutterViewController(engine:) attaches
    // itself; running first leaves a dead engine. (2) The view must NOT be
    // inside a window before run(): loading the view auto-launches the
    // engine with the DEFAULT entrypoint (`main` — a rogue second copy of
    // the whole app), and the explicit run(withEntrypoint:) then fails with
    // "already running". Engine → attach VC → run → THEN build the window.
    let engine = FlutterEngine(name: "magicgit-history", project: nil)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    hwDebugLog("engine + view controller created, running entrypoint")
    // The entrypoint must exist in lib/main.dart (the root library) — macOS
    // has no libraryURI variant of run(withEntrypoint:).
    guard engine.run(withEntrypoint: "historyWindowMain") else {
      // Nothing window-shaped exists yet, so the only cleanup is the engine
      // itself — no orphaned invisible NSWindows, ever.
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

    // Hover events (tooltips, cursor changes) need the view's NSTrackingArea.
    // The default mode (inKeyWindow) was configured at window-attach time,
    // BEFORE makeKeyAndOrderFront — when the window wasn't key — and nothing
    // re-arms tracking on key changes. Setting the mode here re-runs the
    // configuration, and inActiveApp keeps hover alive regardless of which
    // of the app's windows is key (matching how the main window feels).
    viewController.mouseTrackingMode = .inActiveApp

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
        // Resolve even mid-teardown — an unresolved reply handle is retained
        // forever; the caller's RELAY_DOWN handling is the graceful path.
        guard let self, !self.isTornDown else {
          result(FlutterError(code: "RELAY_DOWN", message: "history window closed", details: nil))
          return
        }
        result(reply)
      }
    }

    // History Dart → native allowlist, else forward to main Dart
    // (execute / requestState / undoRecord / mutationPerformed / performUndo).
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
      case "debugLog":
        // The history engine's Dart errors — invisible anywhere else in a
        // release build. Handled natively; never forwarded to main Dart.
        hwDebugLog("(hist) " + ((call.arguments as? String) ?? "?"))
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
      default:
        break
      }
      guard let hubA = self.hubA else {
        result(FlutterError(code: "RELAY_DOWN", message: "main engine unavailable", details: nil))
        return
      }
      hubA.invokeMethod(call.method, arguments: call.arguments) { [weak self] reply in
        // Same as the A→B direction: never leave a reply handle unresolved.
        guard let self, !self.isTornDown else {
          result(FlutterError(code: "RELAY_DOWN", message: "history window closed", details: nil))
          return
        }
        result(reply)
      }
    }
  }
}
