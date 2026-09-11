// MADR 0044 phase 2. An arm settles on a SIGNAL, not on a clock.
//
// It used to read `handle.exitCode` with a flat 250 ms cap. A live watcher
// never completes `exitCode`, so every arm that SUCCEEDED waited the whole
// quarter-second — 63 % of what a tab switch costs, against a median SSH round
// trip of 49 ms on the reporting host (MADR 0044 F7).
//
// The replacement races two futures: the refusal's exit status, and the
// readiness marker the arming script writes to stderr. What makes it a race
// and not a guess is WHERE the marker sits — both refusals exit before it, so
// a refused arm cannot emit it and a healthy one always does. That ordering is
// pinned against a real shell in watch_lease_teardown_exec_test.dart; what is
// pinned here is that the client acts on it.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_watcher_handle.dart';

/// Arms against one [FakeWatcherHandle] and records every one-shot command, so
/// what the arm did on the host is a fact rather than an inference.
class _ScriptedExecutor extends SSHCommandExecutor {
  _ScriptedExecutor(this.handle) : super(SSHClientManager());

  final FakeWatcherHandle handle;
  final armed = Completer<void>();
  final commands = <String>[];

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
    if (!armed.isCompleted) armed.complete();
    return handle;
  }
}

/// What one arm did: how long it took to commit, and what it reported.
typedef ArmOutcome = ({
  Duration elapsed,
  List<String> diagnostics,
  _ScriptedExecutor executor,
});

