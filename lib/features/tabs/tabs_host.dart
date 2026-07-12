import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/window_manager_bridge.dart';
import '../app_shell.dart';
import 'tab_strip.dart';
import 'tabs_controller.dart';
import 'tabs_scope.dart';

/// The native window title: `repo (branch) — Magic Git` while a repo is active,
/// plain `Magic Git` otherwise. Shown in Mission Control, the app switcher, and
/// the Window menu (the in-window titlebar is hidden), so it's how a user tells
/// two projects apart at the OS level. Tracks the ACTIVE tab's session — the
/// host re-points its subscription when the active tab changes.
final windowTitleProvider = Provider.autoDispose<String>((ref) {
  final connection = ref.watch(connectionProvider);
  final repoPath = connection.repoPath;
  if (!connection.isConnected || repoPath == null) return 'Magic Git';
  final segments = repoPath.split('/').where((seg) => seg.isNotEmpty);
  final name = segments.isEmpty ? repoPath : segments.last;
  final branch = ref.watch(
    statusProvider(repoPath).select((s) => s.value?.branch.head),
  );
  return branch == null || branch.isEmpty
      ? '$name — Magic Git'
      : '$name ($branch) — Magic Git';
});

/// The stably-mounted top-level host: it owns the process-level concerns that
/// must survive tab switches — the native `magicgit/menu` bridge, the window
/// lifecycle (bounds persistence, clean-disconnect-on-close, ⌘Q), and the
/// native window title — and mounts exactly ONE tab's [AppShell] at a time
/// (single-active-mount) under that tab's own [ProviderContainer].
///
/// These concerns are deliberately NOT in [AppShell]: the active shell remounts
/// on every tab switch, and an end-of-frame `dispose` there would tear down the
/// menu handler out from under the newly-active tab. The host is created once
/// and never remounts, so the menu/window plumbing stays stable while it merely
/// *re-points* its subscriptions at whichever tab is active.
class TabsHost extends StatefulWidget {
  const TabsHost({super.key, this.controller});

  /// Test seam: inject a controller to observe/drive tabs. In production the
  /// host creates and owns its own.
  final TabsController? controller;

  @override
  State<TabsHost> createState() => _TabsHostState();
}

class _TabsHostState extends State<TabsHost> with WindowListener {
  late final TabsController _controller;
  late final bool _ownsController;

  /// Bridge to the native menu bar. The Swift side ("View → Show Output View")
  /// invokes toggles; we push the current checkbox state back so the menu
  /// item's checkmark stays in sync. Routed to the ACTIVE tab's container.
  static const _menuChannel = MethodChannel('magicgit/menu');

  /// Debounces persisting the window's bounds while it's moved/resized. Saving
  /// continuously (rather than only on close/quit) is what makes the restore
  /// reliable: ⌘Q is intercepted (`prepareToTerminate`) and the red button
  /// fires [onWindowClose], but a crash or force-kill fires neither, and even a
  /// clean close's single final write can be lost to the process dying before
  /// it flushes. By the time the app exits, the last position/size is already
  /// persisted. See WindowBoundsStore and main.dart's restore.
  Timer? _boundsSaveTimer;

  /// Live subscriptions against the ACTIVE tab's container (menu checkmarks +
  /// window title). Closed and re-opened against the new container whenever the
  /// active tab changes — see [_wireActive].
  final List<ProviderSubscription> _activeSubs = [];
  String? _wiredTabId;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TabsController();
    _controller.ensureInitialTab();
    _controller.addListener(_onTabsChanged);
    // Expose the controller to connection sheets pushed above TabsScope.
    TabsController.current = _controller;
    // Point the single root History bridge at this controller so a pop-out pins
    // to (and serves from) its spawning tab's container. The bridge was built by
    // the root ProviderScope keeper before this host mounted.
    WindowManagerBridge.current
      ?..sessionContainerFor =
          ((tabId) => tabId == null ? null : _controller.containerFor(tabId))
      ..activeTabId = (() => _controller.activeId);

