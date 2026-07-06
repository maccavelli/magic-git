import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:window_manager/window_manager.dart';
import 'core/providers/app_providers.dart';
import 'core/theme/app_theme.dart';
import 'features/app_shell.dart';

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
        : const Size(1200, 800),
    center: savedBounds == null,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'Magic Git',
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (savedBounds != null) {
      await windowManager.setPosition(Offset(savedBounds.$1, savedBounds.$2));
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
