// The Windows shell prompt (MADR 0070, 0070-PLAN Phase 4): what each kind
// says and offers, that its buttons reach the controller, and — through
// AppShell against a fake Windows host — that the prompt appears on its own
// and goes away when the connect it stopped is cancelled or retried.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/ssh/windows_host_probe.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/connection/windows_shell_prompt_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bash = r'C:\Program Files\Git\bin\bash.exe';

WindowsHostFacts _facts({
  String defaultShell = '',
  String bash = _bash,
  bool admin = true,
}) => WindowsHostFacts.parse(
  'MGW_PS=5.1.26100.2161\n'
  'MGW_DEFAULT_SHELL=$defaultShell\n'
  'MGW_BASH=$bash\n'
  'MGW_ADMIN=${admin ? 1 : 0}\n',
)!;

/// A controller whose state the test chooses, recording the prompt's calls.
class _FakeConnection extends ConnectionController {
  _FakeConnection(this._initial);
  final ConnectionState _initial;
  final List<String> calls = [];

  @override
  ConnectionState build() => _initial;

  @override
  Future<void> enableGitBashShell() async => calls.add('enable');

  @override
  Future<void> retryConnect() async => calls.add('retry');

  @override
  Future<void> dismissWindowsShellPrompt() async => calls.add('dismiss');
}

Future<_FakeConnection> _pumpSheet(
  WidgetTester tester,
  WindowsShellPrompt prompt, {
  VoidCallback? onOpenSettings,
}) async {
  final fake = _FakeConnection(
    ConnectionState(phase: ConnectionPhase.error, windowsShellPrompt: prompt),
  );
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionProvider.overrideWith(() => fake)],
      child: MacosApp(
        home: MacosWindow(
          child: WindowsShellPromptSheet(onOpenSettings: onOpenSettings),
        ),
      ),
    ),
  );
  await tester.pump();
  return fake;
}

// --- AppShell against a fake Windows host -------------------------------------

class _Manager extends SSHClientManager {
  int disconnects = 0;
  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {}
  @override
  Future<void>? get done => Completer<void>().future;
  @override
  Future<void> disconnect() async => disconnects++;
}

/// Reports Windows, answers the probe with [defaultShell], and runs POSIX
/// commands as Git Bash would once that shell is bash.
class _WindowsHost extends SSHCommandExecutor {
  _WindowsHost() : super(SSHClientManager());
  String defaultShell = '';

  @override
  String? get remoteVersion => 'SSH-2.0-OpenSSH_for_Windows_9.5';

