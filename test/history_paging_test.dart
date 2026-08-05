// The History panel's depth: it walks one page at a time, deepening when the
// list is scrolled to its end, and stops asking once git returns fewer commits
// than it walked for. Also `sha:`, which — like every other term — is a
// criterion git applies, not a pass over the rows already on screen.

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

/// One `git log` the panel asked for: the window it wanted out of the walk.
typedef _Walk = ({int skip, int count});

/// A git whose log honors `skip`/`maxCount` against a synthetic history, and
/// records the window of every walk — so a test can tell a *page* fetch from a
/// re-walk of the whole prefix.
class _PagingGit extends GitService {
  _PagingGit(this.total) : super(SSHCommandExecutor(SSHClientManager()));

  /// How many commits this repo has in total.
  int total;

  /// The window of every log call, in order — the paging trail.
  final List<_Walk> walks = [];
  final List<String?> greps = [];
  final List<String?> shas = [];

  /// When set, the next walk throws (one transient SSH failure) and the flag
  /// clears — the shape of a single dropped page fetch.
  bool failNextWalk = false;

  // 40-char hashes that differ in their LEADING characters (`c007ffff…`), so a
  // `sha:` prefix can single one out — real hashes are distinctive up front, and
  // a prefix match is only meaningful against that.
  static String hashOf(int i) =>
      'c${i.toString().padLeft(3, '0')}'.padRight(40, 'f');

