// Regression test: switching connections at runtime must reset the previous
// host's resolved environment (PATH / binary paths) and re-probe the new host,
// so a macOS-laptop → Linux-bastion switch never imposes /opt/homebrew paths on
// the bastion.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/ssh/windows_host_probe.dart';

class _OkManager extends SSHClientManager {
  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
    void Function(Duration rtt)? onPingSample,
  }) async {}
  @override
  Future<void>? get done => Completer<void>().future; // never drops
  @override
  Future<void> disconnect() async {}
}

/// Records env lifecycle + which commands ran, and returns per-command canned
/// output (validate → `true`, probe → [probeOut]).
class _SpyExecutor extends SSHCommandExecutor {
  _SpyExecutor() : super(SSHClientManager());
  String probeOut = '';
  final List<String> events = [];
  String? lastConfiguredPath;

  @override
  void resetEnvironment() {
    events.add('reset');
    super.resetEnvironment();
  }

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    events.add('configure');
    lastConfiguredPath = path;
    super.configureEnvironment(path: path, binaries: binaries);
  }

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
      events.add('validate');
      return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
    }
    if (gitArgs.isNotEmpty && gitArgs.first == 'sh') {
      // Connect-time OS/PATH probe (uname) vs later --version pass.
      if (gitArgs.join(' ').contains('uname')) {
        events.add('probe');
      }
      return SSHCommandResult(exitCode: 0, stdout: probeOut, stderr: '');
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// Like [_SpyExecutor] but can gate the *first* environment probe mid-flight,
/// so a test can land a newer connect (which resets + reconfigures the shared
/// executor) while an older connect's probe is still running, then release it
/// and confirm the superseded probe does not reconfigure anything.
class _GatedProbeExecutor extends SSHCommandExecutor {
  _GatedProbeExecutor() : super(SSHClientManager());
  String probeOut = '';
  String? lastConfiguredPath;
  int configures = 0;
  Completer<void>? probeGate; // if set, the first probe awaits it
  Completer<void>? firstProbeStarted;
  bool _gatedOnce = false;

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {
    configures++;
    lastConfiguredPath = path;
    super.configureEnvironment(path: path, binaries: binaries);
  }

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
    if (gitArgs.isNotEmpty && gitArgs.first == 'sh') {
      final out = probeOut; // snapshot this host's output before any await
      if (probeGate != null && !_gatedOnce) {
        _gatedOnce = true;
        firstProbeStarted?.complete();
        await probeGate!.future;
      }
      return SSHCommandResult(exitCode: 0, stdout: out, stderr: '');
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// [_OkManager] that counts disconnects: the Windows prompt keeps the
/// transport for Enable, and dismissing it must release it.
class _CountingManager extends _OkManager {
  int disconnects = 0;
  @override
  Future<void> disconnect() async => disconnects++;
}

/// Decodes an `-EncodedCommand` line's Base64 UTF-16LE payload.
String _decodedScript(String commandLine) {
  final bytes = base64.decode(commandLine.split(' ').last);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
}

/// A Windows host (MADR 0070): answers the raw PowerShell probe with
/// [facts] and Enable with [enableExit]; a successful Enable makes Git Bash the
/// shell, so the next probe reports it. POSIX commands answer as Git Bash would
/// — or, when [posixRejected], as cmd.exe does.
class _WindowsHostExecutor extends SSHCommandExecutor {
  _WindowsHostExecutor({required this.banner, required this.facts})
    : super(SSHClientManager());

  String? banner;
  String facts;
  int enableExit = 0;
  String enableStderr = '';
  bool posixRejected = false;
  final List<String> events = [];
  final List<String> rawScripts = [];

  static const cmdExeError =
      "'sh' is not recognized as an internal or external command,\r\n"
      'operable program or batch file.\r\n';

  @override
  String? get remoteVersion => banner;

  @override
  Future<SSHCommandResult> executeRaw(
    String command, {
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    ExecLane lane = ExecLane.isolated,
  }) async {
    expect(command, startsWith('powershell.exe '));
    final script = _decodedScript(command);
    rawScripts.add(script);
    if (script.contains('New-ItemProperty')) {
      events.add('enable');
      if (enableExit == 0) {
        facts = facts.replaceFirst(
          RegExp('MGW_DEFAULT_SHELL=.*'),
          r'MGW_DEFAULT_SHELL=C:\Program Files\Git\bin\bash.exe',
        );
      }
      return SSHCommandResult(
        exitCode: enableExit,
        stdout: '',
        stderr: enableStderr,
      );
    }
    events.add('windows-probe');
    posixRejected = !facts.contains(r'MGW_DEFAULT_SHELL=C:\Program Files\Git');
    return SSHCommandResult(exitCode: 0, stdout: facts, stderr: '');
  }

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
    if (posixRejected) {
      events.add('rejected');
      return const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: cmdExeError,
      );
    }
    if (gitArgs.contains('rev-parse')) {
      events.add('validate');
      return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
    }
    if (gitArgs.isNotEmpty &&
        gitArgs.first == 'sh' &&
        gitArgs.join(' ').contains('uname')) {
      events.add('probe');
      return const SSHCommandResult(
        exitCode: 0,
        stdout: 'OS=MINGW64_NT-10.0-26100\nPATH=/usr/bin\n',
        stderr: '',
      );
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

const _windowsBanner = 'SSH-2.0-OpenSSH_for_Windows_9.5';
const _factsCmdWithBash =
    'MGW_PS=5.1.26100.2161\n'
    'MGW_DEFAULT_SHELL=\n'
    r'MGW_GIT_ROOT=C:\Program Files\Git'
    '\n'
    r'MGW_BASH=C:\Program Files\Git\bin\bash.exe'
    '\n'
    r'MGW_GIT=C:\Program Files\Git\cmd\git.exe'
    '\n'
    'MGW_ADMIN=1\n';
const _factsCmdNoBash =
    'MGW_PS=5.1.26100.2161\nMGW_DEFAULT_SHELL=\nMGW_GIT_ROOT=\nMGW_BASH=\n'
    'MGW_GIT=\nMGW_ADMIN=0\n';
const _factsBashActive =
    'MGW_PS=5.1.26100.2161\n'
    r'MGW_DEFAULT_SHELL=C:\Program Files\Git\bin\bash.exe'
    '\n'
    r'MGW_BASH=C:\Program Files\Git\bin\bash.exe'
    '\n'
    'MGW_ADMIN=1\n';

({ProviderContainer container, _CountingManager manager}) _windowsContainer(
  _WindowsHostExecutor exec,
) {
  final manager = _CountingManager();
  final container = ProviderContainer(
    overrides: [
      sshClientManagerProvider.overrideWithValue(manager),
      executorProvider.overrideWithValue(exec),
      gitServiceProvider.overrideWithValue(GitService(exec)),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, manager: manager);
}

void main() {
  const macProfile = SSHConnectionProfile(host: 'mac', username: 'u');
  const linuxProfile = SSHConnectionProfile(host: 'bastion', username: 'u');

  test(
    'connect resets env before probing, and a switch re-probes the new host',
    () async {
      final spy = _SpyExecutor();
      final container = ProviderContainer(
        overrides: [
          sshClientManagerProvider.overrideWithValue(_OkManager()),
          executorProvider.overrideWithValue(spy),
          gitServiceProvider.overrideWithValue(GitService(spy)),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionProvider.notifier);

      // Connection A: a macOS host with Homebrew paths.
      spy.probeOut =
          'OS=Darwin\nPATH=/opt/homebrew/bin:/usr/bin\n'
          'BIN=git=/opt/homebrew/bin/git\n';
      await controller.connect(profile: macProfile, repoPath: '/repo');

      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connected,
      );
      // Order matters: reset the old env, probe + configure the new host, THEN
      // validate — so validateRepoPath's `git` runs against the augmented PATH
      // (a Homebrew-only or missing git surfaces honestly, not as a misleading
      // "not a git repository").
      expect(
        spy.events.indexOf('reset') < spy.events.indexOf('probe'),
        isTrue,
        reason: 'reset must precede the environment probe',
      );
      expect(
        spy.events.indexOf('probe') < spy.events.indexOf('validate'),
        isTrue,
        reason: 'the environment must be resolved before validateRepoPath',
      );
      expect(
        spy.events.indexOf('configure') < spy.events.indexOf('validate'),
        isTrue,
        reason: 'the executor must be configured before the first git command',
      );
      expect(spy.lastConfiguredPath, contains('/opt/homebrew/bin'));

      // Switch to connection B: a Linux bastion — must reset A's env first.
      spy.events.clear();
      spy.probeOut = 'OS=Linux\nPATH=/usr/bin:/bin\nBIN=git=/usr/bin/git\n';
      await controller.connect(profile: linuxProfile, repoPath: '/repo');

      expect(
        spy.events.first,
        'reset',
        reason:
            'the new connection must clear the old env before anything runs',
      );
      expect(spy.lastConfiguredPath, '/usr/bin:/bin');
      expect(spy.lastConfiguredPath, isNot(contains('/opt/homebrew')));
      expect(container.read(binaryEnvironmentProvider).os, 'linux');
    },
  );

  test("a superseded connect's still-running env probe cannot reconfigure the "
      'shared executor with the old host\'s PATH', () async {
    final spy = _GatedProbeExecutor();
    final container = ProviderContainer(
      overrides: [
        sshClientManagerProvider.overrideWithValue(_OkManager()),
        executorProvider.overrideWithValue(spy),
        gitServiceProvider.overrideWithValue(GitService(spy)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionProvider.notifier);

    // Connection A (mac): its probe is gated mid-flight, so this connect
    // stays parked inside _resolveEnvironment.
    spy.probeOut =
        'OS=Darwin\nPATH=/opt/homebrew/bin\nBIN=git=/opt/homebrew/bin/git\n';
    spy.probeGate = Completer<void>();
    spy.firstProbeStarted = Completer<void>();
    final aFuture = controller.connect(profile: macProfile, repoPath: '/repo');
    await spy.firstProbeStarted!.future; // A is stuck in its probe

    // Connection B (linux) supersedes A and completes fully, configuring the
    // executor with the bastion's PATH.
    spy.probeOut = 'OS=Linux\nPATH=/usr/bin:/bin\nBIN=git=/usr/bin/git\n';
    await controller.connect(profile: linuxProfile, repoPath: '/repo');
    expect(spy.lastConfiguredPath, '/usr/bin:/bin');
    final configuresAfterB = spy.configures;

    // Release A's gated probe: it resolves late but, being superseded, must
    // NOT reconfigure the shared executor back to the mac PATH.
    spy.probeGate!.complete();
    await aFuture;
    expect(
      spy.lastConfiguredPath,
      '/usr/bin:/bin',
      reason: 'the stale probe must not win over the current connection',
    );
    expect(
      spy.configures,
      configuresAfterB,
      reason: 'a superseded probe must skip configureEnvironment entirely',
    );
  });

  test(
    'same-host auto-reconnect reuses the env cache; disconnect invalidates',
    () async {
      final spy = _SpyExecutor();
      final container = ProviderContainer(
        overrides: [
          sshClientManagerProvider.overrideWithValue(_OkManager()),
          executorProvider.overrideWithValue(spy),
          gitServiceProvider.overrideWithValue(GitService(spy)),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionProvider.notifier);

      spy.probeOut =
          'OS=Darwin\nPATH=/opt/homebrew/bin:/usr/bin\n'
          'BIN=git=/opt/homebrew/bin/git\n';
      await controller.connect(profile: macProfile, repoPath: '/repo');
      expect(spy.events.where((e) => e == 'probe').length, 1);

      spy.events.clear();
      await controller.connect(
        profile: macProfile,
        repoPath: '/repo',
        reconnecting: true,
      );
      expect(
        spy.events.where((e) => e == 'probe'),
        isEmpty,
        reason: 'same-host reconnect must reuse the cached environment',
      );
      expect(spy.events, contains('configure'));

      spy.events.clear();
      await controller.disconnect();
      await controller.connect(profile: macProfile, repoPath: '/repo');
      expect(
        spy.events.where((e) => e == 'probe').length,
        1,
        reason: 'disconnect must invalidate the cache',
      );

      spy.events.clear();
      await controller.connect(
        profile: const SSHConnectionProfile(host: 'mac', username: 'other'),
        repoPath: '/repo',
      );
      expect(
        spy.events.where((e) => e == 'probe').length,
        1,
        reason: 'a different username must not hit the cache',
      );

      // Sibling of the username case: the cache key is host|port|username,
      // so a non-default port on the same host is a different environment
      // (a container's sshd is not the host's sshd).
      spy.events.clear();
      await controller.connect(
        profile: const SSHConnectionProfile(
          host: 'mac',
          username: 'u',
          port: 2222,
        ),
        repoPath: '/repo',
      );
      expect(
        spy.events.where((e) => e == 'probe').length,
        1,
        reason: 'a different port must not hit the cache',
      );
    },
  );

  group('the Windows shell check (MADR 0070)', () {
    const winProfile = SSHConnectionProfile(host: 'winbox', username: 'u');

    test('Git Bash installed but not the shell stops with the prompt, and '
        'never reports "not a git repository"', () async {
      final exec = _WindowsHostExecutor(
        banner: _windowsBanner,
        facts: _factsCmdWithBash,
      );
      final (:container, :manager) = _windowsContainer(exec);
      await container
          .read(connectionProvider.notifier)
          .connect(profile: winProfile, repoPath: r'C:\repo');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.error);
      expect(state.windowsShellPrompt?.kind, WindowsShellPromptKind.notActive);
      expect(state.error, contains('cmd.exe'));
      expect(state.error, isNot(contains('not a git repository')));
      expect(
        state.windowsShellPrompt!.enableCommand,
        enableGitBashCommand(r'C:\Program Files\Git\bin\bash.exe'),
      );
      expect(exec.events, ['windows-probe'], reason: 'no POSIX command ran');
      expect(manager.disconnects, 0, reason: 'Enable needs the transport');
    });

    test('no Git Bash stops with the not-installed prompt', () async {
      final exec = _WindowsHostExecutor(
        banner: _windowsBanner,
        facts: _factsCmdNoBash,
      );
      final (:container, manager: _) = _windowsContainer(exec);
      await container
          .read(connectionProvider.notifier)
          .connect(profile: winProfile, repoPath: r'C:\repo');

      final prompt = container.read(connectionProvider).windowsShellPrompt;
      expect(prompt?.kind, WindowsShellPromptKind.notInstalled);
      expect(prompt!.enableCommand, isNull);
    });

    test('Git Bash already the shell connects on the POSIX layer', () async {
      final exec = _WindowsHostExecutor(
        banner: _windowsBanner,
        facts: _factsBashActive,
      );
      final (:container, manager: _) = _windowsContainer(exec);
      await container
          .read(connectionProvider.notifier)
          .connect(profile: winProfile, repoPath: '/c/repo');

      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.windowsShellPrompt, isNull);
      // In order; later reads (the background finish) may follow.
      expect(
        exec.events,
        containsAllInOrder(['windows-probe', 'probe', 'validate']),
      );
      expect(exec.events.first, 'windows-probe');
      expect(container.read(binaryEnvironmentProvider).os, 'windows');
    });

    test('a POSIX host is never sent the Windows probe', () async {
      final exec = _WindowsHostExecutor(
        banner: 'SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13',
        facts: _factsBashActive,
      );
      final (:container, manager: _) = _windowsContainer(exec);
      await container
          .read(connectionProvider.notifier)
          .connect(profile: winProfile, repoPath: '/repo');

      expect(exec.rawScripts, isEmpty);
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.connected,
      );
    });

    test('Enable sets the shell and connects again', () async {
      final exec = _WindowsHostExecutor(
        banner: _windowsBanner,
        facts: _factsCmdWithBash,
      );
      final (:container, manager: _) = _windowsContainer(exec);
      final controller = container.read(connectionProvider.notifier);
      await controller.connect(profile: winProfile, repoPath: '/c/repo');
      expect(container.read(connectionProvider).windowsShellPrompt, isNotNull);

      await controller.enableGitBashShell();

      expect(
        exec.rawScripts[1],
        contains(enableGitBashCommand(r'C:\Program Files\Git\bin\bash.exe')),
      );
      final state = container.read(connectionProvider);
      expect(state.phase, ConnectionPhase.connected);
      expect(state.windowsShellPrompt, isNull);
      // In order; later reads (the background finish) may follow.
      expect(
        exec.events,
        containsAllInOrder([
          'windows-probe',
          'enable',
          'windows-probe',
          'probe',
          'validate',
        ]),
      );
      expect(exec.events.take(3), ['windows-probe', 'enable', 'windows-probe']);
    });

    test('Enable denied keeps the prompt with the host\'s words', () async {
      final exec =
          _WindowsHostExecutor(banner: _windowsBanner, facts: _factsCmdWithBash)
            ..enableExit = 1
            ..enableStderr = 'Requested registry access is not allowed.\r\n';
      final (:container, manager: _) = _windowsContainer(exec);
      final controller = container.read(connectionProvider.notifier);
      await controller.connect(profile: winProfile, repoPath: '/c/repo');

      await controller.enableGitBashShell();

      final prompt = container.read(connectionProvider).windowsShellPrompt;
      expect(prompt?.kind, WindowsShellPromptKind.notActive);
      expect(prompt!.enableError, 'Requested registry access is not allowed.');
      expect(prompt.enabling, isFalse);
      expect(exec.events, ['windows-probe', 'enable']);
    });

    test("cmd.exe's rejection finds a Windows host its banner hid", () async {
      final exec = _WindowsHostExecutor(
        banner: 'SSH-2.0-CustomBanner',
        facts: _factsCmdWithBash,
      )..posixRejected = true;
      final (:container, manager: _) = _windowsContainer(exec);
      await container
          .read(connectionProvider.notifier)
          .connect(profile: winProfile, repoPath: r'C:\repo');

      final state = container.read(connectionProvider);
      expect(state.windowsShellPrompt?.kind, WindowsShellPromptKind.notActive);
      expect(state.error, isNot(contains('not a git repository')));
      expect(exec.events, ['rejected', 'windows-probe']);
    });

    test('dismissing the prompt releases the transport', () async {
      final exec = _WindowsHostExecutor(
        banner: _windowsBanner,
        facts: _factsCmdWithBash,
      );
      final (:container, :manager) = _windowsContainer(exec);
      final controller = container.read(connectionProvider.notifier);
      await controller.connect(profile: winProfile, repoPath: r'C:\repo');

      await controller.dismissWindowsShellPrompt();

      expect(container.read(connectionProvider).windowsShellPrompt, isNull);
      expect(manager.disconnects, 1);
    });
  });
}
