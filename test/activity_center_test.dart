import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/exec/command_lanes.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';
import 'package:remote_magic_git/features/common/activity_center.dart';

OperationEvent _event(
  String id,
  OperationPhase phase, {
  bool undoable = false,
}) => OperationEvent(
  id: OperationId(id),
  descriptor: OperationDescriptor(
    repositoryPath: '/repo',
    label: 'Operation $id',
    kind: OperationKind.synchronization,
    lane: ExecLane.sync,
  ),
  phase: phase,
  occurredAt: DateTime.utc(2026, 1, 1),
  undoable: undoable,
);

void main() {
  testWidgets('activity list explains empty state', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        theme: MacosThemeData.dark(),
        home: const ActivityCenterList(records: []),
      ),
    );
    expect(find.text('No repository operations yet.'), findsOneWidget);
  });

  testWidgets('activity row presents a safe label and phase', (tester) async {
    final now = DateTime.utc(2026, 1, 1);
    final record = OperationRecord(
      id: const OperationId('op'),
      descriptor: const OperationDescriptor(
        repositoryPath: '/repo',
        label: 'Push branch',
        kind: OperationKind.synchronization,
        lane: ExecLane.sync,
      ),
      phase: OperationPhase.running,
      queuedAt: now,
      startedAt: now,
    );
    await tester.pumpWidget(
      MacosApp(
        theme: MacosThemeData.dark(),
        home: ActivityCenterList(records: [record]),
      ),
    );
    expect(find.text('Push branch'), findsOneWidget);
    expect(find.textContaining('Running ·'), findsOneWidget);
    expect(find.textContaining('/repo'), findsOneWidget);
  });

  // 0009 M3: the sheet is LIVE (it watches the provider, not a tap-time
  // snapshot) and Escape dismisses it.
  testWidgets('the open sheet updates as operations land, and Escape closes',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(operationActivityProvider.notifier)
        .report(_event('fetch', OperationPhase.queued));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          home: Center(child: ActivityCenterButton(repositoryPath: '/repo')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ActivityCenterButton));
    await tester.pumpAndSettle();
    expect(find.text('Operation fetch'), findsOneWidget);

    // A new operation lands while the sheet is open — it must appear.
    container
        .read(operationActivityProvider.notifier)
        .report(_event('push', OperationPhase.queued));
    await tester.pumpAndSettle();
    expect(find.text('Operation push'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Operation push'), findsNothing);
  });

  // Only the NEWEST undoable record may offer Undo — the journal is a stack,
  // so an older row's Undo would be a lying button.
  testWidgets('Undo is offered only on the newest undoable record', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(operationActivityProvider.notifier);
    notifier.report(_event('older', OperationPhase.queued, undoable: true));
    notifier.report(_event('newer', OperationPhase.queued, undoable: true));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          home: Center(child: ActivityCenterButton(repositoryPath: '/repo')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ActivityCenterButton));
    await tester.pumpAndSettle();

    expect(find.text('Operation newer'), findsOneWidget);
    expect(find.text('Operation older'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });
}
