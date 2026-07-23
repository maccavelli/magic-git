// Mouse-kind drag coverage against the REAL HistoryView: every other drag test
// uses the default touch pointer, but the shipped app is macOS-only — a MOUSE
// is the only pointer it ever sees. Pins that a mouse click-drag on a commit
// row and on a branch chip actually starts the drag (ghost in the overlay).

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGit extends GitService {
  _FakeGit(this.commits, this.refList)
    : super(SSHCommandExecutor(SSHClientManager()));
  final List<GitCommit> commits;
  final List<GitRef> refList;

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => refList;
}

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

const _repo = '/srv/repo';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final head = _c('aaaaaaa1111111', 'head commit');
  final older = _c('bbbbbbb2222222', 'old commit');
  final git = _FakeGit(
    [head, older],
    [
      GitRef(name: 'refs/heads/main', oid: head.hash, isHead: true, subject: 's'),
      GitRef(
        name: 'refs/heads/feature',
        oid: older.hash,
        isHead: false,
        subject: 's',
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: HistoryView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mouse-dragging a commit row starts a drag (ghost appears)', (
    tester,
  ) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('old commit')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    // The canonical lift cell (carrying the row's snapshot) is under the
    // pointer.
    expect(
      find.byType(LiftedDragCell),
      findsOneWidget,
      reason: 'a mouse drag on a commit row must start and lift the cell',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('mouse-dragging a branch chip starts a drag', (tester) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('feature')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    expect(
      find.byType(LiftedDragCell),
      findsOneWidget,
      reason: 'a mouse drag on a branch chip must start and lift the cell',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
