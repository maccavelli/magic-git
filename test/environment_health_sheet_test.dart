// Smoke test for the Environment health ("doctor") panel: it renders per-tool
// status from the resolved environment and shows install hints for what's
// missing.

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/install_planner.dart';
import 'package:remote_magic_git/core/settings/install_service.dart';
import 'package:remote_magic_git/core/ssh/environment_probe.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/settings/environment_health_sheet.dart';

class _FixedEnv extends BinaryEnvironmentNotifier {
  _FixedEnv(this._env);
  final RemoteEnvironment _env;
  @override
  RemoteEnvironment build() => _env;
}

/// A connected session whose re-probe is a no-op, so the install flow can run
/// without touching a real executor.
class _ConnectedConn extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: '/repo',
  );
  @override
  Future<void> reprobeBinaries() async {}
}

/// Records install runs and reports fixed host capabilities.
class _FakeInstall extends InstallService {
  _FakeInstall(this.caps) : super(SSHCommandExecutor(SSHClientManager()));
  final HostCapabilities caps;
  final List<String> ran = [];
  @override
  Future<HostCapabilities> probeCapabilities(String repoPath) async => caps;
  @override
  Future<SSHCommandResult> run(String repoPath, String command) async {
    ran.add(command);
    return const SSHCommandResult(exitCode: 0, stdout: 'done', stderr: '');
  }
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

  testWidgets('one-click install runs the planned command on a brew host', (
    tester,
  ) async {
    final fake = _FakeInstall(const HostCapabilities(hasBrew: true));
    const env = RemoteEnvironment(
      os: 'macos',
      path: '/usr/bin',
      found: {'git': '/usr/bin/git'},
      versions: {'git': '2.39.3'},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          binaryEnvironmentProvider.overrideWith(() => _FixedEnv(env)),
          connectionProvider.overrideWith(() => _ConnectedConn()),
          installServiceProvider.overrideWithValue(fake),
        ],
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: EnvironmentHealthSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle(); // runs the post-frame capability probe

    // glab is the first missing tool on macOS → its Homebrew install button.
    expect(find.text('Install with Homebrew'), findsWidgets);
    await tester.tap(find.text('Install with Homebrew').first);
    await tester.pumpAndSettle();

    // The confirm dialog shows the exact command; approve it.
    expect(find.textContaining('brew install glab'), findsWidgets);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(fake.ran, contains('brew install glab'));
  });
}
