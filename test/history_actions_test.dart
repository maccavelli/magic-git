// The History panel's per-commit actions menu: it appears once a commit is
// selected, and "Amend last commit" is offered only for HEAD (the first log
// row). Uses a fake GitService so no SSH is touched.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';

class _FakeGit extends GitService {
  _FakeGit(this.commits) : super(SSHCommandExecutor(SSHClientManager()));
  final List<GitCommit> commits;

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    bool all = false,
    bool follow = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(String repoPath, String hash, {String? path}) async =>
      'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
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

Future<void> _pump(WidgetTester tester, List<GitCommit> commits) async {
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(_FakeGit(commits))],
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

Finder get _actionsMenu => find.byWidgetPredicate(
  (w) => w is MacosIcon && w.icon == CupertinoIcons.line_horizontal_3,
);

void main() {
  final head = _c('aaaaaaa1111111', 'head commit');
  final older = _c('bbbbbbb2222222', 'old commit');

  testWidgets('no actions menu until a commit is selected', (tester) async {
    await _pump(tester, [head, older]);
    expect(find.text('Select a commit'), findsOneWidget);
    expect(_actionsMenu, findsNothing);
  });

  testWidgets('HEAD commit offers Amend', (tester) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();

    expect(_actionsMenu, findsOneWidget);
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    expect(find.text('Checkout'), findsOneWidget);
    expect(find.text('Cherry-pick'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);
    expect(find.text('Amend last commit'), findsOneWidget);
  });

  testWidgets('non-HEAD commit hides Amend', (tester) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('old commit'));
    await tester.pumpAndSettle();

    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    expect(find.text('Revert'), findsOneWidget);
    expect(find.text('Amend last commit'), findsNothing);
  });

  testWidgets('an active all-branches filter hides Amend on the top row', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    // Turn on the all-branches filter. The displayed top row is still the head
    // commit, but under a filter the shown list isn't `git log HEAD`, so its
    // first row need not be the real HEAD — Amend (which rewrites the actual
    // HEAD) must not be offered.
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is MacosIcon && w.icon == CupertinoIcons.square_stack_3d_up,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();

    expect(find.text('Revert'), findsOneWidget);
    expect(find.text('Amend last commit'), findsNothing);
  });

  testWidgets('the text-prompt sheet is width-capped, not window-filling', (
    tester,
  ) async {
    await _pump(tester, [head, older]);
    await tester.tap(find.text('head commit'));
    await tester.pumpAndSettle();
    await tester.tap(_actionsMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Branch from here…'));
    await tester.pumpAndSettle();

    // The prompt is open and constrained to 440px rather than ballooning to
    // fill the window. Its text field is wrapped by exactly one 440-wide
    // SizedBox (distinct from the always-present history search field).
    final capped = find.ancestor(
      of: find.byType(MacosTextField),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 440),
    );
    expect(capped, findsOneWidget);
  });
}
