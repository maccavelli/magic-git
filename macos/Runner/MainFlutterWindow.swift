import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var bookmarkChannel: FlutterMethodChannel?
  private var showOutputItem: NSMenuItem?
  private var showFileItem: NSMenuItem?
  private var dashboardItem: NSMenuItem?

  /// Whether a quit-initiated Flutter cleanup round trip is already running,
  /// so a second terminate request while the first is in flight doesn't spawn
  /// another one (AppKit needs exactly one reply).
  private var terminateRequestInFlight = false

  /// Asks Flutter to shut down cleanly (persist bounds, disconnect SSH) ahead
  /// of app termination. Returns false when the Flutter channel isn't up yet —
  /// the caller should terminate immediately. Otherwise `completion` runs
  /// exactly once: when Dart answers, or after a 3s backstop so quit can never
  /// hang on an unresponsive connection.
  func prepareToTerminate(completion: @escaping () -> Void) -> Bool {
    guard let channel = menuChannel else { return false }
    if terminateRequestInFlight { return true }
    terminateRequestInFlight = true
    var replied = false
    let finish = {
      guard !replied else { return }
      replied = true
      completion()
    }
    channel.invokeMethod("prepareToTerminate", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
    return true
  }

  /// Security-scoped URLs currently being accessed for a local repo, keyed by
  /// the bookmarked path. Must be the *exact* URL instance
  /// `startAccessingSecurityScopedResource()` was called on — a URL freshly
  /// constructed from the same path string is not equivalent and calling
  /// `stopAccessingSecurityScopedResource()` on it would be a no-op, so this
  /// dictionary is what makes a later `stopAccessingBookmark` call possible
  /// at all.
  private var activeScopedURLs: [String: URL] = [:]

  override func awakeFromNib() {
    // Start fully transparent so nothing paints at the default (main-display)
    // launch position. Flutter repositions the window onto its saved monitor
    // while it's invisible, then reveals it via window_manager's setOpacity(1)
    // (see main.dart) — so the window appears already on the correct screen
    // with no flash on the main display, and no other apps there "blinking".
    // NB: this keeps the window "visible at launch" (unlike hiding it, which
    // left it never showing) so window_manager's normal show/position lifecycle
    // still works — we only mask the pixels until it's in the right place.
    self.alphaValue = 0

    // Bounds are owned by WindowBoundsStore (Dart) — restored via setBounds
    // before first show. Opt out of AppKit state restoration so two systems
    // don't both bookkeep the frame (AppKit restoring to one position, Flutter
    // immediately moving to another).
    self.isRestorable = false

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Bridge the native "View" menu items to Flutter. Each item invokes a
    // toggle*; Flutter pushes the checkbox state back via set*Checked so the
    // checkmarks stay in sync.
    let channel = FlutterMethodChannel(
      name: "magicgit/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.menuChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setOutputViewChecked":
        if let checked = call.arguments as? Bool {
          self?.showOutputItem?.state = checked ? .on : .off
        }
        result(nil)
      case "setFileViewChecked":
        if let checked = call.arguments as? Bool {
          self?.showFileItem?.state = checked ? .on : .off
        }
        result(nil)
      case "setDashboardChecked":
        if let checked = call.arguments as? Bool {
          self?.dashboardItem?.state = checked ? .on : .off
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Lets Flutter persist access to a user-picked local repo folder across
    // app relaunches under App Sandbox — see handleBookmarkCall below.
    let bookmarks = FlutterMethodChannel(
      name: "magicgit/bookmarks",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.bookmarkChannel = bookmarks
    bookmarks.setMethodCallHandler { [weak self] call, result in
      self?.handleBookmarkCall(call, result: result)
    }

    // Defer so the app's main menu (loaded from MainMenu.xib) is in place.
    DispatchQueue.main.async { [weak self] in
      self?.installViewMenuItems()
      self?.installAboutPanelOverride()
    }

    super.awakeFromNib()
  }

  /// Handles `magicgit/bookmarks`: `createBookmark(path) -> base64 data`,
  /// `startAccessingBookmark(base64 data) -> resolved path`,
  /// `stopAccessingBookmark(path)`. A local repo's folder is picked once
  /// through a system panel (the only way to gain a sandbox grant for it at
  /// all); `createBookmark` captures that grant so it can be restored on a
  /// later app launch without re-prompting, and `startAccessingBookmark` /
  /// `stopAccessingBookmark` bracket the whole time it's actually in use —
  /// a spawned `git`/`glab` child process only inherits the grant while it's
  /// held open.
  private func handleBookmarkCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createBookmark":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      do {
        let data = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(data.base64EncodedString())
      } catch {
        result(FlutterError(code: "bookmark_failed", message: "\(error)", details: nil))
      }

    case "startAccessingBookmark":
      guard let base64 = call.arguments as? String,
        let data = Data(base64Encoded: base64)
      else {
        result(FlutterError(code: "bad_args", message: "bookmark data required", details: nil))
        return
      }
      do {
        // `isStale` (the file moved but was still resolvable via other
        // means) isn't acted on here — a rare edge case; the next explicit
        // re-pick through the folder-picker sheet recreates a fresh
        // bookmark regardless.
        var isStale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: .withSecurityScope,
          relativeTo: nil,
          bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
          result(
            FlutterError(code: "access_denied", message: "could not start access", details: nil))
          return
        }
        // Balance start/stop per URL instance: if a grant for this same path is
        // already held (e.g. two saved entries pointing at one folder, or a
        // re-open before the prior access was released), stop the old instance
        // before replacing it — otherwise its startAccessing is never matched by
        // a stop and that scope leaks for the app's lifetime.
        if let previous = self.activeScopedURLs[url.path] {
          previous.stopAccessingSecurityScopedResource()
        }
        self.activeScopedURLs[url.path] = url
        result(url.path)
      } catch {
        result(FlutterError(code: "resolve_failed", message: "\(error)", details: nil))
      }

    case "stopAccessingBookmark":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      if let url = self.activeScopedURLs.removeValue(forKey: path) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func installViewMenuItems() {
    guard let mainMenu = NSApp.mainMenu else { return }

    // Find the existing "View" menu, or create one just before the Window
    // menu. The Window menu is located via NSApp.windowsMenu — its systemMenu
    // role, which survives renaming/localization — with the title comparison
    // kept only as a fallback; the "View" title match is unavoidable (AppKit
    // has no systemMenu role for View) but this app ships English-only menus.
    let viewMenu: NSMenu
    if let existing = mainMenu.items.first(where: {
      $0.title == "View" || $0.submenu?.title == "View"
    })?.submenu {
      viewMenu = existing
    } else {
      let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
      let created = NSMenu(title: "View")
      viewItem.submenu = created
      if let windowIndex = mainMenu.items.firstIndex(where: {
        ($0.submenu != nil && $0.submenu === NSApp.windowsMenu)
          || $0.title == "Window" || $0.submenu?.title == "Window"
      }) {
        mainMenu.insertItem(viewItem, at: windowIndex)
      } else {
        mainMenu.addItem(viewItem)
      }
      viewMenu = created
    }

    self.showOutputItem = addToggleItem(
      to: viewMenu, title: "Show Output View", key: "o",
      action: #selector(toggleOutputView(_:)), separatorBefore: true)
    self.showFileItem = addToggleItem(
      to: viewMenu, title: "Show File View", key: "e",
      action: #selector(toggleFileView(_:)), separatorBefore: false)
    self.dashboardItem = addToggleItem(
      to: viewMenu, title: "Dashboard View", key: "d",
      action: #selector(toggleDashboard(_:)), separatorBefore: false)

    // The items now exist, so pull the current checkbox states from Flutter.
    // Flutter also pushes them once at startup, but that push races this
    // (async-deferred) install and is dropped if it lands while showOutputItem
    // /showFileItem are still nil — which left the checkmarks off even though
    // both views default to on. Requesting here guarantees the items exist
    // before Flutter answers, so the marks are correct from the first frame.
    menuChannel?.invokeMethod("syncMenuState", arguments: nil)
  }

  // Adds (or reuses, if awakeFromNib runs twice) a checkable ⇧⌘<key> item
  // wired to `action`.
  private func addToggleItem(
    to menu: NSMenu, title: String, key: String, action: Selector,
    separatorBefore: Bool
  ) -> NSMenuItem {
    if let existing = menu.items.first(where: { $0.action == action }) {
      return existing
    }
    if separatorBefore && !menu.items.isEmpty {
      menu.addItem(NSMenuItem.separator())
    }
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = [.command, .shift]
    item.target = self
    item.state = .off
    menu.addItem(item)
    return item
  }

  /// Repoints the standard "About Magic Git" menu item (wired in MainMenu.xib to
  /// `orderFrontStandardAboutPanel:`) at our own handler, so the About panel can
  /// show the app's branding artwork. Deliberately does NOT set
  /// `NSApp.applicationIconImage` — that would also change the Dock/bundle icon;
  /// passing `.applicationIcon` as an About-panel option affects only that panel.
  private func installAboutPanelOverride() {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
    for item in appMenu.items
    where item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) {
      item.target = self
      item.action = #selector(showAboutPanel(_:))
    }
  }

  @objc private func showAboutPanel(_ sender: Any?) {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    // Falls back to the default (Dock/bundle) icon if the asset is missing.
    if let icon = NSImage(named: "AboutIcon") {
      options[.applicationIcon] = icon
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
  }

  @objc private func toggleOutputView(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleOutputView", arguments: nil)
  }

  @objc private func toggleFileView(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleFileView", arguments: nil)
  }

  @objc private func toggleDashboard(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleDashboard", arguments: nil)
  }
}
