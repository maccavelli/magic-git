/// Central registry of the method-channel names the native multi-window system
/// and the Dart side must agree on. One owner for every string, so a rename can
/// never drift across the isolates' worth of files that used to hardcode them
/// (the old single-History-window code repeated `magicgit/history` and
/// `magicgit/history/hub` across four files).
///
/// Channel-plane split:
///  * [windowControlChannel] — one MAIN-engine channel, the window registry API
///    (open/close/front) + the native→Dart `windowClosed` notification. A
///    single multiplexed channel is correct here because a registry is
///    inherently id-addressed.
///  * [windowBootstrapChannel] — a fixed-name channel installed by each
///    controller on its OWN child engine's messenger (no collision: distinct
///    messengers). The child pulls its descriptor and ships early debug lines
///    here, before it knows its per-window hub name.
///  * [windowHubChannel] / [windowLifecycleChannel] — PER-WINDOW data-plane
///    channels, one pair per open window, so each window's traffic is isolated
///    and the "no correlation id needed" property is preserved (every
///    `invokeMethod` carries its own reply handle; ordering is enforced in the
///    main isolate's single lane scheduler).
library;

/// The main-engine control channel: `openWindow`/`closeWindow`/`frontWindow`
/// (Dart→native) and `windowClosed` (native→Dart). Every method carries a
/// `windowId`, minted Dart-side by [WindowManagerBridge].
const String windowControlChannel = 'magicgit/windows';

/// The per-engine bootstrap channel. Installed by the controller on the child
/// engine's messenger before `run()`, so the child's first `descriptor` pull
/// always finds a handler. Also carries the child's early `debugLog` lines
/// (before it has resolved its per-window hub name).
const String windowBootstrapChannel = 'magicgit/window/bootstrap';

/// The per-window data-plane hub for [windowId] — the relayed git command and
/// event traffic between the main isolate and this window's isolate.
String windowHubChannel(String windowId) => 'magicgit/window/$windowId/hub';

/// The per-window lifecycle channel for [windowId] — native→Dart pushes of
/// [AppLifecycleState] name as the window is occluded/minimized/revealed, so
/// the child can pause and resume its own tickers and timers.
String windowLifecycleChannel(String windowId) =>
    'magicgit/window/$windowId/lifecycle';
