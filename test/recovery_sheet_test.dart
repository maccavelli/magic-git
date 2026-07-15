// The Recovery sheet: reflog + snapshot listing, selection driving the diff
// preview and restore actions, and empty states. Data providers are
// overridden directly — the sheet's service round trips are covered by
// undo_scripts_test.dart against real git.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';
import 'package:remote_magic_git/features/recovery/recovery_sheet.dart';

class _StubConnection extends ConnectionController {
  @override
  ConnectionState build() => const ConnectionState(
    phase: ConnectionPhase.connected,
    repoPath: '/repo',
    host: 'h',
  );
}

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));

  final branched = <(String name, String startPoint)>[];

  @override
  Future<void> branchFrom(
    String repoPath,
    String name,
    String startPoint, {
    bool checkout = true,
  }) async {
    branched.add((name, startPoint));
  }
}

const _entries = [
  ReflogEntry(
    hash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    shortHash: 'aaaaaaa',
    selector: 'HEAD@{5 minutes ago}',
    action: 'commit',
    detail: 'add feature',
    subject: 'add feature',
  ),
  ReflogEntry(
    hash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    shortHash: 'bbbbbbb',
    selector: 'HEAD@{2 hours ago}',
    action: 'checkout',
    detail: 'moving from main to feature',
    subject: 'base commit',
  ),
];

const _snapshots = [
  SnapshotRef(
    refName: 'refs/magic-git/snapshots/1751000000-1',
    oid: 'cccccccccccccccccccccccccccccccccccccccc',
    subject: 'magic-git snapshot',
    relativeDate: '2 hours ago',
  ),
];

const _diff = '''
diff --git a/a.txt b/a.txt
index 0000000..1111111 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-old line
+new line
''';

Future<void> pump(
  WidgetTester tester, {
  List<ReflogEntry> entries = _entries,
  List<SnapshotRef> snapshots = _snapshots,
  GitService? git,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (git != null) gitServiceProvider.overrideWithValue(git),
        connectionProvider.overrideWith(_StubConnection.new),
        reflogProvider.overrideWith((ref, repoPath) async => entries),
        magicSnapshotsProvider.overrideWith((ref, repoPath) async => snapshots),
        refsProvider.overrideWith((ref, repoPath) async => const <GitRef>[]),
        commitDiffProvider.overrideWith((ref, key) async => _diff),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: RecoverySheet(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists reflog entries and snapshots in sections', (tester) async {
    await pump(tester);

    expect(find.text('REFLOG'), findsOneWidget);
    expect(find.text('SNAPSHOTS'), findsOneWidget);
    expect(find.text('add feature'), findsOneWidget);
    expect(find.text('moving from main to feature'), findsOneWidget);
    expect(find.text('commit'), findsOneWidget, reason: 'action chip');
    expect(find.textContaining('aaaaaaa · HEAD@{5 minutes ago}'),
        findsOneWidget);
    expect(find.text('Deleted untracked files'), findsOneWidget,
        reason: 'flavor-B snapshots get a friendly label');
    expect(find.text('2 hours ago'), findsOneWidget);
  });

  testWidgets('selecting a reflog entry shows the diff and restore actions', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Select a reflog entry or snapshot'), findsOneWidget);

    await tester.tap(find.text('add feature'));
    await tester.pumpAndSettle();

    expect(find.byType(DiffView), findsOneWidget);
    expect(find.text('Restore…'), findsOneWidget);
    expect(find.text('aaaaaaaaaa'), findsOneWidget,
        reason: 'detail header shows the short hash prefix');
  });

  testWidgets('Create branch here… prompts for a name, creates the branch at '
      'the selected hash, and the prompt closes cleanly', (tester) async {
    final git = _FakeGit();
    await pump(tester, git: git);

    await tester.tap(find.text('add feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create branch here…'));
    await tester.pumpAndSettle();

    expect(find.text('New branch from this state'), findsOneWidget);
    await tester.enterText(find.byType(MacosTextField), 'rescue/feature');
    await tester.tap(find.widgetWithText(PushButton, 'Create'));
    // Settle fully: the prompt's exit animation runs with the text field
    // still holding its (widget-owned) controller — this is where a
    // caller-disposed controller used to be a landmine.
    await tester.pumpAndSettle();

    expect(git.branched, [
      ('rescue/feature', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
    ]);
    expect(find.text('New branch from this state'), findsNothing);
  });

  testWidgets('cancelling the branch prompt creates nothing', (tester) async {
    final git = _FakeGit();
    await pump(tester, git: git);

    await tester.tap(find.text('add feature'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create branch here…'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(PushButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(git.branched, isEmpty);
    expect(find.text('New branch from this state'), findsNothing);
  });

  testWidgets('selecting a snapshot shows snapshot actions', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Deleted untracked files'));
    await tester.pumpAndSettle();

    expect(find.text('Actions'), findsOneWidget);
    expect(find.text('Snapshot of deleted untracked files'), findsOneWidget);
    expect(find.byType(DiffView), findsOneWidget);
  });

  testWidgets('empty reflog and snapshots render their empty states', (
    tester,
  ) async {
    await pump(tester, entries: const [], snapshots: const []);

    expect(find.text('No reflog entries yet.'), findsOneWidget);
    expect(
      find.textContaining('One is taken automatically'),
      findsOneWidget,
    );
  });
}
