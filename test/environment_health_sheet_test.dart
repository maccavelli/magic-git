// Smoke test for the Environment health ("doctor") panel: it renders per-tool
// status from the resolved environment and shows install hints for what's
// missing.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/features/settings/environment_health_sheet.dart';

class _FixedEnv extends BinaryEnvironmentNotifier {
  _FixedEnv(this._env);
  final RemoteEnvironment _env;
  @override
  RemoteEnvironment build() => _env;
}

Future<void> _pump(WidgetTester tester, RemoteEnvironment env) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [binaryEnvironmentProvider.overrideWith(() => _FixedEnv(env))],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: EnvironmentHealthSheet(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows OK version for git and an install hint for missing glab', (
    tester,
  ) async {
    const env = RemoteEnvironment(
      os: 'macos',
      path: '/usr/bin',
      found: {'git': '/usr/bin/git'},
      versions: {'git': '2.39.3'},
    );
    await _pump(tester, env);

    // git present with its version.
    expect(find.text('git'), findsOneWidget);
    expect(find.text('OK · 2.39.3'), findsOneWidget);

    // glab (a feature tool) is missing → shown, with the Homebrew install hint.
    expect(find.text('glab'), findsOneWidget);
    expect(find.text('Not installed'), findsWidgets);
    expect(find.text('brew install glab'), findsOneWidget);

    // inotifywait is Linux-only, so it's not listed on a macOS host.
    expect(find.text('inotifywait'), findsNothing);
  });

  testWidgets('flags an outdated git against the minimum version', (
    tester,
  ) async {
    const env = RemoteEnvironment(
      os: 'linux',
      path: '/usr/bin',
      found: {'git': '/usr/bin/git'},
      versions: {'git': '2.20.0'}, // below the 2.24 floor
    );
    await _pump(tester, env);

    expect(find.textContaining('Update ·'), findsOneWidget);
    // Linux git upgrade guidance is offered.
    expect(find.text('sudo apt install git'), findsOneWidget);
    // fswatch is macOS-only → absent on Linux.
    expect(find.text('fswatch'), findsNothing);
  });

  testWidgets('prompts to connect when nothing is detected', (tester) async {
    await _pump(tester, RemoteEnvironment.empty);
    expect(find.textContaining('Connect to a repository'), findsOneWidget);
  });
}
