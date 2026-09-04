// Regression test for "Interactive rebase from here…" while a search/grep
// filter is active. The rebase range used to be sliced out of whatever list
// the panel was *displaying* (`_lastCommits`), which is the grep-filtered
// subset when a filter is active — silently dropping any real, non-matching
// commit between the rebase target and HEAD once the rebase replaced history
// with exactly the list it was given. The fix resolves the range from a
// fresh, unfiltered `logProvider` fetch instead.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/history/rebase_sheet.dart';
import 'helpers/fake_snapshot.dart';

/// Returns [full] for an unfiltered `git log` (no grep, not all-branches) and
/// [filtered] otherwise — standing in for how a real `--grep` narrows the
/// result server-side.
class _FilterAwareFakeGit extends GitService with FakeRefsSnapshot {
  _FilterAwareFakeGit({required this.full, required this.filtered})
    : super(SSHCommandExecutor(SSHClientManager()));
  final List<GitCommit> full;
  final List<GitCommit> filtered;

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
    bool fullHistory = false,
  }) async => (grep == null && !all) ? full : filtered;

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  // The history panel prefetches the newest commits' patches whenever the log
  // lands — serve them here rather than letting the prefetch fall through to
  // the real (unconfigured) executor.
  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
}

GitCommit _c(String hash, String subject, {List<String> parents = const []}) =>
    GitCommit(
      hash: hash,
      shortHash: hash.substring(0, 7),
      authorName: 'Dev',
      authorEmail: 'd@e',
      date: '2026-07-04T10:00',
      parents: parents,
      subject: subject,
    );

const _repo = '/srv/repo';

Finder get _actionsMenu => find.byWidgetPredicate(
  (w) => w is MacosIcon && w.icon == CupertinoIcons.line_horizontal_3,
);

void main() {
  testWidgets(
    'rebase-from-here uses the unfiltered log, not the grep-filtered display '
    'list, so a non-matching intermediate commit is never silently dropped',
    (tester) async {
      // Newest-first, as `git log` emits: head -> middle -> target -> (base).
      // `target` needs a non-empty parents list — the rebase-from-here menu
      // item is disabled otherwise (nothing to rebase onto).
      final target = _c(
        't1111112222222',
        'Add feature scaffolding',
        parents: const ['b0000000000000'],
      );
      final middle = _c(
        'm1111112222222',
        'wip internal cleanup', // does NOT match the "feature" grep filter
        parents: [target.hash],
      );
      final head = _c(
        'h1111112222222',
        'Add real feature',
        parents: [middle.hash],
      );
      final full = [head, middle, target];
      // The grep filter for "feature" excludes `middle` (its subject has no
      // "feature" in it) — the exact scenario that used to lose it.
      final filtered = [head, target];

      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(
            _FilterAwareFakeGit(full: full, filtered: filtered),
          ),
          repoWatchProvider.overrideWith(
            (ref, repoPath) => const Stream.empty(),
          ),
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

      // Activate the search filter — the panel now shows `filtered`, missing
      // `middle`.
      await tester.enterText(find.byType(MacosTextField), 'feature');
      await tester.pump(const Duration(milliseconds: 400)); // debounce
      await tester.pumpAndSettle();
      expect(find.text('Add real feature'), findsOneWidget);
      expect(find.text('Add feature scaffolding'), findsOneWidget);
      expect(
        find.text('wip internal cleanup'),
        findsNothing,
        reason: 'middle is filtered out of the displayed list',
      );

      // Select the filtered-but-present `target` commit and rebase from it.
      await tester.tap(find.text('Add feature scaffolding'));
      await tester.pumpAndSettle();
      await tester.tap(_actionsMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Interactive rebase from here…'));
      await tester.pumpAndSettle();

      final sheet = tester.widget<RebaseSheet>(find.byType(RebaseSheet));
      expect(
        sheet.commits.map((c) => c.hash),
        [target.hash, middle.hash, head.hash],
        reason:
            'the rebase range must come from the unfiltered log and must '
            'include `middle`, even though it never appeared in the filtered '
            'display list',
      );
    },
  );
}