    _menuChannel.setMethodCallHandler(_handleMenuCall);
    // Intercept the window close so each tab's SSH session gets a clean
    // disconnect instead of the socket just vanishing when the process dies.
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    _wireActive();
    // Push the initial panel/menu state so the native checkmarks and title are
    // correct from the first frame (channel listens only fire on later changes).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pushActiveState();
    });
  }

  @override
  void dispose() {
    // Detach the native menu handler so a late toggle from Swift can't touch a
    // disposed container.
    _menuChannel.setMethodCallHandler(null);
    _boundsSaveTimer?.cancel();
    windowManager.removeListener(this);
    for (final s in _activeSubs) {
      s.close();
    }
    _controller.removeListener(_onTabsChanged);
    if (identical(TabsController.current, _controller)) {
      TabsController.current = null;
    }
    // Un-wire the bridge so it stops resolving against a disposed controller.
    WindowManagerBridge.current
      ?..sessionContainerFor = ((_) => null)
      ..activeTabId = (() => null);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onTabsChanged() {
    if (_controller.activeId != _wiredTabId) {
      _wireActive();
      _pushActiveState();
    }
    if (mounted) setState(() {});
  }

  /// Re-points the menu-checkmark / window-title subscriptions at the active
  /// tab's container. Called on boot and on every active-tab switch.
  void _wireActive() {
    for (final s in _activeSubs) {
      s.close();
    }
    _activeSubs.clear();
    _wiredTabId = _controller.activeId;
    final c = _controller.active?.container;
    if (c == null) return;
    // Explicit type args: adding into the raw-typed list would otherwise drive
    // `listen`'s generic to `dynamic` via the argument's context type.
    _activeSubs.add(
      c.listen<String>(windowTitleProvider, (_, title) {
        unawaited(windowManager.setTitle(title));
      }),
    );
    _activeSubs.add(
      c.listen<bool>(outputLogProvider.select((s) => s.visible), (_, v) {
        _syncMenuState('setOutputViewChecked', v);
      }),
    );
    _activeSubs.add(
      c.listen<bool>(fileViewVisibleProvider, (_, v) {
        _syncMenuState('setFileViewChecked', v);
      }),
    );
    _activeSubs.add(
      c.listen<bool>(dashboardVisibleProvider, (_, v) {
        _syncMenuState('setDashboardChecked', v);
      }),
    );
    _activeSubs.add(
      c.listen<bool>(recoveryVisibleProvider, (_, v) {
        _syncMenuState('setRecoveryChecked', v);
      }),
    );
  }

  /// Pushes the active tab's current panel states + title to native — used on
  /// boot, on tab switch, and when Swift asks (`syncMenuState`), since a
  /// `listen` only fires on subsequent changes.
  void _pushActiveState() {
    final c = _controller.active?.container;
    if (c == null) return;
    _syncMenuState('setOutputViewChecked', c.read(outputLogProvider).visible);
    _syncMenuState('setFileViewChecked', c.read(fileViewVisibleProvider));
    _syncMenuState('setDashboardChecked', c.read(dashboardVisibleProvider));
    _syncMenuState('setRecoveryChecked', c.read(recoveryVisibleProvider));
    unawaited(windowManager.setTitle(c.read(windowTitleProvider)));
  }

  void _syncMenuState(String method, bool visible) {
    _menuChannel.invokeMethod<void>(method, visible).catchError((_) {});
  }

  Future<dynamic> _handleMenuCall(MethodCall call) async {
    final c = _controller.active?.container;
    if (c == null) return null;
    switch (call.method) {
      case 'toggleOutputView':
        c.read(outputLogProvider.notifier).toggle();
      case 'toggleFileView':
        c.read(fileViewVisibleProvider.notifier).toggle();
      case 'toggleDashboard':
        c.read(dashboardVisibleProvider.notifier).toggle();
      case 'toggleRecovery':
        c.read(recoveryVisibleProvider.notifier).toggle();
      case 'openHistoryWindow':
        await WindowManagerBridge.current?.openHistory();
      case 'prepareToTerminate':
        // ⌘Q (or any AppKit terminate path). The delegate holds termination
        // open (.terminateLater, with a native timeout backstop) until this
        // returns; persist the final bounds and close EVERY tab's SSH session
        // cleanly instead of letting the process die with sockets open.
        await _onPrepareToTerminate();
      case 'syncMenuState':
        // The native side asks for this once its menu items are installed, so
        // the checkmarks are correct even if our startup push raced item
        // creation and was dropped.
        _pushActiveState();
    }
    return null;
  }

  Future<void> _onPrepareToTerminate() async {
    _boundsSaveTimer?.cancel();
    try {
      await _saveBounds();
    } catch (_) {
      // Best-effort — never block quitting on a bounds read.
    }
    await _disconnectAllTabs();
  }

  /// Cleanly disconnects every open tab's session — used on window close and
  /// ⌘Q so no tab leaves a socket dangling.
  Future<void> _disconnectAllTabs() async {
    for (final t in _controller.tabs) {
      try {
        await t.container.read(connectionProvider.notifier).disconnect();
      } catch (_) {
        // Best-effort — one tab's hiccup must not block the others' teardown.
      }
    }
  }

  @override
  void onWindowMoved() => _persistBoundsSoon();

  @override
  void onWindowResized() => _persistBoundsSoon();

  /// Persist the window's current bounds shortly after it settles. Debounced so
  /// a drag/resize that emits a burst of events writes once, not on every tick.
  void _persistBoundsSoon() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      // A minimized or full-screen frame isn't where the user wants the window
      // to reopen, so don't persist those transient bounds.
      if (await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      await _saveBounds();
    });
  }

  Future<void> _saveBounds() async {
    final bounds = await windowManager.getBounds();
    await WindowBoundsStore.save(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    );
  }

  @override
  void onWindowClose() async {
    if (!await windowManager.isPreventClose()) return;
    // Capture bounds before the window actually closes so the next launch can
    // restore this position/size (see WindowBoundsStore / main.dart).
    try {
      await _saveBounds();
    } catch (_) {
      // Best-effort.
    }
    await _disconnectAllTabs();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final active = _controller.active!;
    return TabsScope(
      controller: _controller,
      child: Column(
        children: [
          const TabStrip(),
          Expanded(
            // Single-active-mount: only the active tab's AppShell is mounted,
            // keyed by tab id so switching disposes the old shell and builds a
            // fresh one against the newly-active container (background tabs'
            // autoDispose fetches quiesce; their sockets stay alive).
            child: UncontrolledProviderScope(
              key: ValueKey(active.id),
              container: active.container,
              child: const AppShell(),
            ),
          ),
        ],
      ),
    );
  }
}
