// autoFetchProvider must not arm its periodic timer for a repo with no
// remote at all (common for a local-only repo never pushed anywhere) — doing
// so would just fail every tick and spam the output log with an expected,
// not-actually-broken error.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

const _repo = '/repo';

class _NoopExecutor extends SSHCommandExecutor {
  _NoopExecutor() : super(SSHClientManager());
}

/// `connectLocal()`'s environment probe reads `localExecutorProvider`
/// directly (bypassing `gitServiceProvider`'s override below) — without this,
/// it would spawn a real `sh -c` subprocess, which `fakeAsync` cannot drive
/// (a real OS process's completion isn't simulated fake time).
class _FakeLocalExecutor extends LocalCommandExecutor {
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
  }) async => const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
}

class _FetchCountingGit extends GitService {
  _FetchCountingGit() : super(_NoopExecutor());
  int fetchCalls = 0;

  @override
  Future<void> validateRepoPath(String repoPath) async {}

  @override
  Future<RepoLayout?> validateLocalRepoRoot(String repoPath) async => null;

  @override
  Future<SSHCommandResult> fetch(
    String repoPath, {
    bool background = false,
    FetchScope scope = FetchScope.allRemotes,
    CommandOutputCallback? onOutput,
    OperationId? operationId,
  }) async {
    fetchCalls++;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// Fixed settings with a positive auto-fetch interval, bypassing the real
/// async SharedPreferences load entirely.
class _FixedSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(autoFetchMinutes: 5);
}

void main() {
  Future<ProviderContainer> connectedContainer(
    _FetchCountingGit git,
    List<GitRef> refs,
  ) async {
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        localExecutorProvider.overrideWithValue(_FakeLocalExecutor()),
        appSettingsProvider.overrideWith(_FixedSettings.new),
        refsProvider(_repo).overrideWith((ref) async => refs),
        // The auto-fetch gate reads CONFIGURED remotes now, not
        // remote-tracking refs — derived here so each case's intent
        // (remote present / absent) carries over unchanged.
        remotesProvider(_repo).overrideWith(
          (ref) async =>
              refs.any((r) => r.isRemote) ? const ['origin'] : const <String>[],
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(connectionProvider.notifier).connectLocal(_repo);
    return container;
  }

  test('does not arm the timer for a repo with no configured remote', () {
    fakeAsync((async) {
      final git = _FetchCountingGit();
      late ProviderContainer container;
      connectedContainer(git, const []).then((c) => container = c);
      async.flushMicrotasks();

      container.listen(autoFetchProvider, (_, _) {});
      async.elapse(const Duration(minutes: 30));

      expect(git.fetchCalls, 0);
    });
  });

  test('arms the timer once a configured remote is present', () {
    fakeAsync((async) {
      final git = _FetchCountingGit();
      late ProviderContainer container;
      connectedContainer(git, const [
        GitRef(
          name: 'refs/remotes/origin/main',
          oid: 'deadbeef',
          isHead: false,
          subject: 'Initial commit',
        ),
      ]).then((c) => container = c);
      async.flushMicrotasks();

      container.listen(autoFetchProvider, (_, _) {});
      async.elapse(const Duration(minutes: 5));

      expect(git.fetchCalls, 1);
    });
  });
}
