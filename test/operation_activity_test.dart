import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/exec/command_lanes.dart';
import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';

const _descriptor = OperationDescriptor(
  repositoryPath: '/repo',
  label: 'Stage changes',
  kind: OperationKind.gitMutation,
  lane: ExecLane.exclusive,
);

OperationEvent _event(
  OperationId id,
  OperationPhase phase,
  DateTime at, {
  String? result,
}) => OperationEvent(
  id: id,
  descriptor: _descriptor,
  phase: phase,
  occurredAt: at,
  result: result,
);

void main() {
  test('lifecycle is monotonic and terminal state is final', () {
    final store = OperationActivityStore();
    const id = OperationId('op-1');
    final t0 = DateTime.utc(2026, 1, 1);
    store.apply(_event(id, OperationPhase.queued, t0));
    store.apply(
      _event(id, OperationPhase.running, t0.add(const Duration(seconds: 2))),
    );
    store.apply(
      _event(id, OperationPhase.succeeded, t0.add(const Duration(seconds: 5))),
    );
    store.apply(
      _event(id, OperationPhase.running, t0.add(const Duration(seconds: 6))),
    );

    final record = store.records.single;
    expect(record.phase, OperationPhase.succeeded);
    expect(record.startedAt, t0.add(const Duration(seconds: 2)));
    expect(
      record.elapsed(t0.add(const Duration(days: 1))),
      const Duration(seconds: 3),
    );
  });

  test('unknown non-queued and duplicate terminal events are ignored', () {
    final store = OperationActivityStore();
    const id = OperationId('op-1');
    final now = DateTime.utc(2026, 1, 1);
    store.apply(_event(id, OperationPhase.running, now));
    expect(store.records, isEmpty);

    store.apply(_event(id, OperationPhase.queued, now));
    store.apply(_event(id, OperationPhase.failed, now, result: 'failed'));
    store.apply(_event(id, OperationPhase.succeeded, now, result: 'late'));
    expect(store.records.single.phase, OperationPhase.failed);
    expect(store.records.single.result, 'failed');
  });

  test('retention never evicts active work and caps recent terminal work', () {
    final store = OperationActivityStore(
      maxTerminalRecords: 2,
      terminalRetention: const Duration(minutes: 30),
    );
    final now = DateTime.utc(2026, 1, 1, 1);
    const active = OperationId('active');
    store.apply(
      _event(
        active,
        OperationPhase.queued,
        now.subtract(const Duration(hours: 2)),
      ),
    );
    for (var i = 0; i < 4; i++) {
      final id = OperationId('done-$i');
      store.apply(_event(id, OperationPhase.queued, now));
      store.apply(_event(id, OperationPhase.succeeded, now));
    }

    expect(store.records.where((record) => !record.isTerminal), hasLength(1));
    expect(store.records.where((record) => record.isTerminal), hasLength(2));
  });

  test('disconnect supersedes all active work before a new epoch', () {
    final store = OperationActivityStore();
    final now = DateTime.utc(2026, 1, 1);
    for (final value in ['queued', 'running']) {
      final id = OperationId(value);
      store.apply(_event(id, OperationPhase.queued, now));
      if (value == 'running') {
        store.apply(_event(id, OperationPhase.running, now));
      }
    }
    store.supersedeActive(now.add(const Duration(seconds: 1)));
    expect(
      store.records,
      everyElement(predicate<OperationRecord>((r) => r.isTerminal)),
    );
    expect(
      store.records,
      everyElement(
        predicate<OperationRecord>((r) => r.result!.contains('Superseded')),
      ),
    );
  });

  test('wire descriptor excludes argv, stdin, environment, and tokens', () {
    final wire = _descriptor.toWire();
    expect(wire.keys, isNot(contains('gitArgs')));
    expect(wire.keys, isNot(contains('stdin')));
    expect(wire.keys, isNot(contains('extraEnv')));
    expect(OperationDescriptor.fromWire(wire)?.label, 'Stage changes');
  });

  test(
    'local executor emits queued, running, and exactly one terminal event',
    () async {
      final events = <OperationEvent>[];
      final executor = LocalCommandExecutor();
      final result = await executor.execute(
        repoPath: Directory.systemTemp.path,
        gitArgs: ['sh', '-c', 'exit 0'],
        lane: ExecLane.exclusive,
        operation: _descriptor,
        onOperationEvent: events.add,
      );
      expect(result.isSuccess, isTrue);
      expect(events.map((event) => event.phase), [
        OperationPhase.queued,
        OperationPhase.running,
        OperationPhase.succeeded,
      ]);
    },
  );

  test(
    'a mutation queued behind another is acknowledged before it starts',
    () async {
      final executor = LocalCommandExecutor();
      final first = executor.execute(
        repoPath: Directory.systemTemp.path,
        gitArgs: ['sh', '-c', 'sleep 0.15'],
        lane: ExecLane.exclusive,
      );
      final events = <OperationEvent>[];
      final second = executor.execute(
        repoPath: Directory.systemTemp.path,
        gitArgs: ['sh', '-c', 'exit 0'],
        lane: ExecLane.exclusive,
        operation: _descriptor,
        onOperationEvent: events.add,
      );

      expect(events.map((event) => event.phase), [OperationPhase.queued]);
      await Future.wait([first, second]);
      expect(
        events.where((event) => event.phase == OperationPhase.running),
        hasLength(1),
      );
      expect(events.last.phase, OperationPhase.succeeded);
    },
  );

  test('background visibility is omitted from the visible notifier', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final reporter = container.read(operationActivityProvider.notifier);
    final now = DateTime.utc(2026, 1, 1);
    reporter.report(
      OperationEvent(
        id: const OperationId('background'),
        descriptor: const OperationDescriptor(
          repositoryPath: '/repo',
          label: 'Auto-fetch',
          kind: OperationKind.background,
          lane: ExecLane.sync,
          visibility: OperationVisibility.background,
        ),
        phase: OperationPhase.queued,
        occurredAt: now,
      ),
    );
    expect(container.read(operationActivityProvider), isEmpty);
  });
}
