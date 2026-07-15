// A diff pane must always, eventually, show a diff. These are the three ways it
// stopped doing that — all of them ending in the same permanent spinner, all of
// them about how a cached diff is told its content went stale.
//
//  1. Stale while nobody was watching (the one users actually hit, and the
//     nastiest). A diff you have looked at is kept alive by KeepAliveLru but is
//     not being watched once you click another file. Anything that edits the
//     file on disk invalidates it in that state — and reopening it then hung
//     forever, because KeepAliveLru.touch closed a KeepAliveLink belonging to a
//     superseded build and took the freshly-rebuilt element down with it.
//
//  2. Refreshed mid-load. `ref.invalidate` is immediate: over a provider holding
//     a value, Riverpod carries the value through and the pane keeps rendering
//     it — fine. But over a provider whose FIRST read has not landed, there is
//     no value to carry, so the read in flight is discarded and the pane
//     restarts from a bare spinner. `RepoStatusView._refresh()` runs after every
//     mutation and on the toolbar's Refresh button, so a mutation landing while
//     a slow diff was still loading killed that load and began it again. The
//     `git diff` behind the discarded read is not cancelled either: it runs to
//     completion unheard, still holding one of the six read slots in
//     CommandLaneScheduler, so its replacement queues behind it.
//
//  3. Refreshed after loading — which must NOT blank the pane. Covered here so
//     that a fix for (2) can't over-correct into a flash of empty on every
//     stage.
//
// The deferred channel — `worktreeEditsProvider.noteFiles/noteRepo`, which moves
// the stamp `_dependOnWorktreeState` watches — is the one safe way to say "this
// went stale": that guard holds a mark arriving mid-fetch until the fetch lands
// and then refetches exactly once. The filesystem watcher already used it. The
// mutation path did not.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';
const _path = 'lib/a.dart';

String _diffOf(String added) =>
    'diff --git a/$_path b/$_path\n'
    'index 111..222 100644\n'
    '--- a/$_path\n'
    '+++ b/$_path\n'
    '@@ -1,2 +1,2 @@\n'
    ' keep\n'
    '-old\n'
    '+$added\n';

/// A git whose `diffFile` can be held open, so a test can act *while a read is
/// in flight* — which is the entire question here. Counts its reads, so a
/// discarded-and-restarted one is visible.
class _SlowGit extends GitService {
  _SlowGit() : super(SSHCommandExecutor(SSHClientManager()));

  /// Every gated read handed out, in order. A test completes them by hand.
  final List<Completer<String>> reads = [];

  /// When false, reads answer immediately with [content] instead of gating.
  bool gate = false;
  String content = _diffOf('new');

  /// Every read, gated or not — so a discarded-and-reissued one is visible.
  int readCount = 0;

  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    bool staged = false,
    bool ignoreWhitespace = false,
    int? context,
  }) {
    readCount++;
    if (!gate) return Future.value(content);
    final c = Completer<String>();
    reads.add(c);
    return c.future;
  }
}

