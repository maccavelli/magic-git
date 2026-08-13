import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/exec/command_lanes.dart';
import 'package:remote_magic_git/core/exec/operation_activity.dart';
import 'package:remote_magic_git/features/common/activity_center.dart';

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
}
