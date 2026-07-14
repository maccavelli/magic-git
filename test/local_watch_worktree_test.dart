// A linked worktree's git state lives OUTSIDE the folder you'd naively watch.
//
// Its `.git` is a file, written once at creation and never again. HEAD, the
// index and the HEAD reflog live in `<main>/.git/worktrees/<id>`; the branches
// it moves live in the shared `<main>/.git/refs` and `packed-refs`. A commit
// made in a linked worktree writes ZERO git metadata inside the worktree
// directory — so a recursive watch of it alone sees the working-tree files
// change and never learns that HEAD moved. The branch list, History and the
// ahead/behind counts would then sit stale until something else happened to
// refresh them.
//
// These run against real git and a real FSEvents watcher, because that is the
// only way to prove the bug is actually gone.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/local_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';

void main() {
  late Directory tmp;
  late String main;
  late String wt;

  Future<void> git_(List<String> args, String cwd) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) {
      fail('git ${args.join(' ')} (in $cwd) failed: ${r.stderr}');
    }
  }

  /// Waits for the first tick satisfying [test], or fails after a timeout.
  /// FSEvents on macOS is asynchronous and coalesced, so waiting for the
  /// condition is the only honest way to assert on it.
  Future<RepoWatchEvent> waitFor(
    Stream<RepoWatchEvent> stream,
    bool Function(RepoWatchEvent) test, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return stream
        .where(test)
        .first
        .timeout(
          timeout,
          onTimeout: () => fail('no matching watch event within $timeout'),
        );
  }

  /// Starts a watcher and waits until it stops reporting anything.
  ///
  /// `setUp` itself does real git work (`init`, `commit`, `worktree add`), and
  /// FSEvents delivers those writes asynchronously — including writes under
  /// `<main>/.git/worktrees/…`, which this watcher now legitimately observes.
  /// Without draining them first, a test asserting on its OWN change can be
  /// handed a tick that is really the tail of the setup, and the assertions
  /// become timing-dependent. Cancel the subscription in a tearDown.
  Future<Stream<RepoWatchEvent>> quietWatcher(String path) async {
    final events = LocalWatchService().watch(path).asBroadcastStream();
    final sub = events.listen(null);
    addTearDown(sub.cancel);

    var lastSeen = DateTime.now();
    final probe = events.listen((_) => lastSeen = DateTime.now());
    // Bounded: under a loaded, parallel test run the machine may never go a full
    // second without an FSEvent, and an unbounded wait would then hang until the
    // 10-minute suite timeout — which is what it did. Settling is an
    // optimisation (it keeps setUp's own churn out of the assertions), not a
    // correctness requirement, so give up after a while and proceed.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().difference(lastSeen) < const Duration(seconds: 1) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await probe.cancel();
    return events;
  }

  setUp(() async {
    final base = await Directory.systemTemp.createTemp('wt_watch_');
    // git realpath's every path it reports; on macOS /var is a symlink to
    // /private/var, so without this the worktree's `.git` file would name a
    // path that never prefix-matches the one we watch.
    tmp = Directory(base.resolveSymbolicLinksSync());
    main = '${tmp.path}/main';
    wt = '${tmp.path}/feature';
    Directory(main).createSync();

    await git_(['init', '-q', '-b', 'main'], main);
    await git_(['config', 'user.email', 't@t'], main);
    await git_(['config', 'user.name', 't'], main);
    await git_(['config', 'commit.gpgsign', 'false'], main);
    File('$main/a.txt').writeAsStringSync('one\n');
    await git_(['add', 'a.txt'], main);
    await git_(['commit', '-q', '-m', 'first'], main);
    await git_(['worktree', 'add', '-q', wt, '-b', 'feature'], main);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a commit made IN the linked worktree is seen as a git-state change',
      () async {
    final events = await quietWatcher(wt);

    // The commit that must be observed. It writes the worktree's HEAD/index
    // under <main>/.git/worktrees/feature, and moves refs/heads/feature under
    // <main>/.git — none of it inside `wt`.
    File('$wt/a.txt').writeAsStringSync('two\n');
    await git_(['add', 'a.txt'], wt);
    await git_(['commit', '-q', '-m', 'from the worktree'], wt);

    final event = await waitFor(events, (e) => e.touchesGitState);

    expect(
      event.touchesGitState,
      isTrue,
      reason: 'without the common-git-dir root this never fires, and the '
          'branch list / History stay stale after a commit',
    );
  });

  test('a branch moved in the MAIN repo is seen from the worktree', () async {
    // Refs are shared. A commit on `main` in the main repo changes a ref that
    // the worktree's own Branches panel is displaying, so it has to refresh.
    final events = await quietWatcher(wt);

    File('$main/a.txt').writeAsStringSync('changed in main\n');
    await git_(['add', 'a.txt'], main);
    await git_(['commit', '-q', '-m', 'from the main repo'], main);

    final event = await waitFor(events, (e) => e.touchesGitState);
    expect(event.touchesGitState, isTrue);
  });

  test('an ordinary working-tree edit is NOT reported as a git-state change',
      () async {
    // The gating in repo_status_view uses touchesGitState to decide between a
    // full repo refresh and a cheap status-only one. A plain file edit must
    // stay on the cheap path — otherwise every keystroke-triggered save would
    // re-walk the log.
    final events = await quietWatcher(wt);

    File('$wt/scratch.txt').writeAsStringSync('just a file\n');

    final event = await waitFor(events, (e) => e.paths.isNotEmpty);
    expect(event.paths, contains('scratch.txt'));
    expect(event.touchesGitState, isFalse);
  });

  test('a worktree of a BARE repo sees git-state changes too', () async {
    // The admin dir of a bare repo's worktree is `<repo>.git/worktrees/<id>` —
    // no `.git` segment anywhere in the path. Classifying by the literal
    // `/.git/worktrees/` marker misses it, the watcher then gets no second
    // root, and a commit made in the worktree (which writes nothing inside the
    // worktree directory) is invisible: branches and History sit stale.
    final bare = '${tmp.path}/bare.git';
    await git_(['clone', '-q', '--bare', main, bare], tmp.path);
    final bareWt = '${tmp.path}/bare-feature';
    await git_(['worktree', 'add', '-q', bareWt, '-b', 'bare-feature'], bare);

    final events = await quietWatcher(bareWt);

    File('$bareWt/a.txt').writeAsStringSync('changed in bare worktree\n');
    await git_(['add', 'a.txt'], bareWt);
    await git_(['commit', '-q', '-m', 'from the bare worktree'], bareWt);

    final event = await waitFor(events, (e) => e.touchesGitState);
    expect(event.touchesGitState, isTrue);
  });

  test('an ordinary repo watches exactly one root, as before', () async {
    // The main worktree's `.git` is already inside the folder, so nothing about
    // its behaviour changes — no second root, no remapping.
    final events = await quietWatcher(main);

    File('$main/a.txt').writeAsStringSync('edited\n');
    await git_(['add', 'a.txt'], main);
    await git_(['commit', '-q', '-m', 'in main'], main);

    final event = await waitFor(events, (e) => e.touchesGitState);
    expect(event.touchesGitState, isTrue);
  });
}
