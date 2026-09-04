// The forge-facing providers must carry a scoped (bare/dotfiles) repo's
// GIT_DIR/GIT_WORK_TREE overlay, not just glab/ghServiceProvider.
//
// ScopedCommandExecutor and scopedForgeExecutorProvider existed, and the two
// service providers used them — but originRemoteUrlProvider, forgeProvider and
// sessionAuthStatusProvider each built on the RAW activeExecutorProvider. Every
// one of them shells `git remote get-url origin`, which on a repo whose git-dir
// lives outside its work tree resolves nothing at all: the Forge tab reported
// Forge.none, browser links came back null, and an Enterprise host could not be
// resolved — on a repo with a perfectly good forge remote (0022 H2).
//
// These tests assert the env actually reaches the command, which is what the
// unit test for ScopedCommandExecutor alone could never catch.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/app_scope.dart';

const _repo = '/home/user';
const _gitDir = '/home/user/.home.git';

/// Records every command's repoPath/argv/extraEnv and answers plausibly.
class _RecordingExecutor implements CommandExecutor {
  final List<(String, List<String>, Map<String, String>?)> calls = [];

  /// stdout for the next `git remote get-url origin`.
  String originUrl = 'git@github.com:mac/dotfiles.git\n';

  Map<String, String>? envFor(String argvContains) {
    for (final (_, argv, env) in calls) {
      if (argv.join(' ').contains(argvContains)) return env;
    }
    return null;
  }

  bool sawCommand(String argvContains) =>
      calls.any((c) => c.$2.join(' ').contains(argvContains));

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
    calls.add((repoPath, gitArgs, extraEnv));
    if (gitArgs.join(' ').contains('remote get-url')) {
      return SSHCommandResult(exitCode: 0, stdout: originUrl, stderr: '');
    }
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> uploadBytes(
    String remotePath,
    Uint8List bytes, {
    String? routingRepo,
  }) async {}

  @override
  void configureEnvironment({
    String? path,
    Map<String, String> binaries = const {},
  }) {}

  @override
  String? resolvedBinaryPath(String name) => null;

  @override
  void setForgeTokenNeutralization(Iterable<String> vars) {}

  @override
  void resetEnvironment() {}
}

/// Pins a connected state carrying a scoped repo.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

ConnectionState _scopedState() => const ConnectionState(
  phase: ConnectionPhase.connected,
  repoPath: _repo,
  repoPaths: [_repo],
  connectionId: 'c1',
  connectionLabel: 'Bastion',
  host: 'h',
  scopedGitDirs: {_repo: _gitDir},
);

ConnectionState _plainState() => const ConnectionState(
  phase: ConnectionPhase.connected,
  repoPath: _repo,
  repoPaths: [_repo],
  connectionId: 'c1',
  connectionLabel: 'Bastion',
  host: 'h',
);

void main() {
  late _RecordingExecutor executor;

  ProviderContainer build(ConnectionState state) {
    executor = _RecordingExecutor();
    final c = appProviderContainer(
      overrides: [
        connectionProvider.overrideWith(() => _StubConnection(state)),
        activeExecutorProvider.overrideWithValue(executor),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('originRemoteUrlProvider scopes get-url on a scoped repo', () async {
    final c = build(_scopedState());
    await c.read(originRemoteUrlProvider(_repo).future);

    expect(executor.sawCommand('remote get-url'), isTrue);
    expect(executor.envFor('remote get-url'), {
      'GIT_DIR': _gitDir,
      'GIT_WORK_TREE': _repo,
    });
  });

  test('originRemoteUrlProvider leaves an ordinary repo unscoped', () async {
    // The overlay must be a true no-op for a normal repo — a stray GIT_DIR
    // would break every command it touched.
    final c = build(_plainState());
    await c.read(originRemoteUrlProvider(_repo).future);

    expect(executor.sawCommand('remote get-url'), isTrue);
    expect(executor.envFor('remote get-url'), isNull);
  });

  test(
    'forgeProvider scopes the remote probe that classifies the forge',
    () async {
      final c = build(_scopedState());
      final forge = await c.read(forgeProvider(_repo).future);

      expect(executor.envFor('remote get-url'), {
        'GIT_DIR': _gitDir,
        'GIT_WORK_TREE': _repo,
      });
      // With the remote resolvable, the repo classifies instead of falling to
      // Forge.none — the user-visible half of the bug.
      expect(forge, isNot(Forge.none));
    },
  );

  test('switching to an unscoped repo clears a stale scope entry', () async {
    // 0022 M7. The live registry only ever grew within a session, so an
    // ordinary repo opened at a path a scoped repo had vacated inherited its
    // GIT_DIR — and, because isRepoScoped also gates `-uall`, silently changed
    // which untracked files that repo reported.
    const other = '/srv/plain';
    final c = build(_scopedState());
    final git = c.read(gitServiceProvider);
    // Simulate connect having registered every scope the connection carries.
    git.registerRepoScope(_repo, gitDir: _gitDir, workTree: _repo);
    git.registerRepoScope(other, gitDir: _gitDir, workTree: other);
    expect(git.isRepoScoped(other), isTrue);

    // `other` is NOT in the connection's scopedGitDirs, so switching to it must
    // leave it unscoped.
    c.read(connectionProvider.notifier).setRepoPath(other);

    expect(git.isRepoScoped(other), isFalse);
    expect(
      git.isRepoScoped(_repo),
      isTrue,
      reason: 'the genuinely scoped repo must keep its entry',
    );
  });

  test('sessionAuthStatusProvider scopes its probe commands', () async {
    final c = build(_scopedState());
    await c.read(sessionAuthStatusProvider.future);

    // Whatever the probe ran first, it must have carried the overlay: the
    // provider passes the repo path as cwd, which is the scope registry's key.
    expect(executor.calls, isNotEmpty);
    final scopedCalls = executor.calls.where(
      (c) => c.$1 == _repo && c.$3 != null,
    );
    expect(
      scopedCalls,
      isNotEmpty,
      reason: 'at least one repo-cwd probe must carry GIT_DIR',
    );
    for (final (_, _, env) in scopedCalls) {
      expect(env!['GIT_DIR'], _gitDir);
    }
  });
}
