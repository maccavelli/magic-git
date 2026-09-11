// MADR 0026 Phase 2: the transition log is wired into the engine, and the
// hypotheses it exists to discriminate are driven directly.
//
// A new file rather than edits to the existing watcher tests on purpose: the
// wiring must be behaviour-neutral, so no existing expectation may change.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch/engine/watch_engine.dart';
import 'package:remote_magic_git/core/git/watch/source/watch_source.dart';
import 'package:remote_magic_git/core/git/watch/watcher_id.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'helpers/conventional_git_dir.dart';
import 'helpers/fake_arm_settle.dart';
import 'helpers/fake_watcher_handle.dart';
import 'helpers/function_watch_source.dart';

/// Reports `inotifywait` available and hands out silent handles, so every arm
/// succeeds and holds its slot.
class _ArmsAlwaysExecutor extends SSHCommandExecutor {
  _ArmsAlwaysExecutor() : super(SSHClientManager());

  final handles = <FakeWatcherHandle>[];

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
    final h = FakeWatcherHandle.armed();
    handles.add(h);
    return h;
  }
}

void main() {
  late HostWatcherBudget hostBudget;

  setUp(() {
    watchDiagnostics.clear();
    hostBudget = HostWatcherBudget();
  });
  tearDown(watchDiagnostics.clear);

  // ---- 2a: the instrument records the UNHEALTHY transitions ----------------

  test(
    'a ceiling refusal is recorded as armFailed with its cause and count',
    () {
      fakeAsync((async) {
        final executor = _ArmsAlwaysExecutor();
        // A budget of 4 leaves a ceiling of 2 once the CI trace and clone
        // progress channels are reserved — the two this test fills below.
        final service = RemoteWatchService(
          executor,
          streamBudget: () => 4,
          admission: WatchAdmission(budget: hostBudget),
          gitDirOf: conventionalGitDir,
        );
        final subs = <StreamSubscription<RepoWatchEvent>>[];

        // Fill the ceiling, then ask for one more.
        for (final repo in ['/a', '/b']) {
          subs.add(service.watch(repo).listen((_) {}));
        }
        async.letArmsSettle();
        expect(hostBudget.liveTotal, service.maxConcurrentWatchers);

        subs.add(service.watch('/c').listen((_) {}));
        async.letArmsSettle();

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
        expect(armFailed.single.liveWatchers, service.maxConcurrentWatchers);

        // And the engine's own consequence of that refusal.
        expect(
          refused.map((r) => r.kind),
          contains(WatchTransition.degradedToPolling),
          reason: 'a refused arm degrades to the 5s poll — the expensive state',
        );

        for (final s in subs) {
          s.cancel();
        }
        async.flushMicrotasks();
      });
    },
  );

  test('the degradation names WHICH refusal caused it', () {
    fakeAsync((async) {
      // 0028 H2. The engine collapses four different refusals into one
      // `WatchUnavailable` and answers all of them with the same 3-minute
      // recovery. A ceiling refusal is transient and locally controlled — it
      // resolves the instant another watcher stops — where "this host has no
      // inotifywait" is not. The engine cannot tell them apart, so it cannot
      // treat them differently; carrying the reason is the prerequisite.
      final executor = _ArmsAlwaysExecutor();
      final service = RemoteWatchService(
        executor,
        admission: WatchAdmission(budget: hostBudget),
        gitDirOf: conventionalGitDir,
      );
      final subs = <StreamSubscription<RepoWatchEvent>>[];
      for (final repo in ['/a', '/b']) {
        subs.add(service.watch(repo).listen((_) {}));
      }
      async.flushMicrotasks();
      subs.add(service.watch('/c').listen((_) {}));
      async.letArmsSettle();

      final degraded = watchDiagnostics
          .forRepo('/c')
          .records
          .where((r) => r.kind == WatchTransition.degradedToPolling)
          .toList();
      expect(degraded, isNotEmpty);
      expect(
        degraded.last.cause,
        contains('ceiling'),
        reason: 'the engine must know WHY it degraded, not just that it did',
      );

      for (final s in subs) {
        s.cancel();
      }
      async.flushMicrotasks();
    });
  });

  test('a healthy arm is recorded as armed, not as a failure', () {
    fakeAsync((async) {
      final service = RemoteWatchService(
        _ArmsAlwaysExecutor(),
        admission: WatchAdmission(budget: hostBudget),
        gitDirOf: conventionalGitDir,
      );
      final sub = service.watch('/ok').listen((_) {});
      async.letArmsSettle();

      final kinds = watchDiagnostics.forRepo('/ok').records.map((r) => r.kind);
      expect(kinds, contains(WatchTransition.armed));
      expect(kinds, isNot(contains(WatchTransition.degradedToPolling)));
      sub.cancel();
      async.flushMicrotasks();
    });
  });

  test('every record names the watcher that produced it', () {
    fakeAsync((async) {
      // MADR 0045 F9. MADR 0043's investigation read two records as adjacent
      // with nothing to say they came from one watcher. The engine's records
      // carry the session and attempt; the remote source's own records also
      // carry the host token it stamped.
      final service = RemoteWatchService(
        _ArmsAlwaysExecutor(),
        // A budget of 3 less the 2 reserved channels: a ceiling of one.
        streamBudget: () => 3,
        admission: WatchAdmission(budget: hostBudget),
        gitDirOf: conventionalGitDir,
      );
      final held = service.watch('/a', sessionId: 's7').listen((_) {});
      async.letArmsSettle();
      final refused = service.watch('/b', sessionId: 's7').listen((_) {});
      async.letArmsSettle();

      final armed = watchDiagnostics
          .forRepo('/a')
          .records
          .singleWhere((r) => r.kind == WatchTransition.armed);
      expect(
        armed.watcher,
        const WatcherId(sessionId: 's7', repoPath: '/a', attempt: 1),
        reason: "the engine's transition names its session and attempt",
      );
      final armFailed = watchDiagnostics
          .forRepo('/b')
          .records
          .singleWhere((r) => r.kind == WatchTransition.armFailed);
      expect(armFailed.watcher?.sessionId, 's7');
      expect(armFailed.watcher?.attempt, 1);
      expect(
        armFailed.watcher?.token,
        isNotNull,
        reason: "the source's own refusal names the token it stamped",
      );

      held.cancel();
      refused.cancel();
      async.flushMicrotasks();
    });
  });

  // ---- Phase 3: the log is readable while it matters ---------------------

  test('a degradation is explained on the diagnostic channel', () {
    fakeAsync((async) {
      final lines = <String>[];
      final service = RemoteWatchService(
        _ArmsAlwaysExecutor(),
        onDiagnostic: lines.add,
        // Budget 4 less the 2 reserved channels: a ceiling of two, which is
        // what the "watchers held 2" line below is about.
        streamBudget: () => 4,
        admission: WatchAdmission(budget: hostBudget),
        gitDirOf: conventionalGitDir,
      );
      final subs = <StreamSubscription<RepoWatchEvent>>[];
      for (final repo in ['/a', '/b']) {
        subs.add(service.watch(repo).listen((_) {}));
      }
      async.flushMicrotasks();
      subs.add(service.watch('/c').listen((_) {}));
      async.letArmsSettle();

      // The maintainer-facing answer to "why is this repo polling", on the
      // channel watcher stderr already uses.
      final explained = lines.where((l) => l.startsWith('polling /c')).toList();
      expect(
        explained,
        isNotEmpty,
        reason: 'the degradation must be explained',
      );
      expect(explained.single, contains('ceiling'));
      expect(explained.single, contains('watchers held 2'));

      for (final s in subs) {
        s.cancel();
      }
      async.flushMicrotasks();
    });
  });

  test('a repo that never degrades has no summary', () {
    final log = WatchTransitionLog()
      ..add(
        WatchTransitionRecord(
          at: DateTime.now(),
          kind: WatchTransition.armed,
          repoPath: '/ok',
          cause: 'arm succeeded',
          liveWatchers: 1,
          restarts: 0,
        ),
      );
    expect(log.degradationSummary, isNull);
  });

  // ---- 2b: H1 driven directly -------------------------------------------

  test('overlapping start() calls: every armed source is torn down', () {
    fakeAsync((async) {
      // MADR 0026 H1. `start()` was async and unguarded; it nulled
      // `armedTeardown` before `await arm(...)` and only assigned the new one
      // after. A second start() entering that window tore down nothing and
      // armed again, and the later assignment overwrote the first teardown —
      // orphaning a live source and, in RemoteWatchService, leaking the watcher
      // slot it reserved.
      var armCalls = 0;
      var teardowns = 0;
      final gate = Completer<void>();
      FakeArmedSource? captured;

      final stream = WatchEngine(
        source: FunctionWatchSource((_) async {
          armCalls++;
          final armed = FakeArmedSource(onClose: () => teardowns++);
          captured = armed;
          if (armCalls == 1) await gate.future;
          return SourceArmed(armed);
        }),
        repoPath: '/repo',
      ).events;
      final sub = stream.listen((_) {});
      async.letArmsSettle();
      expect(
        armCalls,
        1,
        reason: 'the first arm is in flight, holding the gate',
      );

      // A legitimate re-arm (the watched path set changed) arriving while the
      // first arm has not yet returned.
      captured!.rearm();
      async.flushMicrotasks();
      expect(
        armCalls,
        1,
        reason: 'the re-arm must QUEUE behind the in-flight arm, not race it',
      );

      gate.complete();
      async.flushMicrotasks();
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

      sub.cancel();
      async.flushMicrotasks();

      // THE ASSERTION. Two sources were armed; both must be torn down. Before
      // the fix this was 1: the second start() overwrote the first's teardown,
      // so one source stayed live with nothing holding it — the orphaned
      // `inotifywait` the live census found, and the leaked slot that then
      // refuses every later arm and drops the repo to the 5-second poll.
      expect(
        teardowns,
        2,
        reason:
            'both armed sources must be torn down; H1 is real if only one is',
      );
    });
  });

  test('many re-arms during one slow arm collapse into a single follow-up', () {
    fakeAsync((async) {
      // The serialisation alone would QUEUE all of them, so three timers
      // firing during one slow arm would produce three sequential re-arms —
      // three SSH round trips and three watcher spawns to reach a state one
      // would have reached. At most one follow-up is kept.
      var armCalls = 0;
      final gate = Completer<void>();
      FakeArmedSource? captured;

      final stream = WatchEngine(
        source: FunctionWatchSource((_) async {
          armCalls++;
          final armed = FakeArmedSource();
          captured = armed;
          if (armCalls == 1) await gate.future;
          return SourceArmed(armed);
        }),
        repoPath: '/repo',
      ).events;
      final sub = stream.listen((_) {});
      async.letArmsSettle();
      expect(armCalls, 1);

      captured!
        ..rearm()
        ..rearm()
        ..rearm();
      gate.complete();
      async.flushMicrotasks();

      expect(
        armCalls,
        2,
        reason:
            'one in flight plus one collapsed follow-up, not one per request',
      );
      sub.cancel();
      async.flushMicrotasks();
    });
  });
}
