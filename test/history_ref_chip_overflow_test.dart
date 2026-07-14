// Ref chips must never spill past the right edge of the commit-list pane.
//
// The pane is a fixed 420px, and the commit list has a FIXED row height
// (`itemExtent`) — the graph painter draws lane edges that have to line up
// between adjacent rows, and the minimap maps commits to y-positions assuming
// uniform rows. So chips cannot wrap onto a second line; they must fit on one.
//
// The bug: the chips were intrinsically-sized children of a Row, sitting beside
// an `Expanded` subject. Once their combined natural width exceeded the pane,
// the subject collapsed to zero and the surplus had nowhere to go — the chips
// painted straight out past the margin.
//
// Worktrees are what surfaced it: every branch checked out in another worktree
// now carries a chip of its own, so a commit routinely has several.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/history/ref_chip.dart';

const _repo = '/repo';

/// A 40-char hex hash; `'a' * 40` is not a const expression.
const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const _commit = GitCommit(
  hash: _hash,
  shortHash: 'aaaaaaa',
  authorName: 'Test',
  authorEmail: 't@t',
  date: '2026-07-14T10:00:00Z',
  parents: [],
  subject: 'the subject must stay readable',
);

/// The pathological case: one commit that is the tip of many refs, several with
/// long names. Exactly what a repo full of worktrees produces.
List<GitRef> _manyRefs() => [
  const GitRef(
    name: 'refs/heads/main',
    oid: _hash,
    isHead: true,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/heads/feature/some-really-long-branch-name-here',
    oid: _hash,
    isHead: false,
    subject: 's',
    worktreePath: '/wt/a',
  ),
  const GitRef(
    name: 'refs/heads/hotfix/another-extremely-long-branch-name',
    oid: _hash,
    isHead: false,
    subject: 's',
    worktreePath: '/wt/b',
  ),
  const GitRef(
    name: 'refs/remotes/origin/feature/some-really-long-branch-name-here',
    oid: _hash,
    isHead: false,
    subject: 's',
  ),
  const GitRef(
    name: 'refs/tags/v1.0.0-release-candidate-4',
    oid: _hash,
    isHead: false,
    subject: 's',
  ),
];

class _FakeGit extends GitService {
  _FakeGit(this._refs) : super(SSHCommandExecutor(SSHClientManager()));

  final List<GitRef> _refs;

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
  }) async => skip > 0 ? const [] : const [_commit];

  @override
  Future<List<GitRef>> refs(String repoPath) async => _refs;
}

Future<void> pump(WidgetTester tester, List<GitRef> refs) async {
  // A normal desktop window. The commit pane inside History is a fixed 420px
  // regardless — which is the width the chips have to live within.
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(_FakeGit(refs))],
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
  // HistoryView arms a short debounce timer. A bare Timer schedules no frames,
  // so pumpAndSettle does not advance it, and it would still be pending when the
  // tree is torn down — which the test binding reports as a failure. Let it fire.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('many long ref chips do not overflow the commit pane', (
    tester,
  ) async {
    await pump(tester, _manyRefs());

    // A RenderFlex overflow is reported as a test exception, so this fails
    // loudly on the regression rather than merely looking wrong.
    expect(tester.takeException(), isNull);

    // The subject is not squeezed out of existence by the chips.
    expect(find.text('the subject must stay readable'), findsOneWidget);
  });

  testWidgets('past three refs, the rest collapse into a +N chip', (
    tester,
  ) async {
    await pump(tester, _manyRefs());

    // Five refs -> three chips + "+2". Without the cap, a commit that is the tip
    // of a dozen refs would leave no room for the subject at all.
    expect(find.text('+2'), findsOneWidget);
    expect(find.byType(RefChip), findsNWidgets(RefChipStrip.maxVisible));
  });

  testWidgets('a commit with a single short ref still shows it plainly', (
    tester,
  ) async {
    await pump(tester, [
      const GitRef(
        name: 'refs/heads/main',
        oid: _hash,
        isHead: true,
        subject: 's',
      ),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.byType(RefChip), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('a commit with no refs gives the subject the whole row', (
    tester,
  ) async {
    await pump(tester, const []);

    expect(tester.takeException(), isNull);
    expect(find.byType(RefChip), findsNothing);
    expect(find.text('the subject must stay readable'), findsOneWidget);
  });
}