  @override
  Future<SSHCommandResult> executeRaw(
    String command, {
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    ExecLane lane = ExecLane.isolated,
  }) async => SSHCommandResult(
    exitCode: 0,
    stdout:
        'MGW_PS=5.1\nMGW_DEFAULT_SHELL=$defaultShell\nMGW_BASH=$_bash\n'
        'MGW_ADMIN=1\n',
    stderr: '',
  );

  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
    Duration? activityIdle,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
    CommandOutputCallback? onOutput,
  }) async {
    if (gitArgs.contains('rev-parse')) {
      return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
    }
    if (gitArgs.isNotEmpty &&
        gitArgs.first == 'sh' &&
        gitArgs.join(' ').contains('uname')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: 'OS=MINGW64_NT-10.0-26100\nPATH=/usr/bin\n',
        stderr: '',
      );
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  group('the sheet', () {
    testWidgets('not active: the cause, the path, the command, Enable', (
      tester,
    ) async {
      final prompt = WindowsShellPrompt(
        kind: WindowsShellPromptKind.notActive,
        facts: _facts(),
      );
      final fake = await _pumpSheet(tester, prompt);

      expect(find.text('Git Bash Is Not the SSH Shell'), findsOneWidget);
      expect(find.textContaining('SSH shell is cmd.exe'), findsOneWidget);
      expect(find.text('Git Bash: $_bash'), findsOneWidget);
      expect(
        find.textContaining('every SSH user of this host'),
        findsOneWidget,
      );
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        enableGitBashCommand(_bash),
      );
      expect(find.textContaining(kDisableGitBashCommand), findsOneWidget);
      expect(find.textContaining('not an administrator'), findsNothing);

      await tester.tap(find.text('Enable'));
      await tester.tap(find.text('Reconnect'));
      await tester.tap(find.text('Cancel'));
      expect(fake.calls, ['enable', 'retry', 'dismiss']);
    });

    testWidgets('a standard account is told Enable will be refused', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        WindowsShellPrompt(
          kind: WindowsShellPromptKind.notActive,
          facts: _facts(admin: false),
        ),
      );
      expect(find.textContaining('not an administrator'), findsOneWidget);
    });

    testWidgets('while enabling, there is no second Enable', (tester) async {
      final fake = await _pumpSheet(
        tester,
        WindowsShellPrompt(
          kind: WindowsShellPromptKind.notActive,
          facts: _facts(),
        ).asEnabling(),
      );
      expect(find.text('Enabling…'), findsOneWidget);
      await tester.tap(find.text('Enabling…'));
      expect(fake.calls, isEmpty);
    });

    testWidgets("a failed Enable shows the host's words", (tester) async {
      await _pumpSheet(
        tester,
        WindowsShellPrompt(
          kind: WindowsShellPromptKind.notActive,
          facts: _facts(),
        ).withEnableError('Requested registry access is not allowed.'),
      );
      expect(
        find.text('Enable failed: Requested registry access is not allowed.'),
        findsOneWidget,
      );
    });

    testWidgets('not installed: the install command and Settings, no Enable', (
      tester,
    ) async {
      var settingsOpened = false;
      await _pumpSheet(
        tester,
        WindowsShellPrompt(
          kind: WindowsShellPromptKind.notInstalled,
          facts: _facts(bash: ''),
        ),
        onOpenSettings: () => settingsOpened = true,
      );

      expect(find.text('Git Bash Is Not Installed'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'winget install --id Git.Git -e',
      );
      expect(find.text('Enable'), findsNothing);
      await tester.tap(find.text('Open Settings'));
      expect(settingsOpened, isTrue);
    });

    testWidgets('probe failed: the reason, and Reconnect', (tester) async {
      await _pumpSheet(
        tester,
        const WindowsShellPrompt(
          kind: WindowsShellPromptKind.probeFailed,
          detail: 'powershell.exe was not found',
        ),
      );
      expect(find.text("Couldn't Check This Windows Host"), findsOneWidget);
      expect(
        find.textContaining('powershell.exe was not found'),
        findsOneWidget,
      );
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Enable'), findsNothing);
    });
  });

  group('through AppShell', () {
    const profile = SSHConnectionProfile(host: 'winbox', username: 'u');

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<(ProviderContainer, _Manager, _WindowsHost)> pumpShell(
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final manager = _Manager();
      final host = _WindowsHost();
      final container = ProviderContainer(
        overrides: [
          sshClientManagerProvider.overrideWithValue(manager),
          executorProvider.overrideWithValue(host),
          gitServiceProvider.overrideWithValue(GitService(host)),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox.expand(child: AppShell()),
          ),
        ),
      );
      await settle(tester);
      return (container, manager, host);
    }

    testWidgets('a stopped connect shows the prompt; Cancel releases it', (
      tester,
    ) async {
      final (container, manager, _) = await pumpShell(tester);
      unawaited(
        container
            .read(connectionProvider.notifier)
            .connect(profile: profile, repoPath: '/c/repo'),
      );
      await settle(tester);

      expect(find.text('Git Bash Is Not the SSH Shell'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.text('Git Bash Is Not the SSH Shell'), findsNothing);
      // The route itself, not just its text: a sheet left open with nothing
      // in it would still block the app behind its barrier.
      expect(find.byType(WindowsShellPromptSheet), findsNothing);
      expect(container.read(connectionProvider).windowsShellPrompt, isNull);
      expect(manager.disconnects, greaterThanOrEqualTo(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('Esc closes the prompt and releases the session too', (
      tester,
    ) async {
      final (container, manager, _) = await pumpShell(tester);
      unawaited(
        container
            .read(connectionProvider.notifier)
            .connect(profile: profile, repoPath: '/c/repo'),
      );
      await settle(tester);
      expect(find.text('Git Bash Is Not the SSH Shell'), findsOneWidget);
      final before = manager.disconnects;

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      expect(find.text('Git Bash Is Not the SSH Shell'), findsNothing);
      // The route itself, not just its text: a sheet left open with nothing
      // in it would still block the app behind its barrier.
      expect(find.byType(WindowsShellPromptSheet), findsNothing);
      expect(container.read(connectionProvider).windowsShellPrompt, isNull);
      expect(manager.disconnects, before + 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('Reconnect after the shell is fixed closes the prompt and '
        'connects', (tester) async {
      final (container, _, host) = await pumpShell(tester);
      unawaited(
        container
            .read(connectionProvider.notifier)
            .connect(profile: profile, repoPath: '/c/repo'),
      );
      await settle(tester);
      expect(find.text('Git Bash Is Not the SSH Shell'), findsOneWidget);

      host.defaultShell = _bash; // fixed by hand on the host
      await tester.tap(find.text('Reconnect'));
      await settle(tester);

      expect(find.text('Git Bash Is Not the SSH Shell'), findsNothing);
      // The route itself, not just its text: a sheet left open with nothing
      // in it would still block the app behind its barrier.
      expect(find.byType(WindowsShellPromptSheet), findsNothing);
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connected,
      );
      // A connected session runs timers; end it the way the app would.
      await container.read(connectionProvider.notifier).disconnect();
      await settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
