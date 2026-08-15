import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/window_manager_bridge.dart';
import '../../core/settings/keymap.dart';
import '../../core/settings/settings_bus.dart';
import '../../core/theme/app_theme.dart';
import '../app_shell.dart';
import '../common/actions.dart';
import '../common/menu_bar_bridge.dart';
import '../common/menu_bar_spec.dart';
import '../common/session_exit_guard.dart';
import 'tab_strip.dart';
import 'tab_ui_providers.dart';
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
  final alias = ref.watch(tabAliasProvider);
  final segments = repoPath.split('/').where((seg) => seg.isNotEmpty);
  final name = alias ?? (segments.isEmpty ? repoPath : segments.last);
  final branch = ref.watch(
    statusProvider(repoPath).select((s) => s.value?.branch.head),
  );
  return branch == null || branch.isEmpty
      ? '$name — Magic Git'
      : '$name ($branch) — Magic Git';
});

/// The stably-mounted top-level host: it owns [MacosApp] plus the process-level
/// concerns that must survive tab switches — the native `magicgit/menu` bridge,
/// the window lifecycle (bounds persistence, clean-disconnect-on-close, ⌘Q), and
/// the native window title — and mounts exactly ONE tab's [AppShell] at a time
/// (single-active-mount) under that tab's own [ProviderContainer].
///
/// Crucially, the active tab's container is provided via [MacosApp.builder] —
/// ABOVE the app's root Navigator — so modal sheets and dialogs (commit,
/// clone/create, palette), which are pushed on that Navigator, resolve session
/// providers against the active tab rather than the empty root container. The
/// container switches in place on a tab change, leaving the Navigator (and any
/// navigation state) intact.
///
/// These concerns are deliberately NOT in [AppShell]: the active shell remounts
/// on every tab switch, and an end-of-frame `dispose` there would tear down the
/// menu handler out from under the newly-active tab. The host is created once
/// and never remounts, so the menu/window plumbing stays stable while it merely
/// *re-points* its subscriptions at whichever tab is active.
class TabsHost extends ConsumerStatefulWidget {
  const TabsHost({super.key, this.controller});

  /// Test seam: inject a controller to observe/drive tabs. In production the
  /// host creates and owns its own.
  final TabsController? controller;

  @override
  ConsumerState<TabsHost> createState() => _TabsHostState();
}

class _TabsHostState extends ConsumerState<TabsHost> with WindowListener {
  late final TabsController _controller;
  late final bool _ownsController;

  /// Bridge to the native menu bar. The Swift side ("View → Show Output View")
  /// invokes toggles; we push the current checkbox state back so the menu
  /// item's checkmark stays in sync. Routed to the ACTIVE tab's container.
  static const _menuChannel = MethodChannel('magicgit/menu');

  /// Re-pushes the View items' native key equivalents when Keyboard Mappings
  /// persists a change (0009 M2).
  StreamSubscription<void>? _keymapSub;

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
    // Expose the controller to connection sheets pushed above TabsScope. The
    // History bridge is wired in build() — it isn't built until this host's
    // first build watches it, which is after initState.
    TabsController.current = _controller;

    _menuChannel.setMethodCallHandler(_handleMenuCall);
    // Intercept the window close so each tab's SSH session gets a clean
    // disconnect instead of the socket just vanishing when the process dies.
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    // The repository menus are declared in Dart (menu_bar_spec.dart) and built
    // natively from this one payload, so a command exists in exactly one place.
    _menuChannel
        .invokeMethod<void>('installMenus', menuBarChannelPayload())
        .catchError((_) {});

