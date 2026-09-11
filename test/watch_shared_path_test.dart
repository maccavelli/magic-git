// MADR 0043, as MADR 0045 phase 2 re-owns it. One LIVE watcher per repository
// path per session, however many callers ask.
//
// Arming twice at once was possible, and the second arm was refused by this
// app's OWN host-side lock: a healthy repository degraded to polling for three
// minutes because it collided with itself, and said "another live watcher
// already holds" while there was no other session (0043 F1). `heldByAnother` is
// only worth trusting if one session cannot hold one repository twice.
//
// 0043 guaranteed that by sharing one watcher between callers. 0045 guarantees
// it by admission: every call builds its own watcher, and waits for this
// session's previous watcher of the repository to give its lock back. Sharing
// between LISTENERS is Riverpod's, and is pinned in
// repo_watch_provider_sharing_test.dart.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/remote_watch_service.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';

import 'helpers/fake_watcher_handle.dart';
import 'helpers/watch_settle.dart';

/// Records every arm, so "how many watchers exist" is a number rather than an
/// inference.
class _ArmRecorder extends SSHCommandExecutor {
  _ArmRecorder({this.cancelDelay = Duration.zero}) : super(SSHClientManager());

  /// Applied to every handle this executor hands out.
  final Duration cancelDelay;

  final tokens = <String>[];
  final handles = <FakeWatcherHandle>[];

  /// 'arm' and 'teardown' in the order they happened.
  final log = <String>[];

  /// Which surface each arm watched, in order. A recursive arm's argv always
  /// carries the `@./.git/objects` unwatched path; a bounded arm's never does.
  final surfaces = <String>[];

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
    tokens.add(
      RegExp(r'mg-watch\.(\w+)\.pid').firstMatch(gitArgs.join(' '))?[1] ?? '?',
    );
    log.add('arm');
    surfaces.add(
      gitArgs.join(' ').contains('@./.git/objects') ? 'recursive' : 'bounded',
    );
    final h = FakeWatcherHandle.armed(
      cancelDelay: cancelDelay,
      onTeardown: () => log.add('teardown'),
    );
    handles.add(h);
    return h;
  }
}

/// Holds the host-claims release open until [gate] completes, logging around it,
/// as a slow round trip on a real host holds it.
class _GatedRelease extends SSHCommandExecutor {
  _GatedRelease() : super(SSHClientManager());

  /// 'arm', 'teardown', 'release-start' and 'release-done', in order.
  final log = <String>[];
  final gate = Completer<void>();

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
    if (joined.contains('command -v')) {
      return const SSHCommandResult(
        exitCode: 0,
        stdout: 'inotifywait\n',
        stderr: '',
      );
    }
    // The lease-and-lock release; the lease stamp is a `touch`.
    if (joined.contains('rm -f')) {
      log.add('release-start');
      await gate.future;
      log.add('release-done');
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
    log.add('arm');
    return FakeWatcherHandle.armed(onTeardown: () => log.add('teardown'));
  }
}

