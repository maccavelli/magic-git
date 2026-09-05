// MADR 0026 Phase 2: the transition log is wired into the engine, and the
// hypotheses it exists to discriminate are driven directly.
//
// A new file rather than edits to the existing watcher tests on purpose: the
// wiring must be behaviour-neutral, so no existing expectation may change.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/git/watch_lifecycle.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

/// A stream handle that never emits and never exits — a watcher that armed and
/// is simply waiting, which is the healthy steady state.
class _SilentHandle implements SSHStreamHandle {
  final _out = StreamController<String>.broadcast();
  final _err = StreamController<String>.broadcast();
  var cancelled = false;

  @override
  Stream<String> get stdout => _out.stream;
  @override
  Stream<String> get stderr => _err.stream;
  @override
  Future<int?> get exitCode => Completer<int?>().future;
  @override
  Future<void> cancel() async {
    cancelled = true;
    await _out.close();
    await _err.close();
  }
}

/// Reports `inotifywait` available and hands out silent handles, so every arm
/// succeeds and holds its slot.
class _ArmsAlwaysExecutor extends SSHCommandExecutor {
  _ArmsAlwaysExecutor() : super(SSHClientManager());

  final handles = <_SilentHandle>[];

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
  }) async =>
      const SSHCommandResult(exitCode: 0, stdout: 'inotifywait\n', stderr: '');

  @override
  Future<SSHStreamHandle> executeStream({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    Duration openTimeout = SSHCommandExecutor.defaultTimeout,
    OperationDescriptor? operation,
    OperationEventCallback? onOperationEvent,
  }) async {
    final h = _SilentHandle();
    handles.add(h);
    return h;
  }
}

void main() {
  setUp(() {
    watchDiagnostics.clear();
    RemoteWatchService.resetWatcherCount();
  });
  tearDown(() {
    watchDiagnostics.clear();
    RemoteWatchService.resetWatcherCount();
  });

  // ---- 2a: the instrument records the UNHEALTHY transitions ----------------

  test(
    'a ceiling refusal is recorded as armFailed with its cause and count',
    () async {
      final executor = _ArmsAlwaysExecutor();
      final service = RemoteWatchService(executor);
      final subs = <StreamSubscription<RepoWatchEvent>>[];

      // Fill the ceiling, then ask for one more.
      for (final repo in ['/a', '/b']) {
        subs.add(service.watch(repo).listen((_) {}));
      }
      await pumpEventQueue();
      expect(
        RemoteWatchService.liveWatchers,
        RemoteWatchService.maxConcurrentWatchers,
      );

      subs.add(service.watch('/c').listen((_) {}));
      await pumpEventQueue();

      final refused = watchDiagnostics.forRepo('/c').records;
      expect(
        refused,
        isNotEmpty,
        reason: 'the refusal must be recorded at all',
      );

      final armFailed = refused
          .where((r) => r.kind == WatchTransition.armFailed)
          .toList();
      expect(armFailed, hasLength(1));
      expect(armFailed.single.cause, contains('ceiling'));
      expect(
        armFailed.single.liveWatchers,
        RemoteWatchService.maxConcurrentWatchers,
      );

      // And the engine's own consequence of that refusal.
      expect(
        refused.map((r) => r.kind),
        contains(WatchTransition.degradedToPolling),
        reason: 'a refused arm degrades to the 5s poll — the expensive state',
      );

      for (final s in subs) {
        await s.cancel();
      }
    },
  );

  test('a healthy arm is recorded as armed, not as a failure', () async {
    final service = RemoteWatchService(_ArmsAlwaysExecutor());
    final sub = service.watch('/ok').listen((_) {});
    await pumpEventQueue();

    final kinds = watchDiagnostics.forRepo('/ok').records.map((r) => r.kind);
    expect(kinds, contains(WatchTransition.armed));
    expect(kinds, isNot(contains(WatchTransition.degradedToPolling)));
    await sub.cancel();
  });

  // ---- 2b: H1 driven directly -------------------------------------------

  test('overlapping start() calls: every armed source is torn down', () async {
    // MADR 0026 H1. `start()` is async and unguarded; it nulls `armedTeardown`
    // before `await arm(...)` and only assigns the new one after. A second
    // start() entering that window tears down nothing and arms again, and the
    // later assignment overwrites the first teardown — orphaning a live source
    // and, in RemoteWatchService, leaking the watcher slot it reserved.
    var armCalls = 0;
    var teardowns = 0;
    final gate = Completer<void>();
    WatchHooks? captured;

    final stream = watchLifecycle(
      arm: (hooks) async {
        armCalls++;
        captured = hooks;
        if (armCalls == 1) await gate.future;
        return WatchArmed(() async {
          teardowns++;
        });
      },
    );
    final sub = stream.listen((_) {});
    await pumpEventQueue();
    expect(armCalls, 1, reason: 'the first arm is in flight, holding the gate');

    // A legitimate re-arm (the watched path set changed) arriving while the
    // first arm has not yet returned.
    captured!.rearm();
    await pumpEventQueue();
    expect(
      armCalls,
      1,
      reason: 'the re-arm must QUEUE behind the in-flight arm, not race it',
    );

    gate.complete();
    await pumpEventQueue();
    expect(
      armCalls,
      2,
      reason: 'the queued re-arm runs once the first is done',
    );
    expect(
      teardowns,
      1,
      reason: 'the queued re-arm tore the first source down before arming',
    );

    await sub.cancel();
    await pumpEventQueue();

    // THE ASSERTION. Two sources were armed; both must be torn down. Before the
    // fix this was 1: the second start() overwrote the first's teardown, so one
    // source stayed live with nothing holding it — the orphaned `inotifywait`
    // the live census found, and the leaked slot that then refuses every later
    // arm and drops the repo to the 5-second poll.
    expect(
      teardowns,
      2,
      reason: 'both armed sources must be torn down; H1 is real if only one is',
    );
  });

  test(
    'many re-arms during one slow arm collapse into a single follow-up',
    () async {
      // The serialisation alone would QUEUE all of them, so three timers firing
      // during one slow arm would produce three sequential re-arms — three SSH
      // round trips and three watcher spawns to reach a state one would have
      // reached. At most one follow-up is kept.
      var armCalls = 0;
      final gate = Completer<void>();
      WatchHooks? captured;

      final stream = watchLifecycle(
        arm: (hooks) async {
          armCalls++;
          captured = hooks;
          if (armCalls == 1) await gate.future;
          return WatchArmed(() async {});
        },
      );
      final sub = stream.listen((_) {});
      await pumpEventQueue();
      expect(armCalls, 1);

      captured!
        ..rearm()
        ..rearm()
        ..rearm();
      gate.complete();
      await pumpEventQueue();

      expect(
        armCalls,
        2,
        reason:
            'one in flight plus one collapsed follow-up, not one per request',
      );
      await sub.cancel();
    },
  );
}