    _wireActive();
    // Push the initial panel/menu state so the native checkmarks and title are
    // correct from the first frame (channel listens only fire on later changes).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pushActiveState();
    });
    // A rebind in Keyboard Mappings must reach the native View items too, or
    // the stale equivalent keeps beating Flutter's handler (0009 M2). The
    // bus fires once per persisted write — no extra debounce needed.
    _keymapSub = SettingsBus.instance.onKeymapWritten.listen((_) {
      if (mounted) _pushViewMenuShortcuts();
    });
  }

  @override
  void dispose() {
    // Detach the native menu handler so a late toggle from Swift can't touch a
    // disposed container.
    _menuChannel.setMethodCallHandler(null);
    _keymapSub?.cancel();
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
      // A History pop-out follows the active tab — retarget it to the new one.
      // isBlank distinguishes a landing tab (nothing to follow) from a repo tab
      // that's merely still connecting (activated synchronously, connects next).
      WindowManagerBridge.current?.onActiveTabChanged(
        _controller.activeId,
        isBlank: _controller.active?.isBlank ?? true,
      );
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
    // What the active tab's active panel can run right now — the native side
    // dims every other command rather than hiding it.
    _activeSubs.add(
      c.listen<Set<String>>(availableActionsProvider, (_, ids) {
        _syncEnabledActions(ids);
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
    _syncEnabledActions(c.read(availableActionsProvider));
    _pushViewMenuShortcuts();
    unawaited(windowManager.setTitle(c.read(windowTitleProvider)));
  }

  /// The View items whose native key equivalents mirror the live keymap
  /// (0009 M2). The pane-focus items ship unbound and stay out.
  static const _viewShortcutIds = [
    'global.toggleOutput',
    'global.toggleFileView',
    'global.toggleDashboard',
    'global.toggleRecovery',
    'global.refresh',
    'global.commandPalette',
  ];

  /// AppKit key equivalents are single characters; a binding on anything
  /// else (Enter, arrows…) clears the native shortcut instead — the Flutter
  /// handler still serves it.
  static String _keyEquivalentFor(KeyBinding binding) {
    final label = LogicalKeyboardKey(binding.keyId).keyLabel;
    return label.length == 1 ? label.toLowerCase() : '';
  }

  void _pushViewMenuShortcuts() {
    final c = _controller.active?.container;
    if (c == null) return;
    final keymap = c.read(keymapProvider);
    final payload = <String, Map<String, Object>>{};
    for (final id in _viewShortcutIds) {
      final binding = (keymap[id] ?? const <KeyBinding>[]).firstOrNull;
      final key = binding == null ? '' : _keyEquivalentFor(binding);
      payload[id] = {
        'key': key,
        'modifiers': key.isEmpty
            ? const <String>[]
            : [
                if (binding!.meta) 'command',
                if (binding.shift) 'shift',
                if (binding.alt) 'option',
                if (binding.control) 'control',
              ],
      };
    }
    _menuChannel
        .invokeMethod<void>('setViewMenuShortcuts', payload)
        .catchError((_) {});
  }

  void _syncMenuState(String method, bool visible) {
    _menuChannel.invokeMethod<void>(method, visible).catchError((_) {});
  }

  void _syncEnabledActions(Set<String> ids) {
    _menuChannel
        .invokeMethod<void>('setEnabledActions', ids.toList())
        .catchError((_) {});
  }

  Future<dynamic> _handleMenuCall(MethodCall call) async {
    final c = _controller.active?.container;
    if (c == null) return null;
    switch (call.method) {
      case 'toggleOutputView':
        c.read(outputLogProvider.notifier).toggle();
      case 'toggleSidebar':
        c.read(sidebarToggleRequestProvider.notifier).request();
      case 'toggleFileView':
        c.read(fileViewVisibleProvider.notifier).toggle();
      case 'toggleDashboard':
        c.read(dashboardVisibleProvider.notifier).toggle();
      case 'toggleRecovery':
        c.read(recoveryVisibleProvider.notifier).toggle();
      case 'dispatchAction':
        // Parked for AppShell, which is the only thing that can switch to the
        // owning panel before the intent is consumed.
        final actionId = call.arguments;
        if (actionId is String) {
          c.read(menuActionRequestProvider.notifier).request(actionId);
        }
      case 'openHistoryWindow':
        await WindowManagerBridge.current?.openHistory();
      case 'prepareToTerminate':
        // ⌘Q (or any AppKit terminate path). The delegate holds termination
        // open (.terminateLater, with a native timeout backstop) until this
        // returns; persist the final bounds and close EVERY tab's SSH session
        // cleanly instead of letting the process die with sockets open.
        // Returns false to DECLINE termination — either a session with work
        // at stake needs the user's say-so first (0009 M5; the confirm path
        // re-enters via terminateNow), or the user cancelled.
        return _onPrepareToTerminate();
      case 'syncMenuState':
        // The native side asks for this once its menu items are installed, so
        // the checkmarks are correct even if our startup push raced item
        // creation and was dropped.
        _pushActiveState();
    }
    return null;
  }

  Future<bool> _onPrepareToTerminate() async {
    _boundsSaveTimer?.cancel();
    try {
      await _saveBounds();
    } catch (_) {
      // Best-effort — never block quitting on a bounds read.
    }
    final atRisk = _sessionsAtRisk();
    if (atRisk.isEmpty) {
      await _disconnectAllTabs();
      return true;
    }
    // Decline the terminate FIRST (the native side keeps a 3s backstop, so
    // a confirm dialog can never answer over this channel), then ask; on
    // confirm, finish teardown and re-enter termination via terminateNow.
    unawaited(() async {
      if (!mounted) return;
      final proceed = await confirmAction(
        context,
        title: 'Quit Magic Git?',
        message: sessionExitSummaryMessage(atRisk),
        confirmLabel: 'Quit',
        destructive: true,
      );
      if (!proceed) return;
      await _disconnectAllTabs();
      await _menuChannel.invokeMethod<void>('terminateNow');
    }());
    return false;
  }

  /// Every connected tab's session with work at stake — the quit/window-close
  /// summary's input (0009 M5).
  List<SessionAtRisk> _sessionsAtRisk() => sessionsAtRisk([
    for (final t in _controller.tabs)
      if (t.container.read(connectionProvider) case final connection
          when connection.isConnected && connection.repoPath != null)
        (t.container, connection.repoPath!),
  ]);

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
    // Same at-stake summary as ⌘Q (0009 M5); Cancel simply leaves the
    // window up — preventClose is still armed, so nothing has happened.
    final atRisk = _sessionsAtRisk();
    if (atRisk.isNotEmpty) {
      if (!mounted) return;
      final proceed = await confirmAction(
        context,
        title: 'Close window?',
        message: sessionExitSummaryMessage(atRisk),
        confirmLabel: 'Close Window',
        destructive: true,
      );
      if (!proceed) return;
    }
    await _disconnectAllTabs();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    // Instantiate + keep alive the SINGLE native-window bridge in this (root)
    // container for the app's lifetime. Watching it here builds it (setting
    // WindowManagerBridge.current), so wire its tab resolvers right after — this
    // is the earliest point the bridge exists (it doesn't yet in initState), and
    // re-setting the closures each build is a cheap no-op.
    ref.watch(windowManagerBridgeProvider);
    WindowManagerBridge.current
      ?..sessionContainerFor = ((tabId) =>
          tabId == null ? null : _controller.containerFor(tabId))
      ..activeTabId = (() => _controller.activeId)
      ..containerForRepo = _controller.containerForRepo;
    return MacosApp(
      title: 'Magic Git',
      // Dark-only by design (see AppTheme): pin dark for both slots so the app
      // never renders a half-tuned light appearance regardless of system mode.
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      // Provide the tab controller + the ACTIVE tab's container ABOVE the root
      // Navigator, so sheets/dialogs pushed there (commit, clone/create,
      // palette) read the active tab's live session — not the empty root
      // container. Rebuilt on every tab switch (this host setState's), so the
      // container tracks the active tab; the Navigator itself is preserved.
      builder: (context, child) => TabsScope(
        controller: _controller,
        child: UncontrolledProviderScope(
          container: _controller.active!.container,
          child: child!,
        ),
      ),
      home: const _TabsBody(),
    );
  }
}

/// The window body under [MacosApp]: the tab strip plus the active tab's
/// [AppShell]. The shell is keyed by the active tab id so switching tabs mounts
/// a fresh shell against the newly-active container (background tabs' autoDispose
/// fetches quiesce; their sockets stay alive) — single-active-mount. The ambient
/// container comes from [TabsHost]'s `MacosApp.builder`.
class _TabsBody extends StatelessWidget {
  const _TabsBody();

  @override
  Widget build(BuildContext context) {
    final controller = TabsScope.of(context);
    return Column(
      children: [
        const TabStrip(),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(controller.activeId),
            child: const AppShell(),
          ),
        ),
      ],
    );
  }
}
