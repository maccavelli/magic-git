// MADR 0045 phase 5. `repoWatchProvider` is a facade over
// `watcherProvider(WatchTarget)`, which owns the engine.
//
// The first test is the one the plan put first: MADR 0045 section 1 claimed,
// from reading Riverpod's scheduler rather than from a run, that a facade
// rebuilt with an unchanged target re-attaches to the running watcher before
// its dispose runs, so the watcher is kept.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/ignore_oracle.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';

const _repo = '/repo';

/// Where a scoped repository's git dir lives — outside its work tree, as a
/// dotfiles repository's does.
const _scopedGitDir = '/elsewhere/repo.git';

/// Records every watcher it opens, by the command that opened it.
class _ArmRecorder extends SSHCommandExecutor {
  _ArmRecorder() : super(SSHClientManager());

  final handles = <FakeWatcherHandle>[];
  final arms = <String>[];

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
  }) async => gitArgs.contains('ls-files')
      ? const SSHCommandResult(exitCode: 0, stdout: 'a.txt\x00', stderr: '')
      : const SSHCommandResult(
          exitCode: 0,
          stdout: 'inotifywait\n',
          stderr: '',
        );

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    arms.add(gitArgs.join(' '));
    final handle = FakeWatcherHandle.armed();
    handles.add(handle);
    return handle;
  }
}

/// An SSH connection whose scoped git dirs a test can change.
class _Conn extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState();

  void scope(String gitDir) =>
      state = state.copyWith(scopedGitDirs: {_repo: gitDir});
}

/// A watch service whose events the test writes.
class _ScriptedService extends RemoteWatchService {
  _ScriptedService()
    : super(
        SSHCommandExecutor(SSHClientManager()),
        gitDirOf: conventionalGitDir,
      );

  // Closed in the test that creates it.
  // ignore: close_sinks
  final events = StreamController<RepoWatchEvent>();

  @override
  Stream<RepoWatchEvent> watch(
    String repoPath, {
    BoundedWatchSpecSource? bounded,
    Duration trailing = WatchTimings.defaultTrailing,
    Duration maxWait = WatchTimings.defaultMaxWait,
    Duration minInterval = WatchTimings.defaultMinInterval,
    Duration pollInterval = WatchTimings.defaultPollInterval,
    Duration recoveryInterval = WatchTimings.defaultRecoveryInterval,
    String sessionId = '',
  }) => events.stream;
}

/// An oracle that sees everything outside `build/`.
class _BuildIgnored implements GitIgnoreOracle {
  @override
  void forgetRepo(String repoPath) {}

  @override
  void clear() {}

  @override
  Future<Set<String>> visible(String repoPath, Set<String> paths) async => {
    for (final path in paths)
      if (!path.startsWith('build/')) path,
  };
}

void main() {
  late _ArmRecorder exec;
  late ProviderContainer container;

  setUp(() {
    exec = _ArmRecorder();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionProvider.overrideWith(_Conn.new),
        // What a bounded arm lists its tracked files through.
        executorProvider.overrideWithValue(exec),
        remoteWatchServiceProvider.overrideWithValue(
          RemoteWatchService(
            exec,
            hostKey: () => 'host',
            streamBudget: () => 8,
            admission: WatchAdmission(budget: HostWatcherBudget()),
            gitDirOf: conventionalGitDir,
          ),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    watchDiagnostics.clear();
  });

  test("invalidating the facade keeps an unchanged target's watcher", () {
    fakeAsync((async) {
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();
      expect(exec.arms, hasLength(1));

      // What a reconnect does to every repository's facade. `pump` waits on
      // the scheduler's zero-duration timer, which fake time runs by elapsing.
      container.invalidate(repoWatchProvider);
      async.elapse(Duration.zero);
      async.letArmsSettle();

      expect(
        exec.arms,
        hasLength(1),
        reason:
            'the rebuilt facade listens to the same target again before the '
            "watcher's dispose runs, so nothing re-arms (MADR 0045 section 1)",
      );
      expect(exec.handles.single.cancelled, isFalse, reason: 'nor tears down');
      expect(
        watchDiagnostics.forRepo(_repo).records.map((r) => r.kind),
        isNot(contains(WatchTransition.stopped)),
        reason: 'and the engine recorded no stop',
      );
      sub.close();
    });
  });

  test('a changed scoped git dir replaces the watcher', () {
    fakeAsync((async) {
      final sub = container.listen(repoWatchProvider(_repo), (_, _) {});
      async.letArmsSettle();
      expect(exec.arms.single, isNot(contains(_scopedGitDir)));

      (container.read(connectionProvider.notifier) as _Conn).scope(
        _scopedGitDir,
      );
      async.elapse(Duration.zero);
      async.letArmsSettle();

      expect(
        exec.handles.first.cancelled,
        isTrue,
        reason:
            'a different surface is a different watcher, and the old one goes',
      );
      expect(exec.arms, hasLength(2));
      expect(
        exec.arms.last,
        contains(_scopedGitDir),
        reason: 'the new watcher arms on the bounded surface',
      );
      sub.close();
    });
  });

  test("the facade's events are the watcher's events, filtered", () {
    fakeAsync((async) {
      final service = _ScriptedService();
      final scripted = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          connectionProvider.overrideWith(_Conn.new),
          remoteWatchServiceProvider.overrideWithValue(service),
          ignoreOracleProvider.overrideWithValue(_BuildIgnored()),
        ],
      );

      final fromFacade = <RepoWatchEvent>[];
      final fromWatcher = <RepoWatchEvent>[];
      final facade = scripted.listen(repoWatchProvider(_repo), (_, next) {
        final event = next.value;
        if (event != null) fromFacade.add(event);
      });
      final watcher = scripted.listen(
        watcherProvider(scripted.read(watchTargetProvider(_repo))),
        (_, next) {
          final event = next.value;
          if (event != null) fromWatcher.add(event);
        },
      );

      service.events.add(
        RepoWatchEvent(
          at: DateTime(2026, 9, 11),
          mode: WatchMode.eventDriven,
          paths: const {'lib/main.dart', 'build/app.o'},
        ),
      );
      async.flushMicrotasks();

      expect(fromWatcher.single.paths, {'lib/main.dart', 'build/app.o'});
      expect(
        fromFacade.single.paths,
        {'lib/main.dart'},
        reason:
            'the facade forwards what the watcher saw, less what git ignores',
      );
      facade.close();
      watcher.close();
      scripted.dispose();
      service.events.close();
      async.flushMicrotasks();
    });
  });

  test('an override of repoWatchProvider still replaces the whole chain', () {
    fakeAsync((async) {
      final tick = RepoWatchEvent(
        at: DateTime(2026, 9, 11),
        mode: WatchMode.polling,
        paths: const {},
      );
      final overridden = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          connectionProvider.overrideWith(_Conn.new),
          remoteWatchServiceProvider.overrideWithValue(
            RemoteWatchService(exec, gitDirOf: conventionalGitDir),
          ),
          // As a pop-out window overrides it.
          repoWatchProvider.overrideWith((ref, repoPath) => Stream.value(tick)),
        ],
      );

      final seen = <RepoWatchEvent>[];
      final sub = overridden.listen(repoWatchProvider(_repo), (_, next) {
        final event = next.value;
        if (event != null) seen.add(event);
      });
      async.letArmsSettle();

      expect(seen.single, same(tick));
      expect(
        exec.arms,
        isEmpty,
        reason:
            'a pop-out has no transport of its own: overriding the facade must '
            'leave no target, no engine and no watcher behind it',
      );
      sub.close();
      overridden.dispose();
    });
  });
}
