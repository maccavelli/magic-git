import Cocoa
import FlutterMacOS

/// Diagnostic trail for the multi-window machinery. NSLog alone is useless here
/// — the unified log redacts NSLog message content as <private> — so every line
/// is also appended to hw-debug.log in the app's home directory (the sandbox
/// container when sandboxed). One lazily-opened handle for the process lifetime;
/// the OS flushes and closes it at exit.
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

/// The kinds of secondary window. The raw value is the wire discriminator shared
/// verbatim with the Dart `WindowKind` enum (carried in the descriptor). Keep the
/// two in exact sync.
enum WindowKind: String {
  case history
  case detachedRepo

  var defaultTitle: String {
    switch self {
    case .history: return "History"
    case .detachedRepo: return "Repository"
    }
  }

  var defaultSize: NSSize {
    switch self {
    case .history: return NSSize(width: 1000, height: 640)
    case .detachedRepo: return NSSize(width: 1100, height: 720)
    }
  }

  var minSize: NSSize { NSSize(width: 720, height: 440) }
}

/// A native secondary window: a second NSWindow hosting a second FlutterEngine
/// (the generic entrypoint `secondaryWindowMain`), plus the channel relay that
/// lets the two engines talk. Flutter 3.44 stable has no shared-isolate
/// multi-window on macOS, so each secondary window is a full engine whose git
/// commands are proxied back to the main isolate over its per-window hub
/// (`magicgit/window/<id>/hub`).
///
/// Two channel planes:
///  * a per-engine BOOTSTRAP channel (`magicgit/window/bootstrap`, on the child
///    messenger) that answers the child's identity `descriptor` pull and a small
///    native allowlist — `ready` (reveal after the first frame), `setWindowTitle`,
///    `closeSelf`, and `debugLog`.
///  * the per-window HUB relay, deliberately dumb: verbatim method/argument
///    forwarding both ways with reply piping, no logic — everything testable
///    lives in Dart.
///
/// The controller is fully per-instance (window/engine/channels/isTornDown), so
/// the owner (`MainFlutterWindow`) can hold an arbitrary number of them keyed by
/// window id.
class SecondaryWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var engine: FlutterEngine?
  private var viewController: FlutterViewController?
  private var bootstrap: FlutterMethodChannel?
  /// Hub endpoints: A = main engine, B = child engine. Each side's Dart
  /// `invokeMethod` lands on the same-named per-window Swift channel here and is
  /// forwarded verbatim to the other engine's Dart handler.
  private var hubA: FlutterMethodChannel?
  private var hubB: FlutterMethodChannel?
  private var isTornDown = false

  private let windowId: String
  private let kind: WindowKind
  private let repoPath: String?
  private let initialTitle: String
  private let connectionLabel: String?
  private let mainMessenger: FlutterBinaryMessenger
  private let onClosed: (String) -> Void

  init(
    windowId: String,
    kind: WindowKind,
    repoPath: String?,
    title: String?,
    connectionLabel: String?,
    mainMessenger: FlutterBinaryMessenger,
    onClosed: @escaping (String) -> Void
  ) {
    self.windowId = windowId
    self.kind = kind
    self.repoPath = repoPath
    self.initialTitle = title ?? kind.defaultTitle
    self.connectionLabel = connectionLabel
    self.mainMessenger = mainMessenger
    self.onClosed = onClosed
    super.init()
  }

  func open() {
    if window != nil {
      front()
      return
    }
    hwDebugLog("controller[\(windowId)].open() — creating engine")

    // Order is load-bearing, twice over. (1) FlutterEngine(name:project:) is the
    // NON-headless initializer, so the engine may only run once a view controller
    // is attached — FlutterViewController(engine:) attaches itself; running first
    // leaves a dead engine. (2) The view must NOT be inside a window before run():
    // loading the view auto-launches the engine with the DEFAULT entrypoint
    // (`main` — a rogue second copy of the whole app), and the explicit
    // run(withEntrypoint:) then fails "already running". Engine → attach VC →
    // install channels (so the child's first descriptor pull finds a handler) →
    // run → THEN build the window.
    let engine = FlutterEngine(name: "magicgit-window-\(windowId)", project: nil)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    installBootstrap(childMessenger: engine.binaryMessenger)
    installRelay(childMessenger: engine.binaryMessenger)
    hwDebugLog("engine + view controller created, running entrypoint")
    // The entrypoint must exist in lib/main.dart (the root library) — macOS has
    // no libraryURI variant of run(withEntrypoint:).
    guard engine.run(withEntrypoint: "secondaryWindowMain") else {
      // Nothing window-shaped exists yet, so the only cleanup is the engine
      // itself — no orphaned invisible NSWindows, ever.
      hwDebugLog("engine failed to launch")
      engine.shutDownEngine()
      onClosed(windowId)
      return
    }
    hwDebugLog("engine running, registering plugins")
    self.engine = engine
    self.viewController = viewController
    RegisterGeneratedPlugins(registry: viewController)

    let size = kind.defaultSize
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = initialTitle
    window.minSize = kind.minSize
    // The app is dark-only (AppTheme); a plain dark-aqua window matches it
    // without the main window's vibrancy machinery (WindowManipulator is
    // single-window and must never run in this engine).
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    // Independent engines must not be auto-merged into one titlebar — tabbing
    // would confuse the per-window reveal/occlusion choreography.
    window.tabbingMode = .disallowed
    window.contentViewController = viewController
    // Restore the last frame if one was saved, then keep autosaving. The key is
    // stable across launches and unique per logical window (History is a
    // singleton; a repo-bound window follows its repo), so windows never fight
    // over one saved frame.
    let autosaveName = "SecondaryWindow-\(autosaveKey)"
    if !window.setFrameUsingName(autosaveName) {
      window.center()
    }
    window.setFrameAutosaveName(autosaveName)
    window.delegate = self
    // Shown transparent until Flutter's first frame (`ready`), so the user never
    // sees an empty white flash — same dance as the main window.
    window.alphaValue = 0
    self.window = window

    hwDebugLog("ordering window front (alpha 0 until ready)")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Hover events (tooltips, cursor changes) need the view's NSTrackingArea.
    // The default mode (inKeyWindow) was configured at window-attach time,
    // BEFORE makeKeyAndOrderFront — when the window wasn't key — and nothing
    // re-arms tracking on key changes. Setting the mode here re-runs the
    // configuration, and inActiveApp keeps hover alive regardless of which of
    // the app's windows is key (matching how the main window feels).
    viewController.mouseTrackingMode = .inActiveApp

    // Backstop reveal: if the `ready` message is ever lost, an invisible window
    // that accepts clicks would be far worse than a brief flash.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.reveal()
    }
  }

  /// A stable, filesystem-safe autosave suffix. History is a singleton, so a
  /// fixed key; a repo-bound window keys off its repo path so its frame follows
  /// the repo across launches.
  private var autosaveKey: String {
    switch kind {
    case .history:
      return "history"
    case .detachedRepo:
      let path = repoPath ?? "unknown"
      return "detachedRepo-" + path.replacingOccurrences(of: "/", with: "_")
    }
  }

  func front() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// User-facing close: runs the normal windowWillClose path (engine shutdown +
  /// Dart-side notification).
  func close() {
    window?.close()
  }

  /// Quit-path teardown: everything close() does, but without notifying the main
  /// engine's Dart (the app is exiting; there is no one to tell).
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
    onClosed(windowId)
  }

  // MARK: internals

  private func reveal() {
    hwDebugLog("revealing window[\(windowId)]")
    window?.alphaValue = 1
  }

  /// Hardened teardown ordering: stop channel traffic, detach the view from the
  /// engine BEFORE shutting the engine (so the embedder never touches a dead
  /// engine during release), then shut the engine and drop the view. Not
  /// shutting the engine before releasing it leaks the engine instance.
  private func shutDown() {
    bootstrap?.setMethodCallHandler(nil)
    hubA?.setMethodCallHandler(nil)
    hubB?.setMethodCallHandler(nil)
    bootstrap = nil
    hubA = nil
    hubB = nil
    window?.contentViewController = nil
    engine?.shutDownEngine()
    engine = nil
    viewController = nil
  }

  /// The per-engine allowlist channel: answers the child's identity `descriptor`
  /// pull plus the small set of native ops a window drives on itself.
  private func installBootstrap(childMessenger: FlutterBinaryMessenger) {
    let bootstrap = FlutterMethodChannel(
      name: "magicgit/window/bootstrap", binaryMessenger: childMessenger)
    self.bootstrap = bootstrap
    bootstrap.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.isTornDown else {
        result(FlutterError(code: "RELAY_DOWN", message: "window closed", details: nil))
        return
      }
      switch call.method {
      case "descriptor":
        // Omit nil keys rather than encoding Optional-as-Any (the Flutter codec
        // mishandles a wrapped Swift optional); Dart reads absent keys as null.
        var descriptor: [String: Any] = [
          "windowId": self.windowId,
          "kind": self.kind.rawValue,
          "title": self.initialTitle,
        ]
        if let repoPath = self.repoPath { descriptor["repoPath"] = repoPath }
        if let label = self.connectionLabel {
          descriptor["connectionLabel"] = label
        }
        result(descriptor)
      case "ready":
        self.reveal()
        result(nil)
      case "debugLog":
        // The child engine's Dart errors — invisible anywhere else in a release
        // build. Handled natively; never forwarded to main Dart.
        hwDebugLog("(child \(self.windowId)) " + ((call.arguments as? String) ?? "?"))
        result(nil)
      case "setWindowTitle":
        if let title = call.arguments as? String {
          self.window?.title = title
        }
        result(nil)
      case "closeSelf":
        result(nil)
        // Asynchronously: closing tears the relay down; the reply must go first.
        DispatchQueue.main.async { [weak self] in self?.close() }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The dumb per-window relay: verbatim forwarding both directions with reply
  /// piping. Every path resolves the `result` even mid-teardown — an unresolved
  /// reply handle is retained forever; the caller's RELAY_DOWN handling is the
  /// graceful path.
  private func installRelay(childMessenger: FlutterBinaryMessenger) {
    let name = "magicgit/window/\(windowId)/hub"
    let hubA = FlutterMethodChannel(name: name, binaryMessenger: mainMessenger)
    let hubB = FlutterMethodChannel(name: name, binaryMessenger: childMessenger)
    self.hubA = hubA
    self.hubB = hubB

    // Main Dart → child Dart (connectionChanged / repoTick / invalidateAll /
    // settingsChanged).
    hubA.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.isTornDown, let hubB = self.hubB else {
        result(FlutterError(code: "RELAY_DOWN", message: "window closed", details: nil))
        return
      }
      hubB.invokeMethod(call.method, arguments: call.arguments) { [weak self] reply in
        guard let self, !self.isTornDown else {
          result(FlutterError(code: "RELAY_DOWN", message: "window closed", details: nil))
          return
        }
        result(reply)
      }
    }

    // Child Dart → main Dart (execute / requestState / undoRecord /
    // mutationPerformed / performUndo / settingsChanged).
    hubB.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.isTornDown, let hubA = self.hubA else {
        result(FlutterError(code: "RELAY_DOWN", message: "main engine unavailable", details: nil))
        return
      }
      hubA.invokeMethod(call.method, arguments: call.arguments) { [weak self] reply in
        guard let self, !self.isTornDown else {
          result(FlutterError(code: "RELAY_DOWN", message: "window closed", details: nil))
          return
        }
        result(reply)
      }
    }
  }
}
