// The main-window tool-health banner: appears when connected and a tool is
// missing/outdated, stays hidden when healthy or disconnected, and can be
// dismissed until the situation changes.

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/features/common/tool_icon_button.dart';
import 'package:remote_magic_git/features/settings/tool_health_banner.dart';

class _FixedEnv extends BinaryEnvironmentNotifier {
  _FixedEnv(this._env);
  final RemoteEnvironment _env;
  @override
  RemoteEnvironment build() => _env;
}

/// A connection notifier stuck in a chosen connected/disconnected state, so the
/// banner can be exercised without a real SSH session.
class _FixedConn extends ConnectionController {
  _FixedConn(this._connected);
  final bool _connected;
  @override
  ConnectionState build() => _connected
      ? const ConnectionState(
          phase: ConnectionPhase.connected,
          repoPath: '/repo',
        )
      : const ConnectionState();
}

/// ToolIconButton wraps MacosTooltip (not Flutter's Tooltip).
Finder _byMacosTooltip(String message) => find.byWidgetPredicate(
  (w) => w is MacosTooltip && w.message == message,
);

Future<void> _pump(
  WidgetTester tester, {
  required RemoteEnvironment env,
  required bool connected,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        binaryEnvironmentProvider.overrideWith(() => _FixedEnv(env)),
        connectionProvider.overrideWith(() => _FixedConn(connected)),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: Center(child: ToolHealthBanner()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// git present, glab missing → a feature-tool warning.
const _glabMissing = RemoteEnvironment(
  os: 'macos',
  path: '/usr/bin',
  found: {'git': '/usr/bin/git'},
  versions: {'git': '2.39.3'},
);

void main() {
  testWidgets('shows a warning when connected and a feature tool is missing', (
    tester,
  ) async {
    await _pump(tester, env: _glabMissing, connected: true);
    expect(find.textContaining('glab is not installed'), findsOneWidget);
    expect(_byMacosTooltip('Check environment'), findsOneWidget);
    expect(find.byType(ToolIconButton), findsNWidgets(2)); // doctor + dismiss
  });

  testWidgets('shows nothing when disconnected, even if env looks unhealthy', (
    tester,
  ) async {
    await _pump(tester, env: _glabMissing, connected: false);
    expect(find.textContaining('not installed'), findsNothing);
  });

  testWidgets('shows nothing when connected and all tools are present', (
    tester,
  ) async {
    const healthy = RemoteEnvironment(
      os: 'macos',
      path: '/usr/bin',
      found: {
        'git': '/usr/bin/git',
        'glab': '/usr/bin/glab',
        'gh': '/usr/bin/gh',
        'fswatch': '/usr/bin/fswatch',
      },
      versions: {'git': '2.39.3'},
    );
    await _pump(tester, env: healthy, connected: true);
    expect(find.byType(ToolIconButton), findsNothing);
  });

  testWidgets('dismiss hides the banner', (tester) async {
    await _pump(tester, env: _glabMissing, connected: true);
    expect(find.textContaining('glab is not installed'), findsOneWidget);

    await tester.tap(_byMacosTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('glab is not installed'), findsNothing);
  });
}
