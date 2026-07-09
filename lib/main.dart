import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';
import 'core/providers/app_providers.dart';
import 'core/theme/app_theme.dart';
import 'features/app_shell.dart';

/// The default first-launch window size (before any bounds are persisted).
/// Sized to leave a comfortable margin on a 13"/14" laptop (~75% width) rather
/// than nearly filling the screen, while staying roomy for the three-pane
/// layout; a persisted size from a prior session always takes precedence.
const kDefaultWindowSize = Size(1080, 720);

/// The minimum size the window may be resized to. Enforced live via
/// `windowManager` so the multi-pane layout stays usable and, in particular, so
/// the app window can never be smaller than an in-app floating window's own
/// minimum — the condition that let the viewer/diff-pop-out size clamps hit
/// their degenerate case and the viewer title bar overflow. Kept in sync with
/// [WindowBoundsStore.minWidth]/[minHeight], which reject a persisted size below
/// this same floor.
const kMinWindowSize = Size(
  WindowBoundsStore.minWidth,
  WindowBoundsStore.minHeight,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Restore the window's last position/size if one was persisted on a
  // previous clean close (see WindowBoundsStore / AppShell.onWindowClose).
  // Falls back to the hardcoded default + centering on first launch, or if
  // the persisted size failed WindowBoundsStore's sanity floor.
  final savedBounds = await WindowBoundsStore.load();

  final windowOptions = WindowOptions(
    size: savedBounds != null
        ? Size(savedBounds.$3, savedBounds.$4)
        : kDefaultWindowSize,
    minimumSize: kMinWindowSize,
    center: savedBounds == null,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'Magic Git',
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // The native window launches fully transparent (MainFlutterWindow) so its
    // default main-display position never paints, and is revealed only by the
    // setOpacity(1) in the `finally`. Keeping the reveal in a `finally` is
    // load-bearing: if any placement step throws (a platform-channel hiccup,
    // a plugin regression), the app must still become visible — the failure
    // mode otherwise is a running process with a permanently invisible window.
    try {
      // Enforce the floor explicitly too: WindowOptions.minimumSize alone isn't
      // reliably applied across window_manager versions, and this guarantees the
      // live constraint regardless of the restored size.
      await windowManager.setMinimumSize(kMinWindowSize);
      if (savedBounds != null) {
        // Place position + size atomically *before* the first show, so the
        // window is realized directly on its target display instead of being
        // created on the main display and then moved — that two-step move was the
        // visible flash (and the blinking of other apps on the target monitor).
        //
        // No display-list validation here on purpose: when the saved monitor is
        // still connected this lands the window right back on it, and when it's
        // gone AppKit's own `constrainFrameRect:toScreen:` pulls the frame onto a
        // visible display (keeping the title bar reachable) as part of this single
        // hidden placement — so the unplugged case degrades to "opens on the main
        // display" with no flash, no off-screen/invisible window.
        await windowManager.setBounds(
          Rect.fromLTWH(
            savedBounds.$1,
            savedBounds.$2,
            savedBounds.$3,
            savedBounds.$4,
          ),
        );
      }
      await windowManager.show();
      await windowManager.focus();
    } finally {
      // Now that it's been placed on the correct monitor and shown, reveal it.
      // This ordering is what keeps other apps on the main screen from blinking
      // as the window is positioned.
      await windowManager.setOpacity(1);
    }
  });

  // Enable macOS window vibrancy
  await WindowManipulator.initialize();

  runApp(
    ProviderScope(
      // Riverpod 3 retries failed providers by default (exp. backoff to ~6s).
      // git/glab failures are usually deterministic (bad path, auth, 4xx), so
      // surface them immediately instead of hiding them behind a retry spinner.
      // Manual refresh and the remote watcher already re-drive on demand.
      retry: (_, _) => null,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MacosApp(
      title: 'Magic Git',
      // Dark-only by design (see AppTheme): pin dark for both slots so the app
      // never renders a half-tuned light appearance regardless of system mode.
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: const AppShell(),
    );
  }
}
