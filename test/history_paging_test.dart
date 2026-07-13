// The History panel's depth: it walks one page at a time, deepening when the
// list is scrolled to its end, and stops asking once git returns fewer commits
// than it walked for. Also the one client-side filter term (`sha:`), which
// narrows the loaded rows without changing what git was asked for.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A git whose log honors `maxCount` against a synthetic history, and records
/// how deep each walk was asked to go.
class _PagingGit extends GitService {
  _PagingGit(this.total) : super(SSHCommandExecutor(SSHClientManager()));

  /// How many commits this repo has in total.
  final int total;

  /// The `maxCount` of every log call, in order — the paging trail.
  final List<int> walks = [];
  final List<String?> greps = [];

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
    bool noMerges = false,
  }) async {
    walks.add(maxCount);
    greps.add(grep);
    final count = maxCount < total ? maxCount : total;
    // 40-char hashes that differ in their LEADING characters (`c007ffff…`),
    // so a `sha:` prefix can single one out — real hashes are distinctive up
    // front, and a prefix match is only meaningful against that.
    String hashOf(int i) => 'c${i.toString().padLeft(3, '0')}'.padRight(40, 'f');
    return [
      for (var i = 0; i < count; i++)
        GitCommit(
          hash: hashOf(i),
          shortHash: hashOf(i).substring(0, 7),
          authorName: 'Dev',
          authorEmail: 'd@e',
          date: '2026-07-04T10:00',
          parents: i + 1 < count ? [hashOf(i + 1)] : [],
          subject: 'commit $i',
        ),
    ];
  }

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  /// The panel prefetches the newest few commits' patches; without this the
  /// real implementation would reach for the (absent) SSH executor.
  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async =>
      'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';
}

Future<void> _pump(WidgetTester tester, _PagingGit git) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: HistoryView(repoPath: '/srv/repo'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _listController(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

void main() {
  testWidgets('the first load walks exactly one page, however deep the repo', (
    tester,
  ) async {
    final git = _PagingGit(kHistoryPageSize * 3);
    await _pump(tester, git);
    expect(git.walks, [kHistoryPageSize]);
  });

  testWidgets('scrolling to the end walks deeper, then stops when exhausted', (
    tester,
  ) async {
    // 700 commits: page one (500) leaves more to walk; page two (1000) runs
    // out at 700 and ends the paging.
    final git = _PagingGit(700);
    await _pump(tester, git);
    expect(git.walks, [kHistoryPageSize], reason: 'one page on first load');

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump(); // builds the trailing sentinel → asks for more
    await tester.pumpAndSettle(); // the deeper walk lands

    expect(
      git.walks,
      [kHistoryPageSize, kHistoryPageSize * 2],
      reason: 'reaching the end deepens the walk by one page',
    );

    // 700 < 1000 asked for: the history ran out, so there is no sentinel left
    // to trigger a third walk however far the list is scrolled.
    final deeper = _listController(tester);
    deeper.jumpTo(deeper.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      git.walks,
      [kHistoryPageSize, kHistoryPageSize * 2],
      reason: 'an exhausted history is never re-walked',
    );
  });

  testWidgets('a short history is exhausted immediately', (tester) async {
    final git = _PagingGit(3);
    await _pump(tester, git);

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(git.walks, [kHistoryPageSize], reason: 'nothing deeper to ask for');
    expect(find.text('commit 0'), findsOneWidget);
    expect(find.text('commit 2'), findsOneWidget);
  });

  testWidgets('sha: narrows the loaded rows without re-asking git', (
    tester,
  ) async {
    final git = _PagingGit(12);
    await _pump(tester, git);
    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('commit 2'), findsOneWidget);

    await tester.enterText(find.byType(MacosTextField).first, 'sha:c001');
    await tester.pump(const Duration(milliseconds: 400)); // filter debounce
    await tester.pumpAndSettle();

    // `c001…` is commit 1's hash and no other's — commit 2's row is gone, and
    // git was never asked to grep.
    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('commit 2'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    expect(
      git.greps,
      everyElement(isNull),
      reason: 'sha: is matched client-side; git has no hash-prefix flag',
    );
  });
}
