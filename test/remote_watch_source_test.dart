// MADR 0045 F10 and phase 3. What the remote source locks, and when it refuses
// to open a watcher at all.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/remote_watch_source.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/watch_lease.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/watcher_tool_probe.dart';
import 'package:remote_magic_git/core/git/watch/source/watch_source.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_watcher_handle.dart';

/// A host with inotifywait, recording every command and every stream opened.
class _Host extends SSHCommandExecutor {
  _Host({this.refuseTouch = false}) : super(SSHClientManager());

  final bool refuseTouch;
  final commands = <String>[];
  final streams = <String>[];

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
    final joined = gitArgs.join(' ');
    commands.add(joined);
    if (joined.contains('command -v')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: 'inotifywait\n',
        stderr: '',
      );
    }
    if (refuseTouch && joined.contains('touch')) {
      return const SSHCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'touch: cannot touch: Not a directory',
      );
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
  }) async {
    streams.add(gitArgs.join(' '));
    return FakeWatcherHandle.armed();
  }
}

void main() {
  late HostWatcherBudget budget;
  late WatchAdmission admission;
  late List<String> resolved;

  setUp(() {
    budget = HostWatcherBudget();
    admission = WatchAdmission(budget: budget);
    resolved = [];
  });

  RemoteWatchSource sourceOn(_Host host) => RemoteWatchSource(
    executor: host,
    probe: WatcherToolProbe(host),
    gitDirOf: (repoPath) async {
      resolved.add(repoPath);
      return '/srv/main/.git/worktrees/feature';
    },
    admission: admission,
    hostKey: () => 'host',
    capacity: () => 6,
    timings: WatchTimings.standard,
    record: (_, _) {},
  );

  ArmRequest request({BoundedWatchSpecSource? bounded}) => ArmRequest(
    repoPath: '/srv/feature',
    bounded: bounded,
    cancelled: Completer<void>().future,
    attempt: 1,
  );

  /// Closes an armed source the way the engine does: listening first.
  Future<void> closeArmed(SourceArm outcome) async {
    final armed = (outcome as SourceArmed).source;
    final subscription = armed.signals.listen((_) {});
    await armed.close();
    await subscription.cancel();
  }

  test('a linked worktree is locked by its resolved git dir', () async {
    final host = _Host();

    final outcome = await sourceOn(host).arm(request());

    expect(outcome, isA<SourceArmed>());
    expect(resolved, ['/srv/feature']);
    expect(
      host.streams.single,
      allOf(
        contains('/srv/main/.git/worktrees/feature/mg-watch.lock'),
        isNot(contains('/srv/feature/.git/')),
      ),
      reason:
          '`/srv/feature/.git` is a file in a linked worktree; a lock under it '
          'failed and read as "held by another" (F10)',
    );
    expect(
      admission.exclusion.isHeld('/srv/main/.git/worktrees/feature'),
      isTrue,
      reason: 'the session\'s exclusion and the host lock name one directory',
    );
    await closeArmed(outcome);
  });

  test("a scoped repository is locked by its spec's git dir", () async {
    final host = _Host();

    final outcome = await sourceOn(host).arm(
      request(
        bounded: () async => computeBoundedWatchSpec(
          gitDir: '/home/u/.home.git',
          workTree: '/home/u',
          trackedFiles: const ['.profile'],
        ),
      ),
    );

    expect(outcome, isA<SourceArmed>());
    expect(
      resolved,
      isEmpty,
      reason: 'the spec already names the git dir; nothing is guessed or asked',
    );
    expect(host.streams.single, contains('/home/u/.home.git/mg-watch.lock'));
    await closeArmed(outcome);
  });

  test(
    'a lease that cannot be stamped fails the arm without opening a stream',
    () async {
      final host = _Host(refuseTouch: true);

      await expectLater(
        sourceOn(host).arm(request()),
        throwsA(isA<WatchLeaseException>()),
      );

      expect(
        host.streams,
        isEmpty,
        reason:
            'a watcher started without its lease exits at once — a stream '
            'opened only to spend a restart',
      );
      expect(budget.liveFor('host'), 0, reason: 'the slot goes back');
      expect(
        admission.exclusion.isHeld('/srv/main/.git/worktrees/feature'),
        isFalse,
        reason: 'and so does the lock',
      );
    },
  );
}
