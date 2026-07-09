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

void main() {
  test('reads run concurrently up to maxConcurrentReads', () async {
    final s = CommandLaneScheduler(maxConcurrentReads: 3);
    final gates = List.generate(5, (_) => _Gate());
    final futures = [
      for (final g in gates) s.run(ExecLane.read, g.body),
    ];
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

  test('sync ops run one at a time but overlap reads', () async {
    final s = CommandLaneScheduler();
    final read = _Gate();
    final syncA = _Gate();
    final syncB = _Gate();
    final futures = [
      s.run(ExecLane.sync, syncA.body),
      s.run(ExecLane.read, read.body),
      s.run(ExecLane.sync, syncB.body),
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
      s.run(ExecLane.read, read.body),
      s.run(ExecLane.sync, sync.body),
      s.run(ExecLane.exclusive, excl.body),
      // Enqueued after the exclusive — the barrier holds it back even though
      // the read pool has room.
      s.run(ExecLane.read, after.body),
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
    final a = s.run(ExecLane.exclusive, () async => order.add('a'));
    final b = s.run(ExecLane.exclusive, () async => order.add('b'));
    await Future.wait([a, b]);
    expect(order, ['a', 'b']);
  });

  test('a failing job propagates to its caller without wedging the queue',
      () async {
    final s = CommandLaneScheduler();
    final failing = s.run<void>(ExecLane.exclusive, () async {
      throw StateError('boom');
    });
    final next = s.run(ExecLane.read, () async => 42);
    await expectLater(failing, throwsStateError);
    expect(await next, 42);
    expect(s.queued, 0);
  });

  test('a job never starts synchronously inside the enqueue call', () async {
    final s = CommandLaneScheduler();
    var started = false;
    final f = s.run(ExecLane.read, () async {
      started = true;
    });
    // State mutated after enqueue but before any await must be visible to the
    // job (this is what generation-pinning in the SSH executor depends on).
    expect(started, isFalse);
    await f;
    expect(started, isTrue);
  });
}
