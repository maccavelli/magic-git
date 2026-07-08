import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:screen_retriever/screen_retriever.dart';
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
  var savedBounds = await WindowBoundsStore.load();

  // Guard the multi-monitor restore: only trust the saved *position* if it
  // still lands on a currently-connected display. If that monitor was
  // unplugged or the displays were rearranged, restoring the old coordinates
  // makes the window open off-screen — which is what caused it to flash onto
  // the vanished display (blinking other apps there) before snapping back to
  // the main one. In that case we drop the whole saved rect and re-center at
  // the default size, which always fits the primary display.
  if (savedBounds != null) {
    try {
      final displays = await screenRetriever.getAllDisplays();
      final frames = [
        for (final d in displays)
          Rect.fromLTWH(
            (d.visiblePosition ?? Offset.zero).dx,
            (d.visiblePosition ?? Offset.zero).dy,
            (d.visibleSize ?? d.size).width,
            (d.visibleSize ?? d.size).height,
          ),
      ];
      if (!WindowBoundsStore.boundsOnDisplay(savedBounds, frames)) {
        savedBounds = null;
      }
    } catch (_) {
      // Couldn't enumerate displays — trust the saved bounds rather than
      // second-guessing a good position on a probe failure.
    }
  }

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
    // Enforce the floor explicitly too: WindowOptions.minimumSize alone isn't
    // reliably applied across window_manager versions, and this guarantees the
    // live constraint regardless of the restored size.
    await windowManager.setMinimumSize(kMinWindowSize);
    if (savedBounds != null) {
      // Place position + size atomically *before* the first show, so the
      // window is realized directly on its target display instead of being
      // created on the main display and then moved (the visible flash).
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
