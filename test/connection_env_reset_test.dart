// Regression test: switching connections at runtime must reset the previous
// host's resolved environment (PATH / binary paths) and re-probe the new host,
// so a macOS-laptop → Linux-bastion switch never imposes /opt/homebrew paths on
// the bastion.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

class _OkManager extends SSHClientManager {
  @override
  Future<void> connect(
    SSHConnectionProfile profile, {
    FutureOr<bool> Function(String type, Uint8List fingerprint)?
    onVerifyHostKey,
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
  }) async {
    if (gitArgs.contains('rev-parse')) {
      events.add('validate');
      return const SSHCommandResult(exitCode: 0, stdout: 'true\n', stderr: '');
    }
    if (gitArgs.isNotEmpty && gitArgs.first == 'sh') {
      events.add('probe');
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

void main() {
  const macProfile = SSHConnectionProfile(host: 'mac', username: 'u');
  const linuxProfile = SSHConnectionProfile(host: 'bastion', username: 'u');

  test('connect resets env before probing, and a switch re-probes the new host', () async {
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

    expect(container.read(connectionProvider).phase, ConnectionPhase.connected);
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
      reason: 'the new connection must clear the old env before anything runs',
    );
    expect(spy.lastConfiguredPath, '/usr/bin:/bin');
    expect(spy.lastConfiguredPath, isNot(contains('/opt/homebrew')));
    expect(container.read(binaryEnvironmentProvider).os, 'linux');
  });

  test(
    "a superseded connect's still-running env probe cannot reconfigure the "
    'shared executor with the old host\'s PATH',
    () async {
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
    },
  );
}