  GitCommit _commitAt(int i) => GitCommit(
    hash: hashOf(i),
    shortHash: hashOf(i).substring(0, 7),
    authorName: 'Dev',
    authorEmail: 'd@e',
    date: '2026-07-04T10:00',
    parents: i + 1 < total ? [hashOf(i + 1)] : [],
    subject: 'commit $i',
  );

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
  }) async {
    walks.add((skip: skip, count: maxCount));
    greps.add(grep);
    shas.add(sha);
    if (failNextWalk) {
      failNextWalk = false;
      throw StateError('transport hiccup');
    }

    // Git resolves a `sha:` against the object database and answers with the
    // commit itself, so the result is what the hash *matched* — not a page of
    // history that then gets narrowed. Depth is irrelevant to it.
    if (sha != null) {
      return [
        for (var i = 0; i < total; i++)
          if (hashOf(i).startsWith(sha.toLowerCase())) _commitAt(i),
      ];
    }

    // `--skip` drops the first N of the same walk before `--max-count` counts.
    final start = skip < total ? skip : total;
    final end = (start + maxCount) < total ? (start + maxCount) : total;
    return [for (var i = start; i < end; i++) _commitAt(i)];
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

/// The key the panel builds with no filters typed — the unfiltered HEAD walk.
const LogQuery _defaultQuery = (
  repoPath: '/srv/repo',
  grep: null,
  author: null,
  since: null,
  until: null,
  path: null,
  sha: null,
  noMerges: false,
  all: true,
    revision: null,
);

Future<ProviderContainer> _pump(WidgetTester tester, _PagingGit git) async {
  SharedPreferences.setMockInitialValues({});
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
        home: HistoryView(repoPath: '/srv/repo'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

ScrollController _listController(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

void main() {
  const page = kHistoryPageSize;

  testWidgets('the first load walks exactly one page, however deep the repo', (
    tester,
  ) async {
    final git = _PagingGit(page * 3);
    await _pump(tester, git);
    expect(git.walks, [(skip: 0, count: page)]);
  });

  testWidgets('scrolling to the end fetches ONLY the next page', (tester) async {
    // The regression this pins: paging used to be expressed as a bigger
    // `--max-count` on a new provider key, so page two re-walked, re-sent and
    // re-parsed the 500 commits already on screen to show 500 more — quadratic
    // in the scroll depth, and on the SSH backend it re-sent every one of those
    // commits over the wire. A page must cost a page.
    //
    // 700 commits: page one (500) leaves more; page two asks for 500 from 500,
    // gets 200, and that short page is what ends the paging.
    final git = _PagingGit(700);
    final container = await _pump(tester, git);
    expect(
      git.walks,
      [(skip: 0, count: page)],
      reason: 'one page on first load',
    );

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump(); // builds the trailing sentinel → asks for more
    await tester.pumpAndSettle(); // the page lands

    expect(
      git.walks,
      [(skip: 0, count: page), (skip: page, count: page)],
      reason: 'the second walk skips past what is already held and asks for '
          'one page — not 1000 commits from the top',
    );
    // …and the page is stitched onto the list, not swapped in for it.
    final commits = container.read(logSearchProvider(_defaultQuery)).value!;
    expect(commits, hasLength(700));
    expect(commits.first.subject, 'commit 0');
    expect(commits.last.subject, 'commit 699');

    // 200 < 500 asked for: the history ran out, so there is no sentinel left to
    // trigger a third walk however far the list is scrolled.
    final deeper = _listController(tester);
    deeper.jumpTo(deeper.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      git.walks,
      [(skip: 0, count: page), (skip: page, count: page)],
      reason: 'an exhausted history is never re-walked',
    );
  });

  testWidgets('a refresh re-walks the whole displayed prefix in ONE call', (
    tester,
  ) async {
    // Paging incrementally must not turn a refresh into a page-by-page restitch:
    // a commit landing while the user is scrolled deep would then cost one round
    // trip per page, and every page boundary would be a chance to duplicate or
    // drop a row. So a refresh is still a single atomic walk of everything on
    // screen — and the depth the user paged to survives it, rather than the list
    // snapping back to one page under them.
    final git = _PagingGit(page * 3);
    final container = await _pump(tester, git);

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(git.walks.length, 2, reason: 'paged down to 1000');

    git.walks.clear();
    // Exactly what a commit/checkout/⌘R does — see repoMutationFamilies.
    container.invalidate(logSearchProvider);
    await tester.pumpAndSettle();

    expect(
      git.walks,
      [(skip: 0, count: page * 2)],
      reason: 'one walk, from the top, as deep as the user had paged',
    );
    final commits = container.read(logSearchProvider(_defaultQuery)).value!;
    expect(
      commits,
      hasLength(page * 2),
      reason: 'the depth the user paged to survives the refresh — the list does '
          'not snap back to one page under them',
    );
  });

  testWidgets('a commit landing between pages cannot duplicate a row', (
    tester,
  ) async {
    // `--skip=N` is an offset into a walk git re-runs, so a commit arriving
    // between two pages shifts the window down by one and the next page repeats
    // the last row already held. A duplicate hash means duplicate widget keys
    // and a corrupt graph, so the append dedupes.
    final git = _PagingGit(700);
    final container = await _pump(tester, git);

    // A new commit lands on top: every index shifts by one, so `skip: 500` now
    // points at the commit currently held as row 499.
    git.total = 701;

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pumpAndSettle();

    final commits = container.read(logSearchProvider(_defaultQuery)).value!;
    final hashes = [for (final c in commits) c.hash];
    expect(
      hashes.toSet().length,
      hashes.length,
      reason: 'the row at the page seam is held once, not twice',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short history is exhausted immediately', (tester) async {
    final git = _PagingGit(3);
    await _pump(tester, git);

    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(
      git.walks,
      [(skip: 0, count: page)],
      reason: 'nothing deeper to ask for',
    );
    expect(find.text('commit 0'), findsOneWidget);
    expect(find.text('commit 2'), findsOneWidget);
  });

  testWidgets('sha: is a term git applies, and it singles out the commit', (
    tester,
  ) async {
    final git = _PagingGit(12);
    await _pump(tester, git);
    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('commit 2'), findsOneWidget);

    await tester.enterText(find.byType(MacosTextField).first, 'sha:c001');
    await tester.pump(const Duration(milliseconds: 400)); // filter debounce
    await tester.pumpAndSettle();

    // `c001…` is commit 1's hash and no other's.
    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('commit 2'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    // It reached git rather than being applied to the rows on screen — which
    // is what lets it find a commit this walk never loaded (a hash on another
    // branch, or one page-depths further back).
    expect(git.shas, contains('c001'));
    expect(git.greps, everyElement(isNull));
  });

  testWidgets('a BARE hash prefix finds its commit without the sha: key', (
    tester,
  ) async {
    // Pasting a hash into the search box means "find this commit" — nobody
    // spells it `sha:`-first. The old pipeline read it as message text, so
    // five characters of a real hash found nothing: the original "search is
    // completely broken" report.
    final git = _PagingGit(12);
    await _pump(tester, git);

    await tester.enterText(find.byType(MacosTextField).first, 'c001f');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('commit 2'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    expect(git.shas, contains('c001f'));
  });

  testWidgets('a hex-shaped WORD still searches messages', (tester) async {
    // 'added' is five hex digits, but no commit hash here bears it — the
    // object database says so, and the term falls through to the ordinary
    // message search instead of shadowing it with an empty result.
    final git = _PagingGit(12);
    await _pump(tester, git);

    await tester.enterText(find.byType(MacosTextField).first, 'added');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(git.shas, contains('added'), reason: 'the hash reading was tried');
    expect(git.greps, contains('added'), reason: 'and fell back to message');
    // The fake applies no grep narrowing, so the full page proves the walk ran.
    expect(find.text('commit 1'), findsOneWidget);
  });

  testWidgets('a failed page renders a retry row, and clicking it pages on', (
    tester,
  ) async {
    // The regression this pins: pageFailed latched on the notifier with no way
    // back — one transient SSH failure ended paging for that query forever
    // (and the sentinel kept spinning over a fetch that would never run).
    final git = _PagingGit(page * 2);
    final container = await _pump(tester, git);

    git.failNextWalk = true;
    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pumpAndSettle();

    const retryLabel = 'Couldn\'t load more commits — click to retry';
    expect(
      find.text(retryLabel),
      findsOneWidget,
      reason: 'a failed page must say so, not spin forever over nothing',
    );

    await tester.tap(find.text(retryLabel));
    await tester.pumpAndSettle();

    expect(
      container.read(logSearchProvider(_defaultQuery)).value,
      hasLength(page * 2),
      reason: 'the retried page lands on top of the rows already held',
    );
    expect(find.text(retryLabel), findsNothing);
  });

  testWidgets('a refresh clears a failed page — paging resumes on its own', (
    tester,
  ) async {
    final git = _PagingGit(page * 2);
    final container = await _pump(tester, git);

    git.failNextWalk = true;
    final controller = _listController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load more commits — click to retry'),
        findsOneWidget);

    // Exactly what a commit/checkout/watcher tick does. The rebuild re-walks
    // from the top AND un-latches paging.
    container.invalidate(logSearchProvider);
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t load more commits — click to retry'),
        findsNothing);
    // The sentinel is live again: sitting at the end of the list, it pages.
    expect(
      container.read(logSearchProvider(_defaultQuery)).value,
      hasLength(page * 2),
      reason: 'paging resumed after the refresh instead of staying dead',
    );
  });

  testWidgets('a sha: match in a deep repo does not stampede the walk', (
    tester,
  ) async {
    // The regression: `sha:` used to narrow the *fetched* page, so "exhausted"
    // was judged on the page (a full 500 → more to come) while the list showed
    // the single row that survived. The load-more sentinel therefore sat right
    // under that row — permanently on screen, re-arming itself every frame —
    // and walked the entire repository a page at a time.
    final git = _PagingGit(kHistoryPageSize * 4);
    await _pump(tester, git);
    final walksBefore = git.walks.length;

    await tester.enterText(find.byType(MacosTextField).first, 'sha:c001');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('commit 1'), findsOneWidget);
    expect(find.text('1 matching commit'), findsOneWidget);
    // One walk for the sha query, and it stops there: the row count is what the
    // query matched, so the list knows it is complete.
    expect(git.walks.length, walksBefore + 1);
    expect(git.walks.last, (skip: 0, count: page));
  });
}
