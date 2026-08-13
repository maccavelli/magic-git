// CommandLaneScheduler: reads overlap (bounded), sync ops run one-at-a-time
// alongside reads, and exclusives run strictly alone with FIFO barrier
// semantics — the invariants both executors rely on for `.git/index.lock`
// safety without head-of-line blocking.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_lanes.dart';

/// A job whose completion the test controls explicitly.
class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();

  Future<void> body() async {
    started.complete();
    await release.future;
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// These tests gate their jobs by hand and hold them open across many `_tick`s,
/// so the scheduler's overrun watchdog must stay well out of their way — it is a
/// backstop against a body that never settles, not a clock on a slow one. A
/// deadline no test comes close to keeps it out of the way here, and the
/// watchdog gets its own tests below.
extension _RunForever on CommandLaneScheduler {
  Future<T> run0<T>(ExecLane lane, Future<T> Function() body) =>
      run(lane, body, deadline: const Duration(minutes: 5));
}

void main() {
  test('onStarted fires exactly once when the job receives its lane', () async {
    final scheduler = CommandLaneScheduler(maxConcurrentReads: 1);
    final blocker = Completer<void>();
    final order = <String>[];
    final first = scheduler.run(ExecLane.exclusive, () async {
      order.add('first body');
      await blocker.future;
    }, deadline: const Duration(minutes: 1));
    final second = scheduler.run(
      ExecLane.exclusive,
      () async => order.add('second body'),
      deadline: const Duration(minutes: 1),
      onStarted: () => order.add('second started'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(order, ['first body']);
    blocker.complete();
    await Future.wait([first, second]);
    expect(order, ['first body', 'second started', 'second body']);
  });

  test('reads run concurrently up to maxConcurrentReads', () async {
    final s = CommandLaneScheduler(maxConcurrentReads: 3);
    final gates = List.generate(5, (_) => _Gate());
    final futures = [for (final g in gates) s.run0(ExecLane.read, g.body)];
    await _tick();

    // First three start together; the pool holds the last two back.
    expect(gates.take(3).every((g) => g.started.isCompleted), isTrue);
    expect(gates.skip(3).any((g) => g.started.isCompleted), isFalse);
    expect(s.activeReads, 3);

    gates[0].release.complete();
    await _tick();
    expect(gates[3].started.isCompleted, isTrue);

    for (final g in gates) {
      if (!g.release.isCompleted) g.release.complete();
    }
    await Future.wait(futures);
    expect(s.activeReads, 0);
    expect(s.queued, 0);
  });

  test('setMaxConcurrentReads lowers without cancelling in-flight', () async {
    final s = CommandLaneScheduler(maxConcurrentReads: 3);
    final gates = List.generate(4, (_) => _Gate());
    final futures = [for (final g in gates) s.run0(ExecLane.read, g.body)];
    await _tick();
    expect(s.activeReads, 3);

    // Lowering the cap must not kill running jobs — only hold the 4th.
    s.setMaxConcurrentReads(2);
    expect(s.maxConcurrentReads, 2);
    expect(s.activeReads, 3);
    expect(gates[3].started.isCompleted, isFalse);

    // Finish one: still at 2 active (cap), 4th still held.
    gates[0].release.complete();
    await _tick();
    expect(s.activeReads, 2);
    expect(gates[3].started.isCompleted, isFalse);

    // Finish another: now under cap, 4th starts.
    gates[1].release.complete();
    await _tick();
    expect(gates[3].started.isCompleted, isTrue);

    for (final g in gates) {
      if (!g.release.isCompleted) g.release.complete();
    }
    await Future.wait(futures);
  });

  test('setMaxConcurrentReads raise pumps the queue', () async {
    final s = CommandLaneScheduler(maxConcurrentReads: 1);
    final a = _Gate();
    final b = _Gate();
    final futures = [
      s.run0(ExecLane.read, a.body),
      s.run0(ExecLane.read, b.body),
    ];
    await _tick();
    expect(a.started.isCompleted, isTrue);
    expect(b.started.isCompleted, isFalse);

    s.setMaxConcurrentReads(2);
    await _tick();
    expect(b.started.isCompleted, isTrue);

    a.release.complete();
    b.release.complete();
    await Future.wait(futures);
  });

  test('setMaxConcurrentReads clamps to [1, maxReadCapHardLimit]', () {
    final s = CommandLaneScheduler(maxConcurrentReads: 4);
    s.setMaxConcurrentReads(0);
    expect(s.maxConcurrentReads, 1);
    s.setMaxConcurrentReads(100);
    expect(s.maxConcurrentReads, CommandLaneScheduler.maxReadCapHardLimit);
    s.setMaxConcurrentReads(4);
    expect(s.maxConcurrentReads, 4);
    // Same value is a no-op (still 4).
    s.setMaxConcurrentReads(4);
    expect(s.maxConcurrentReads, 4);
  });

  test('constructor clamps initial maxConcurrentReads', () {
    final low = CommandLaneScheduler(maxConcurrentReads: 0);
    expect(low.maxConcurrentReads, 1);
    final high = CommandLaneScheduler(maxConcurrentReads: 99);
    expect(high.maxConcurrentReads, CommandLaneScheduler.maxReadCapHardLimit);
  });

  test('sync ops run one at a time but overlap reads', () async {
    final s = CommandLaneScheduler();
    final read = _Gate();
    final syncA = _Gate();
    final syncB = _Gate();
    final futures = [
      s.run0(ExecLane.sync, syncA.body),
      s.run0(ExecLane.read, read.body),
      s.run0(ExecLane.sync, syncB.body),
    ];
    await _tick();

    // The read overlaps the running sync; the second sync waits for the first.
    expect(syncA.started.isCompleted, isTrue);
    expect(read.started.isCompleted, isTrue);
    expect(syncB.started.isCompleted, isFalse);

    syncA.release.complete();
    await _tick();
    expect(syncB.started.isCompleted, isTrue);

    read.release.complete();
    syncB.release.complete();
    await Future.wait(futures);
  });

  test('an exclusive waits for everything in flight and runs alone', () async {
    final s = CommandLaneScheduler();
    final read = _Gate();
    final sync = _Gate();
    final excl = _Gate();
    final after = _Gate();
    final futures = [
      s.run0(ExecLane.read, read.body),
      s.run0(ExecLane.sync, sync.body),
      s.run0(ExecLane.exclusive, excl.body),
      // Enqueued after the exclusive — the barrier holds it back even though
      // the read pool has room.
      s.run0(ExecLane.read, after.body),
    ];
    await _tick();

    expect(read.started.isCompleted, isTrue);
    expect(sync.started.isCompleted, isTrue);
    expect(excl.started.isCompleted, isFalse);
    expect(after.started.isCompleted, isFalse, reason: 'barrier must hold');

    read.release.complete();
    await _tick();
    expect(excl.started.isCompleted, isFalse, reason: 'sync still active');

    sync.release.complete();
    await _tick();
    expect(excl.started.isCompleted, isTrue);
    expect(s.activeExclusives, 1);
    expect(
      after.started.isCompleted,
      isFalse,
      reason: 'nothing overlaps an exclusive',
    );

    excl.release.complete();
    await _tick();
    expect(after.started.isCompleted, isTrue);

    after.release.complete();
    await Future.wait(futures);
  });

  test('two exclusives run in strict FIFO order', () async {
    final s = CommandLaneScheduler();
    final order = <String>[];
    final a = s.run0(ExecLane.exclusive, () async => order.add('a'));
    final b = s.run0(ExecLane.exclusive, () async => order.add('b'));
    await Future.wait([a, b]);
    expect(order, ['a', 'b']);
  });

  test(
    'a failing job propagates to its caller without wedging the queue',
    () async {
      final s = CommandLaneScheduler();
      final failing = s.run0<void>(ExecLane.exclusive, () async {
        throw StateError('boom');
      });
      final next = s.run0(ExecLane.read, () async => 42);
      await expectLater(failing, throwsStateError);
      expect(await next, 42);
      expect(s.queued, 0);
    },
  );

  test('a job never starts synchronously inside the enqueue call', () async {
    final s = CommandLaneScheduler();
    var started = false;
    final f = s.run0(ExecLane.read, () async {
      started = true;
    });
    // State mutated after enqueue but before any await must be visible to the
    // job (this is what generation-pinning in the SSH executor depends on).
    expect(started, isFalse);
    await f;
    expect(started, isTrue);
  });

  group('the isolated lane lives outside the exclusive barrier', () {
    // The lane exists for long-running side work (a worktree post-create
    // `pnpm install`) whose effects are disjoint from everything the git lanes
    // protect. On the exclusive lane such a command WAS the barrier: every
    // background refresh in the app queued behind a package install.

    test(
      'an isolated job overlaps a running exclusive — both directions',
      () async {
        final s = CommandLaneScheduler();
        final excl = _Gate();
        final iso = _Gate();
        final futures = [
          s.run0(ExecLane.exclusive, excl.body),
          s.run0(ExecLane.isolated, iso.body),
        ];
        await _tick();

        // Nothing overlaps an exclusive — except this.
        expect(excl.started.isCompleted, isTrue);
        expect(iso.started.isCompleted, isTrue);

        // And the reverse: a still-running isolated job must not delay the next
        // exclusive, or a 20-minute install re-creates the stall lane-by-lane.
        final excl2 = _Gate();
        futures.add(s.run0(ExecLane.exclusive, excl2.body));
        excl.release.complete();
        await _tick();
        expect(iso.release.isCompleted, isFalse, reason: 'install still going');
        expect(excl2.started.isCompleted, isTrue);

        iso.release.complete();
        excl2.release.complete();
        await Future.wait(futures);
      },
    );

    test('an isolated job passes the barrier that holds reads back', () async {
      final s = CommandLaneScheduler();
      final read = _Gate();
      final excl = _Gate();
      final readAfter = _Gate();
      final iso = _Gate();
      final futures = [
        s.run0(ExecLane.read, read.body),
        // Waits on the in-flight read, and bars everything queued after it…
        s.run0(ExecLane.exclusive, excl.body),
        s.run0(ExecLane.read, readAfter.body),
        // …except an isolated job, which no barrier applies to.
        s.run0(ExecLane.isolated, iso.body),
      ];
      await _tick();

      expect(excl.started.isCompleted, isFalse);
      expect(readAfter.started.isCompleted, isFalse, reason: 'barred');
      expect(iso.started.isCompleted, isTrue);

      read.release.complete();
      await _tick();
      expect(excl.started.isCompleted, isTrue, reason: 'isolated is invisible');

      excl.release.complete();
      await _tick();
      readAfter.release.complete();
      iso.release.complete();
      await Future.wait(futures);
    });

    test('bounded by maxConcurrentIsolated, FIFO within the lane', () async {
      final s = CommandLaneScheduler(maxConcurrentIsolated: 2);
      final gates = List.generate(3, (_) => _Gate());
      final futures = [
        for (final g in gates) s.run0(ExecLane.isolated, g.body),
      ];
      await _tick();

      expect(gates[0].started.isCompleted, isTrue);
      expect(gates[1].started.isCompleted, isTrue);
      expect(gates[2].started.isCompleted, isFalse, reason: 'over the cap');
      expect(s.activeIsolated, 2);

      gates[0].release.complete();
      await _tick();
      expect(gates[2].started.isCompleted, isTrue);

      gates[1].release.complete();
      gates[2].release.complete();
      await Future.wait(futures);
      expect(s.activeIsolated, 0);
      expect(s.queued, 0);
    });

    test('a wedged isolated job is reclaimed like any other', () async {
      final s = CommandLaneScheduler(maxConcurrentIsolated: 1);
      final wedged = s.run<void>(
        ExecLane.isolated,
        () => Completer<void>().future,
        deadline: const Duration(milliseconds: 50),
      );
      // Queued behind the wedged one at cap 1 — only the watchdog frees it.
      final next = s.run0(ExecLane.isolated, () async => 42);

      await expectLater(wedged, throwsA(isA<CommandLaneOverrun>()));
      await expectLater(
        next.timeout(const Duration(seconds: 2)),
        completion(42),
      );
      expect(s.activeIsolated, 0);
    });
  });

  group('a job that never settles cannot wedge the app', () {
    // Everything here used to rest on an invariant the scheduler never checked:
    // that a job body always settles. It does today — both executors wrap their
    // command in `.timeout()` and kill the process — but nothing enforced it,
    // and a body that never settles never runs its `whenComplete`, so its slot
    // is never given back. Six of those and the read lane is gone; ONE on the
    // exclusive lane and every command in the app queues behind it, forever,
    // with no error raised anywhere. The app just stops, and every pane waiting
    // on a read spins.

    test('its slot is reclaimed and the caller is told', () async {
      final s = CommandLaneScheduler();
      // A body that will never, ever complete.
      final wedged = s.run<void>(
        ExecLane.exclusive,
        () => Completer<void>().future,
        deadline: const Duration(milliseconds: 50),
      );

      await expectLater(wedged, throwsA(isA<CommandLaneOverrun>()));
      expect(
        s.activeExclusives,
        0,
        reason: 'the slot must go back, or nothing ever runs again',
      );
    });

    test('and the commands queued behind it still run', () async {
      final s = CommandLaneScheduler();
      unawaited(
        s
            .run<void>(
              ExecLane.exclusive,
              () => Completer<void>().future,
              deadline: const Duration(milliseconds: 50),
            )
            .catchError((_) {}),
      );

      // An exclusive at the head of the queue is a barrier: until it is gone,
      // this read cannot start. If the wedged job kept its slot, this future
      // would never complete — which is precisely the app-wide freeze.
      final read = s.run0(ExecLane.read, () async => 42);
      await expectLater(
        read.timeout(const Duration(seconds: 2)),
        completion(42),
      );
    });

    test('a body that comes back from the dead cannot double-answer', () async {
      // The watchdog already failed this caller. If the body then settles, the
      // first answer has to stand — completing a Completer twice throws.
      final s = CommandLaneScheduler();
      final late = Completer<int>();
      final call = s.run<int>(
        ExecLane.read,
        () => late.future,
        deadline: const Duration(milliseconds: 50),
      );
      await expectLater(call, throwsA(isA<CommandLaneOverrun>()));

      late.complete(7);
      await _tick();
      expect(s.activeReads, 0, reason: 'and the slot is not given back twice');
    });

    test(
      'a job that finishes normally is never touched by the watchdog',
      () async {
        // The backstop must never be the thing that ends a merely-slow command.
        final s = CommandLaneScheduler();
        final result = await s.run<int>(ExecLane.exclusive, () async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return 1;
        }, deadline: const Duration(seconds: 5));
        expect(result, 1);
        expect(s.activeExclusives, 0);
      },
    );
  });
}