void main() {
  late HostWatcherBudget hostBudget;

  setUp(() {
    hostBudget = HostWatcherBudget();
    watchDiagnostics.clear();
  });

  /// Arms [handle], waits for the arm to commit either way, then tears down.
  ///
  /// The subscription is cancelled here rather than handed back, so a test can
  /// never leave a watcher counted against the test's budget.
  Future<ArmOutcome> arm(FakeWatcherHandle handle) async {
    final executor = _ScriptedExecutor(handle);
    final diagnostics = <String>[];
    final service = RemoteWatchService(
      executor,
      hostKey: () => 'host',
      onDiagnostic: diagnostics.add,
      admission: WatchAdmission(budget: hostBudget),
      gitDirOf: conventionalGitDir,
    );
    // The transition log, not the live-watcher count. A slot is reserved
    // BEFORE the stream is opened and given back if the arm fails, so
    // `liveWatchers` reads 1 while the arm is still undecided — the first
    // version of this helper waited on it and every timing assertion passed
    // for the wrong reason, in 0.3 ms.
    final log = watchDiagnostics.forRepo('/repo');
    bool settled() => log.records.any(
      (r) =>
          r.kind == WatchTransition.armed ||
          r.kind == WatchTransition.armFailed,
    );

    final watch = Stopwatch()..start();
    final sub = service.watch('/repo').listen((_) {});
    await executor.armed.future;
    // The stream is open; what is being timed is how long the arm then takes
    // to commit, which is the whole subject.
    while (!settled() && watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    watch.stop();
    final outcome = (
      elapsed: watch.elapsed,
      diagnostics: diagnostics,
      executor: executor,
    );
    await sub.cancel();
    await pumpEventQueue();
    return outcome;
  }

  test('an arm settles on the marker, not on the ceiling', () async {
    final handle = FakeWatcherHandle.armed();
    final outcome = await arm(handle);

    // The bound IS the assertion. 250 ms is the constant this change deletes,
    // so anything at or above it means the race is not racing — the arm fell
    // through to a timer, exactly as it did before.
    expect(
      outcome.elapsed,
      lessThan(const Duration(milliseconds: 250)),
      reason:
          'a healthy arm must not wait out any timeout: exitCode never '
          'completes for a live watcher, so a clock can only ever be a cost',
    );
    expect(
      outcome.diagnostics,
      isEmpty,
      reason: 'the marker is addressed to the client, not to the user',
    );
  });

  test('a silent host falls through to the ceiling and still arms', () async {
    // Neither signal. This is the case the old flat wait handled by accident,
    // and the reason the ceiling is kept: degrade slowly, never wrongly.
    final outcome = await arm(FakeWatcherHandle.silentHost());

    expect(
      outcome.elapsed,
      greaterThanOrEqualTo(RemoteWatchService.armSignalCeiling),
      reason: 'the backstop is a backstop, not a hang',
    );
    expect(
      outcome.diagnostics.any((d) => d.contains('arm unavailable')),
      isFalse,
      reason: 'a host that says nothing is treated as armed, as it was before',
    );
    // But not silently. Before this, a host that never announced was
    // indistinguishable from a healthy one — the arm just took longer, and
    // nothing said so.
    expect(
      outcome.diagnostics.any((d) => d.contains('no readiness signal')),
      isTrue,
      reason: 'the only case the ceiling exists for should be visible',
    );
  });

  test(
    'a lock refusal is still a refusal, and still names its incumbent',
    () async {
      final outcome = await arm(
        FakeWatcherHandle.refused(
          boundedWatchLockedExit,
          stderrLine: 'mg-watch: lock held by zzz',
        ),
      );

      expect(
        outcome.diagnostics.any((d) => d.contains('token zzz')),
        isTrue,
        reason:
            'the incumbent is captured by the listener as the line arrives, not '
            'by draining stderr after the fact — and it must survive the move',
      );
      expect(
        outcome.diagnostics.any(
          (d) => d.contains('another live watcher already holds'),
        ),
        isTrue,
      );
      expect(hostBudget.liveTotal, 0, reason: 'a refused arm holds no slot');
    },
  );

  test('the refusal releases the lease it stamped', () async {
    final outcome = await arm(
      FakeWatcherHandle.refused(
        boundedWatchLockedExit,
        stderrLine: 'mg-watch: lock held by zzz',
      ),
    );

    expect(
      outcome.executor.commands.any(
        (c) => c.contains('rm -f') && c.contains('.hb'),
      ),
      isTrue,
      reason:
          'a refusal happens after the lease stamp and never reaches the '
          'WatchArmed teardown that would give it back (MADR 0043 F6)',
    );
  });

  test('only the marker settles an arm — chatter does not', () async {
    // The ordering the whole design rests on, from the client's side. Any
    // stderr line would have armed on inotifywait's own startup output and
    // silently disabled the exclusion the lock exists for.
    final outcome = await arm(
      FakeWatcherHandle.refused(
        boundedWatchLockedExit,
        stderrLine: 'Setting up watches.',
      ),
    );

    expect(hostBudget.liveTotal, 0);
    expect(
      outcome.diagnostics.any(
        (d) => d.contains('another live watcher already holds'),
      ),
      isTrue,
    );
  });

  test('the arm subscribes to stderr exactly once', () async {
    // The invariant that let `_incumbentToken` and its own 250 ms timeout be
    // deleted. dartssh2's stderr is single-subscription, so a second listener
    // throws on a real host and passes silently against a broadcast double —
    // which is why the double counts rather than the test hoping.
    final handle = FakeWatcherHandle.armed();
    await arm(handle);

    expect(handle.stderrListens, 1);
    expect(handle.stdoutListens, 1);
  });

  test('a refused arm subscribes to stderr exactly once too', () async {
    // The path that used to hold BOTH listeners: the arm's own, and
    // `_incumbentToken`'s `stderr.join()`. They were only ever safe because
    // they were mutually exclusive.
    final handle = FakeWatcherHandle.refused(
      boundedWatchLockedExit,
      stderrLine: 'mg-watch: lock held by zzz',
    );
    await arm(handle);

    expect(handle.stderrListens, 1);
    expect(
      handle.stdoutListens,
      0,
      reason: 'a refusal is settled before the event listener is attached',
    );
  });

  test('a marker arriving late does not re-settle a settled arm', () async {
    final handle = FakeWatcherHandle.armed();
    final executor = _ScriptedExecutor(handle);
    final service = RemoteWatchService(
      executor,
      hostKey: () => 'host',
      admission: WatchAdmission(budget: hostBudget),
      gitDirOf: conventionalGitDir,
    );
    final sub = service.watch('/repo').listen((_) {});
    await executor.armed.future;
    final log = watchDiagnostics.forRepo('/repo');
    while (!log.records.any((r) => r.kind == WatchTransition.armed)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // A duplicated line, or a script that re-announced. Completing an already
    // completed completer throws, which would kill the arm from inside its own
    // stderr listener.
    handle.emitStderr('$watchArmedMarker\n');
    await pumpEventQueue();

    expect(hostBudget.liveTotal, 1);
    await sub.cancel();
    await pumpEventQueue();
  });

  test('the ceiling is a bound on failure, not a cost on success', () {
    // Stated as a constant so an edit that turns it back into something every
    // arm pays has to change a test that says why it must not.
    expect(
      RemoteWatchService.armSignalCeiling,
      greaterThan(const Duration(milliseconds: 250)),
      reason:
          'it is allowed to be generous precisely because no healthy arm '
          'reaches it — the 250 ms it replaces was paid by every arm',
    );
  });
}