class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Future<ProviderContainer> _pump(WidgetTester tester, _SlowGit git) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      // A fixed status: this test is about the diff cache's own staleness
      // plumbing, so the file's status record must not move underneath it and
      // trigger a refetch of its own.
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(),
          files: const [GitFileStatus(path: _path, statusX: '.', statusY: 'M')],
        ),
      ),
      pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
      repoWatchProvider(
        _repo,
      ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
      fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
      refsProvider(_repo).overrideWith((ref) async => const []),
      // Sibling of the refs override: the views now read CONFIGURED
      // remotes (remotesProvider), not remote-tracking refs.
      remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: RepoStatusView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('a diff marked stale while nothing is watching it still loads when '
      'reopened', () async {
    // The bug the whole file is really about, and the one a user actually hits:
    //
    //   open file A's diff  →  click file B  →  anything touches A on disk (a
    //   build, a formatter, an editor autosave; the watcher marks it stale and
    //   invalidates it while nothing is watching)  →  click back to A.
    //
    // A's pane came back as a spinner and stayed one, forever.
    //
    // Cause was in KeepAliveLru.touch: it CLOSED the KeepAliveLink it was
    // replacing. A link is bound to the build that created it, and touch only
    // runs from a build — so the link being replaced is always a superseded
    // one, already void. Closing it ran Riverpod's disposal bookkeeping against
    // the dead build and took the fresh element down with it; the `git diff`
    // in flight then landed on a disposed element and its value was never
    // published. AsyncLoading, forever.
    //
    // No widgets here on purpose: this is a provider-lifecycle invariant, and
    // it should fail loudly at that level rather than only as a spinning pane.
    final git = _SlowGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        statusProvider(_repo).overrideWith(
          (ref) async => GitStatus(
            branch: const GitBranchInfo(),
            files: const [
              GitFileStatus(path: _path, statusX: '.', statusY: 'M'),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    const key = (_repo, _path, false, false, 3);

    // Open it, then look away. The LRU keeps it pinned.
    var sub = container.listen(fileDiffProvider(key), (_, _) {});
    expect(await container.read(fileDiffProvider(key).future), _diffOf('new'));
    sub.close();
    await Future<void>.delayed(Duration.zero);

    git.readCount = 0;

    // Something edits the file while we aren't looking at it. The wait is not
    // decoration: Riverpod tears the unwatched element down on a scheduler pass,
    // and it is precisely that teardown-then-rebuild that the stale link
    // corrupted. Re-listen in the same microtask and the element never goes
    // away, so the bug cannot show — which is exactly how it hides.
    git.content = _diffOf('edited');
    container.read(worktreeEditsProvider.notifier).noteFiles(_repo, [_path]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Come back to it — and then read the state the way the PANE does: whatever
    // AsyncValue the provider is publishing. (Awaiting `.future` here would hide
    // the bug: that issues a fresh read of its own, which rebuilds the element
    // cleanly and answers, while the element the pane is actually watching stays
    // wedged in AsyncLoading behind it.)
    sub = container.listen(fileDiffProvider(key), (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(fileDiffProvider(key));
    expect(
      state.hasValue,
      isTrue,
      reason: 'the pane is watching this provider and it has published nothing '
          '— it renders a spinner, and never stops: the read it is waiting on '
          'landed on an element that had already been disposed',
    );
    expect(
      state.value,
      _diffOf('edited'),
      reason: 'and it must be the file as it is NOW, not as it was when it '
          'went off screen',
    );
    expect(
      git.readCount,
      lessThanOrEqualTo(1),
      reason: 'exactly one re-read: the thrashing dispose/rebuild loop this '
          'caused issued several, each landing nowhere',
    );
  });

  testWidgets('a refresh keeps a diff that has already loaded on screen', (
    tester,
  ) async {
    // The easy half, and it already worked: `when()` defaults to
    // skipLoadingOnRefresh, so a refresh over a settled value shows the value.
    final git = _SlowGit();
    final container = await _pump(tester, git);

    await tester.tap(find.text(_path));
    await tester.pumpAndSettle();
    expect(find.text('+new'), findsOneWidget, reason: 'sanity: the diff loaded');

    git.gate = true;
    container.invalidate(fileDiffProvider((_repo, _path, false, false, 3)));
    await tester.pump();

    expect(
      find.byType(ProgressCircle),
      findsNothing,
      reason: 'the previous diff is still the best thing to show',
    );
    expect(find.text('+new'), findsOneWidget);
  });

  testWidgets('a refresh during the FIRST load does not throw that load away', (
    tester,
  ) async {
    // The hard half, and the actual bug. Nothing has landed for this key yet,
    // so there is no previous value to carry — an invalidate here discards the
    // read in flight and starts again from a bare spinner. Refresh at any
    // cadence (hammer the button; stage hunk after hunk; a mutation while a
    // slow SSH diff is still loading) and the pane never gets to show anything.
    final git = _SlowGit()..gate = true;
    await _pump(tester, git);

    await tester.tap(find.text(_path));
    await tester.pump();
    expect(git.readCount, 1, reason: 'sanity: the first read is in flight');
    expect(find.byType(ProgressCircle), findsOneWidget);

    // Exactly what every mutation does in its `finally`, and what the toolbar's
    // Refresh button does on its own.
    await tester.tap(_byMacosTooltip('Refresh'));
    await tester.pump();

    expect(
      git.readCount,
      1,
      reason: 'the read already in flight is reading the very worktree this '
          'refresh is about — restarting it wastes the read (and the git '
          'command behind it is not cancelled: it runs to completion holding a '
          'read slot) and puts the pane back to a bare spinner',
    );

    // The in-flight read lands, and the pane shows it rather than spinning on
    // a replacement for it.
    git.reads.first.complete(_diffOf('new'));
    await tester.pumpAndSettle();

    expect(find.byType(ProgressCircle), findsNothing);
    expect(find.text('+new'), findsOneWidget);
  });
}
