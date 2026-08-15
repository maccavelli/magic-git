import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var menuChannel: FlutterMethodChannel?
  private var bookmarkChannel: FlutterMethodChannel?
  private var windowsChannel: FlutterMethodChannel?
  /// Open secondary windows, keyed by their Dart-minted window id. The owner of
  /// this map is the single source of truth for which native windows exist.
  private var secondaryWindows: [String: SecondaryWindowController] = [:]
  /// The main engine's view controller, captured at awakeFromNib. Never
  /// re-derive it from `contentViewController`: macos_window_utils replaces
  /// that with its own wrapper when Dart calls WindowManipulator.initialize()
  /// (MainFlutterWindowManipulator.swift), so a later
  /// `contentViewController as? FlutterViewController` cast fails.
  private var mainFlutterViewController: FlutterViewController?
  private var willCloseObserver: NSObjectProtocol?
  private var showOutputItem: NSMenuItem?
  private var showFileItem: NSMenuItem?
  private var dashboardItem: NSMenuItem?
  private var recoveryItem: NSMenuItem?

  /// The repository menus Dart installs at startup, kept so a re-install
  /// replaces rather than duplicates them.
  private var dynamicMenuItems: [NSMenuItem] = []

  /// Keymap action ids the active panel can run right now. `validateMenuItem`
  /// dims everything else — per the HIG, an unavailable command stays visible
  /// so people can still discover it.
  private var enabledActionIds: Set<String> = []

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
    self.mainFlutterViewController = flutterViewController
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
      case "setRecoveryChecked":
        if let checked = call.arguments as? Bool {
          self?.recoveryItem?.state = checked ? .on : .off
        }
        result(nil)
      case "installMenus":
        // Dart owns the menu structure (see menu_bar_spec.dart); this side is
        // a generic builder, so adding a command never needs a native change.
        if let spec = call.arguments as? [[String: Any]] {
          self?.installDynamicMenus(spec)
        }
        result(nil)
      case "setEnabledActions":
        if let ids = call.arguments as? [String] {
          self?.enabledActionIds = Set(ids)
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

    // Native secondary-window control (open/close/front from Dart; a closed
    // notification back carrying the window's id). The windows themselves live
    // in SecondaryWindowController instances keyed by id.
    let windows = FlutterMethodChannel(
      name: "magicgit/windows",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.windowsChannel = windows
    windows.setMethodCallHandler { [weak self] call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "openWindow":
        self?.openWindow(args ?? [:])
        result(nil)
      case "closeWindow":
        if let id = args?["windowId"] as? String {
          self?.secondaryWindows[id]?.close()
        }
        result(nil)
      case "frontWindow":
        if let id = args?["windowId"] as? String {
          self?.secondaryWindows[id]?.front()
        }
        result(nil)
      case "debugLog":
        // Dart-side diagnostics: release-build prints are invisible when the
        // app is launched from Finder, so the bridge ships them here.
        hwDebugLog("(dart) " + ((call.arguments as? String) ?? "?"))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Backstop: if this (main) window closes while any secondary window is
    // still up, close them all — the Dart disconnect path normally does this,
    // but a secondary window must never outlive the session's window.
    // (applicationShouldTerminateAfterLastWindowClosed relies on this: the last
    // window to close is always this one.) Snapshot the values first — each
    // close() fires onClosed, which mutates the dictionary.
    willCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: self, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      for controller in Array(self.secondaryWindows.values) {
        controller.close()
      }
    }

    // Defer so the app's main menu (loaded from MainMenu.xib) is in place.
    DispatchQueue.main.async { [weak self] in
      self?.installViewMenuItems()
      self?.installHelpMenuItems()
      self?.installAboutPanelOverride()
      self?.installPreferencesAction()
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
    if viewMenu.items.first(where: {
      $0.action == #selector(toggleSidebar(_:))
    }) == nil {
      let item = NSMenuItem(
        title: "Toggle Sidebar", action: #selector(toggleSidebar(_:)),
        keyEquivalent: "")
      item.target = self
      viewMenu.addItem(item)
    }
    self.showFileItem = addToggleItem(
      to: viewMenu, title: "Show File View", key: "e",
      action: #selector(toggleFileView(_:)), separatorBefore: false)
    self.dashboardItem = addToggleItem(
      to: viewMenu, title: "Show Dashboard View", key: "d",
      action: #selector(toggleDashboard(_:)), separatorBefore: false)
    // ⇧⌘U — ⇧⌘R would collide with the History panel's rebase shortcut.
    self.recoveryItem = addToggleItem(
      to: viewMenu, title: "Show Recovery View", key: "u",
      action: #selector(toggleRecovery(_:)), separatorBefore: false)

    // Plain action item (no checkbox — the window's own close button is its
    // "off"). ⇧⌘H: NOT ⌥⌘H, which is the system-wide "Hide Others" and wins
    // over any menu key equivalent (pressing it hid every other app).
    if viewMenu.items.first(where: {
      $0.action == #selector(openHistoryWindowFromMenu(_:))
    }) == nil {
      let item = NSMenuItem(
        title: "Open History in New Window",
        action: #selector(openHistoryWindowFromMenu(_:)), keyEquivalent: "h")
      item.keyEquivalentModifierMask = [.command, .shift]
      item.target = self
      viewMenu.addItem(item)
    }

    // Refresh (the deleted repository toolbar band was its only button), the
    // command palette, and the pane-focus actions — which ship unbound by
    // default, so before this the palette had exactly one route and the five
    // focus actions had none at all. An action with no route is not a feature.
    installPlainItems(
      in: viewMenu,
      items: [
        (title: "Refresh", actionId: "global.refresh",
         key: "r", separatorBefore: true),
        (title: "Command Palette", actionId: "global.commandPalette",
         key: "k", separatorBefore: false),
        (title: "Focus Navigator", actionId: "global.focusNavigator",
         key: "", separatorBefore: true),
        (title: "Focus Canvas", actionId: "global.focusCanvas",
         key: "", separatorBefore: false),
        (title: "Focus Inspector", actionId: "global.focusInspector",
         key: "", separatorBefore: false),
        (title: "Focus Task Dock", actionId: "global.focusTaskDock",
         key: "", separatorBefore: false),
        (title: "Focus Activity", actionId: "global.focusActivity",
         key: "", separatorBefore: false),
      ])

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

  /// Adds plain (non-checkable) command items to an existing menu, skipping
  /// any already installed — `awakeFromNib` can run more than once.
  private func installPlainItems(
    in menu: NSMenu,
    items: [(title: String, actionId: String, key: String,
            separatorBefore: Bool)]
  ) {
    for spec in items {
      if menu.items.contains(where: {
        ($0.representedObject as? String) == spec.actionId
      }) {
        continue
      }
      if spec.separatorBefore && !menu.items.isEmpty {
        menu.addItem(NSMenuItem.separator())
      }
      let item = NSMenuItem(
        title: spec.title, action: #selector(dynamicMenuActionFired(_:)),
        keyEquivalent: spec.key)
      if !spec.key.isEmpty {
        item.keyEquivalentModifierMask = [.command]
      }
      item.representedObject = spec.actionId
      item.target = self
      menu.addItem(item)
    }
  }

  /// Installs (or replaces) the repository menus Dart declared, inserting them
  /// just before the Window menu. Every command item carries its keymap action
  /// id as `representedObject` and shares one selector, which forwards the id
  /// to Dart — so this side never knows what any individual command does.
  private func installDynamicMenus(_ spec: [[String: Any]]) {
    guard let mainMenu = NSApp.mainMenu else { return }

    for item in dynamicMenuItems {
      if let index = mainMenu.items.firstIndex(of: item) {
        mainMenu.removeItem(at: index)
      }
    }
    dynamicMenuItems.removeAll()

    // Same Window-menu anchor as installViewMenuItems: NSApp.windowsMenu is
    // the role-based lookup, the title match only a fallback.
    let anchor =
      mainMenu.items.firstIndex(where: {
        ($0.submenu != nil && $0.submenu === NSApp.windowsMenu)
          || $0.title == "Window" || $0.submenu?.title == "Window"
      }) ?? mainMenu.items.count

    var insertAt = anchor
    for menuSpec in spec {
      guard let title = menuSpec["title"] as? String,
        let items = menuSpec["items"] as? [[String: Any]]
      else { continue }
      let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let submenu = NSMenu(title: title)
      // AppKit's own enable/disable pass would grey out items whose target is
      // nil; ours are validated by validateMenuItem instead.
      submenu.autoenablesItems = true
      populate(menu: submenu, from: items)
      parent.submenu = submenu
      mainMenu.insertItem(parent, at: insertAt)
      dynamicMenuItems.append(parent)
      insertAt += 1
    }
  }

  private func populate(menu: NSMenu, from items: [[String: Any]]) {
    for spec in items {
      if spec["separator"] as? Bool == true {
        menu.addItem(NSMenuItem.separator())
        continue
      }
      guard let title = spec["title"] as? String else { continue }

      if let children = spec["items"] as? [[String: Any]], !children.isEmpty {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = true
        populate(menu: submenu, from: children)
        parent.submenu = submenu
        menu.addItem(parent)
        continue
      }

      let item = NSMenuItem(
        title: title, action: #selector(dynamicMenuActionFired(_:)),
        keyEquivalent: spec["key"] as? String ?? "")
      if let modifiers = spec["modifiers"] as? [String], !modifiers.isEmpty {
        var mask: NSEvent.ModifierFlags = []
        for modifier in modifiers {
          switch modifier {
          case "command": mask.insert(.command)
          case "shift": mask.insert(.shift)
          case "option": mask.insert(.option)
          case "control": mask.insert(.control)
          default: break
          }
        }
        item.keyEquivalentModifierMask = mask
      }
      item.representedObject = spec["actionId"]
      item.target = self
      menu.addItem(item)
    }
  }

  /// Dims any command whose action id is neither reachable in this session
  /// (cross-panel ids a connected session enables — choosing one switches to
  /// the owning panel) nor runnable on the active panel right now.
  /// The item stays in place: "If all of a menu's items are unavailable, the
  /// menu itself needs to remain available so people can open it and learn
  /// about the commands it contains."
  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(dynamicMenuActionFired(_:)) else {
      return super.validateMenuItem(menuItem)
    }
    guard let actionId = menuItem.representedObject as? String else {
      return false
    }
    return enabledActionIds.contains(actionId)
  }

  @objc private func dynamicMenuActionFired(_ sender: Any?) {
    guard let item = sender as? NSMenuItem,
      let actionId = item.representedObject as? String
    else { return }
    menuChannel?.invokeMethod("dispatchAction", arguments: actionId)
  }

  /// Wires the standard "Preferences…" item (⌘, from MainMenu.xib), which had
  /// no action at all — it opened the menu, dimmed, and did nothing, while the
  /// only way to Settings was a gear buried in a repository toolbar.
  private func installPreferencesAction() {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
    for item in appMenu.items where item.title.hasPrefix("Preferences") {
      item.target = self
      item.action = #selector(dynamicMenuActionFired(_:))
      item.representedObject = "global.openSettings"
    }
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

  @objc private func toggleSidebar(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleSidebar", arguments: nil)
  }

  @objc private func toggleFileView(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleFileView", arguments: nil)
  }

  @objc private func toggleDashboard(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleDashboard", arguments: nil)
  }

  @objc private func toggleRecovery(_ sender: Any?) {
    menuChannel?.invokeMethod("toggleRecovery", arguments: nil)
  }

  @objc private func openHistoryWindowFromMenu(_ sender: Any?) {
    // Routed through Dart (not opened directly) so the connected-session
    // gating lives in one place — the bridge no-ops when disconnected.
    hwDebugLog("menu action fired, forwarding to Dart")
    menuChannel?.invokeMethod("openHistoryWindow", arguments: nil)
  }

  private func installHelpMenuItems() {
    guard let mainMenu = NSApp.mainMenu else { return }

    let helpMenu: NSMenu
    if let existing = mainMenu.items.first(where: {
      $0.title == "Help" || $0.submenu?.title == "Help"
    })?.submenu {
      helpMenu = existing
    } else {
      let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
      let created = NSMenu(title: "Help")
      helpItem.submenu = created
      mainMenu.addItem(helpItem)
      helpMenu = created
    }

    if helpMenu.items.first(where: { $0.action == #selector(showGeneralHelp(_:)) }) == nil {
      let item = NSMenuItem(
        title: "Support & Help",
        action: #selector(showGeneralHelp(_:)),
        keyEquivalent: "?"
      )
      item.keyEquivalentModifierMask = [.command]
      item.target = self
      helpMenu.insertItem(item, at: 0)
    }
  }

  @objc private func showGeneralHelp(_ sender: Any?) {
    HelpWindowController.shared.showHelpWindow()
  }

  private func openWindow(_ args: [String: Any]) {
    guard let id = args["windowId"] as? String,
      let kindName = args["kind"] as? String,
      let kind = WindowKind(rawValue: kindName)
    else {
      hwDebugLog("openWindow: bad args")
      return
    }
    // Dedupe is enforced Dart-side (it owns the registry), but guard here too so
    // a duplicate id can never spawn a second engine.
    if let existing = secondaryWindows[id] {
      hwDebugLog("window \(id) already open, fronting")
      existing.front()
      return
    }
    guard let messenger = mainFlutterViewController?.engine.binaryMessenger
    else {
      hwDebugLog("no main messenger — cannot open")
      return
    }
    let controller = SecondaryWindowController(
      windowId: id,
      kind: kind,
      repoPath: args["repoPath"] as? String,
      title: args["title"] as? String,
      connectionLabel: args["connectionLabel"] as? String,
      mainMessenger: messenger,
      onClosed: { [weak self] closedId in
        self?.secondaryWindows.removeValue(forKey: closedId)
        self?.windowsChannel?.invokeMethod(
          "windowClosed", arguments: ["windowId": closedId])
      })
    secondaryWindows[id] = controller
    controller.open()
  }

  deinit {
    if let observer = willCloseObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Quit-path teardown, called from AppDelegate before the main engine's
  /// prepareToTerminate round trip. Nothing to flush: window bounds are
  /// frame-autosaved continuously and the secondary engines hold no session
  /// state of their own. Snapshot the values first — teardown() is synchronous
  /// but defensive against any re-entrant mutation.
  func teardownAllSecondaryWindows() {
    for controller in Array(secondaryWindows.values) {
      controller.teardown()
    }
    secondaryWindows.removeAll()
  }
}