void main() {
  late HostWatcherBudget hostBudget;

  setUp(() => hostBudget = HostWatcherBudget());
  tearDown(() async {
    await settleArm();
    watchDiagnostics.clear();
  });

  RemoteWatchService serviceOn(_ArmRecorder exec) => RemoteWatchService(
    exec,
    hostKey: () => 'host',
    streamBudget: () => 8,
    admission: WatchAdmission(budget: hostBudget),
  );

  test(
    'two concurrent watch() calls on one path never hold the lock together',
    () async {
      // 0043 F2's reproduction, under admission. Both callers build a watcher —
      // sharing is gone — but the second may not reach the host until the first
      // has given its lock back, so the host lock never sees one session twice.
      final exec = _ArmRecorder();
      final service = serviceOn(exec);

      final a = service.watch('/repo').listen((_) {});
      final b = service.watch('/repo').listen((_) {});
      await settleArm();

      expect(
        exec.log,
        ['arm'],
        reason:
            'the second caller waits for the first watcher\'s lock rather than '
            'arming into it — two arms at once is 0043 F2, and the second is what '
            'the host lock refuses',
      );
      expect(
        hostBudget.liveFor('host'),
        1,
        reason: 'and holds no slot while it waits',
      );

      await a.cancel();
      await settleArm();

      expect(
        exec.log,
        ['arm', 'teardown', 'arm'],
        reason: 'once the first is gone, the second arms — after, never beside',
      );
      expect(
        exec.handles.where((h) => !h.cancelled),
        hasLength(1),
        reason: 'never two live handles',
      );

      await b.cancel();
    },
  );

  test('the last subscriber leaving tears the watcher down', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    await a.cancel();
    await b.cancel();
    await settleArm();

    expect(
      exec.handles.where((h) => !h.cancelled),
      isEmpty,
      reason: 'nobody is listening, so the host must not keep a watcher',
    );
    // Without sharing, the second subscriber arms its own watcher once the
    // first is gone, so how many watchers there were is not the contract. That
    // each was torn down before the next armed is (MADR 0045 plan, deviation
    // (d)).
    expect(exec.log, [
      for (var i = 0; i < exec.log.length; i++) i.isEven ? 'arm' : 'teardown',
    ], reason: 'each watcher is gone before the next arms — never two live');
    expect(hostBudget.liveFor('host'), 0, reason: 'and the slot goes back');
  });

  test('two different paths still get two watchers', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/one').listen((_) {});
    final b = service.watch('/two').listen((_) {});
    await settleArm();

    expect(
      exec.tokens,
      hasLength(2),
      reason: 'sharing is per PATH; different repositories are unrelated',
    );
    expect(hostBudget.liveFor('host'), 2);

    await a.cancel();
    await b.cancel();
  });

  test(
    'two services on one path arm twice — sharing is per connection',
    () async {
      // Two tabs are two sessions, with two executors and two exclusions, and
      // the host lock is what arbitrates between them (MADR 0041 F12). One
      // exclusion across both would make one session wait on another's watcher
      // — and hide the collision the host lock exists to report.
      final execA = _ArmRecorder();
      final execB = _ArmRecorder();

      final a = serviceOn(execA).watch('/repo').listen((_) {});
      final b = serviceOn(execB).watch('/repo').listen((_) {});
      await settleArm();

      expect(execA.tokens, hasLength(1));
      expect(
        execB.tokens,
        hasLength(1),
        reason:
            'a second SERVICE is a second session with its own exclusion; it '
            'must still arm and still meet the host lock, which is the mechanism '
            'built for that case',
      );

      await a.cancel();
      await b.cancel();
    },
  );

  test('a stream that is never listened to arms nothing', () async {
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    service.watch('/repo'); // handed out, never subscribed
    await settleArm();

    expect(
      exec.tokens,
      isEmpty,
      reason:
          'building on first listen, not on the call, is what keeps an '
          'unused stream free',
    );
  });

  test('a rebuilt caller re-arms after the last subscriber left', () async {
    // The provider-rebuild shape: the old subscription goes, a new one
    // arrives. One watcher at a time, but a NEW one — the path is watched
    // again rather than left dead.
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    await settleArm();
    await a.cancel();
    await settleArm();

    final b = service.watch('/repo').listen((_) {});
    await settleArm();

    expect(exec.tokens, hasLength(2), reason: 'a second, distinct watcher');
    expect(
      exec.tokens.first,
      isNot(exec.tokens.last),
      reason: 'each watcher owns its own lease, per 0027',
    );
    expect(hostBudget.liveFor('host'), 1);

    await b.cancel();
  });

  test('a new subscriber waits for a pending teardown before arming', () async {
    // MADR 0043 F3/F4, and the gap a sabotage run found: the earlier re-arm
    // test settles between cancelling and re-subscribing, so the teardown has
    // already finished and the gate is never exercised. Here the teardown is
    // deliberately slow and the next subscriber arrives DURING it — which on a
    // real host is the arm that gets refused by its own predecessor.
    final exec = _ArmRecorder(cancelDelay: const Duration(milliseconds: 400));
    final service = serviceOn(exec);

    final a = service.watch('/repo').listen((_) {});
    await settleArm();
    expect(exec.log, ['arm']);

    // Cancel and immediately re-subscribe — no settle, so the teardown is
    // still in flight.
    unawaited(a.cancel());
    final b = service.watch('/repo').listen((_) {});
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      exec.log,
      ['arm', 'teardown', 'arm'],
      reason:
          'the second watcher must not be built until the first has finished '
          'giving its host lock back — arming into that window is exactly the '
          'refusal MADR 0043 is about',
    );

    await b.cancel();
  });

  // MADR 0043 amendment 0043.1 (0044 PLAN deviation (c)). Found on a live host:
  // a backgrounded tab's watcher kept its lock and lease for over thirty minutes
  // because nothing held it. The sequence below is the shape a reconnect's
  // family-wide invalidate produces while the dying watcher's teardown is still
  // talking to a redialing transport. None of the tests above lets a subscriber
  // LEAVE while a build is still deferred, which is why it went unseen.

  test(
    'a subscriber leaving while a build is deferred orphans nothing',
    () async {
      final exec = _ArmRecorder(cancelDelay: const Duration(milliseconds: 400));
      final service = serviceOn(exec);
      Iterable<FakeWatcherHandle> live() =>
          exec.handles.where((h) => !h.cancelled);

      final s1 = service.watch('/repo').listen((_) {});
      await settleArm();

      unawaited(s1.cancel()); // the teardown is now in flight
      await pumpEventQueue();
      final s2 = service.watch('/repo').listen((_) {});
      await pumpEventQueue();
      unawaited(s2.cancel()); // ...and this one leaves before it settles
      await pumpEventQueue();
      final s3 = service.watch('/repo').listen((_) {});
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        live(),
        hasLength(1),
        reason:
            'one subscriber, so exactly one watcher — not one per interleaving',
      );

      await s3.cancel();
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        live(),
        isEmpty,
        reason:
            'with every subscriber gone, a watcher still alive is held by nothing: '
            'it keeps its host lock and lease until the connection dies',
      );
      expect(hostBudget.liveFor('host'), 0);
    },
  );

  test(
    'arriving, leaving and arriving during a teardown arms once, after it',
    () async {
      final exec = _ArmRecorder(cancelDelay: const Duration(milliseconds: 400));
      final service = serviceOn(exec);

      final a = service.watch('/repo').listen((_) {});
      await settleArm();
      unawaited(a.cancel());
      await pumpEventQueue();
      final b = service.watch('/repo').listen((_) {});
      await pumpEventQueue();
      unawaited(b.cancel());
      await pumpEventQueue();
      final c = service.watch('/repo').listen((_) {});
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        exec.log,
        ['arm', 'teardown', 'arm'],
        reason:
            'however subscribers come and go while a teardown is in flight, the '
            'next watcher is built once, and only after the lock has been given back',
      );

      await c.cancel();
    },
  );

  test(
    'a teardown that never settles holds the next arm only until the grace',
    () {
      fakeAsync((async) {
        // Longer than the grace by design: this teardown is, for the test's
        // purposes, one that never completes.
        final exec = _ArmRecorder(cancelDelay: const Duration(minutes: 10));
        final service = serviceOn(exec);

        final a = service.watch('/repo').listen((_) {});
        async.elapse(const Duration(seconds: 1));
        expect(exec.log, ['arm']);

        unawaited(a.cancel());
        async.flushMicrotasks();
        final b = service.watch('/repo').listen((_) {});
        async.elapse(
          WatchTimings.defaultAdmissionGrace - const Duration(seconds: 5),
        );
        expect(exec.log, [
          'arm',
        ], reason: 'inside the grace, the next arm waits for the teardown');

        async.elapse(const Duration(seconds: 10));
        expect(
          exec.log,
          ['arm', 'arm'],
          reason:
              'past the grace, it arms anyway: a wedged teardown degrades to the old '
              'race rather than leaving the repository unwatchable',
        );

        unawaited(b.cancel());
        async.elapse(const Duration(minutes: 11));
      });
    },
  );

  test('a rebuild with new parameters arms the new surface', () async {
    // The provider-rebuild shape that 0043's factory refresh existed for: in one
    // flush, the old subscription goes and a new one arrives asking for a
    // DIFFERENT surface. A shared watcher keyed by path alone kept the first
    // caller's parameters (MADR 0045 F1); a watcher per call cannot.
    final exec = _ArmRecorder();
    final service = serviceOn(exec);

    final recursive = service.watch('/repo').listen((_) {});
    await settleArm();

    unawaited(recursive.cancel());
    final bounded = service
        .watch(
          '/repo',
          bounded: () async => computeBoundedWatchSpec(
            gitDir: '/repo/.git',
            workTree: '/repo',
            trackedFiles: const ['a.txt'],
          ),
        )
        .listen((_) {});
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      exec.surfaces,
      ['recursive', 'bounded'],
      reason: 'the second watcher is built from the second call\'s parameters',
    );
    expect(
      exec.handles.where((h) => !h.cancelled),
      hasLength(1),
      reason: 'and it replaced the first rather than joining it',
    );

    await bounded.cancel();
  });

  test('the next watcher waits for the host claims, not just the channel', () async {
    // MADR 0045 plan, deviation (e). The pending-teardown test above cannot see
    // this: its executor answers the release at once, and logs `teardown` when
    // the channel closes — before the release. Here the release is held open
    // and the next subscriber arrives meanwhile. Releasing the exclusion before
    // the host has given its lock back would let that subscriber arm into its
    // own predecessor's lock (MADR 0043 F3, F4).
    final exec = _GatedRelease();
    final service = RemoteWatchService(
      exec,
      hostKey: () => 'host',
      streamBudget: () => 8,
      admission: WatchAdmission(budget: hostBudget),
    );

    final a = service.watch('/repo').listen((_) {});
    await settleArm();
    unawaited(a.cancel());
    final b = service.watch('/repo').listen((_) {});
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(exec.log, [
      'arm',
      'teardown',
      'release-start',
    ], reason: 'the host still holds the lock, so the next arm must not start');

    exec.gate.complete();
    await settleArm();

    expect(exec.log, [
      'arm',
      'teardown',
      'release-start',
      'release-done',
      'arm',
    ], reason: 'and it arms once the host has let go');
    await b.cancel();
  });
}
