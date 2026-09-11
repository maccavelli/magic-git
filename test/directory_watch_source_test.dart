// MADR 0045 phase 3. `local_watch_worktree_test.dart`'s five cases, run against
// the source the roots moved into rather than through `LocalWatchService`
// (plan deviation (g): the plan counted three).
//
// A linked worktree's git state lives OUTSIDE the folder you'd naively watch:
// HEAD, the index and the reflog live in `<main>/.git/worktrees/<id>`, and the
// branches it moves in the shared `<main>/.git/refs`. So the source watches the
// common git dir as a second root and remaps its events to `.git/…`.
//
// Real git and a real FSEvents watcher on macOS. Linux's inotify implementation
// in dart:io does not recursively watch pre-existing subdirectories, so the
// common-git-dir changes asserted here are invisible there.
@TestOn('mac-os')
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/source/local/directory_watch_source.dart';
import 'package:remote_magic_git/core/git/watch/source/watch_source.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';

/// Whether [path] is git state, by the same rule every consumer applies.
bool _gitState(String path) => RepoWatchEvent(
  at: DateTime(2026, 9, 10),
  mode: WatchMode.eventDriven,
  paths: {path},
).touchesGitState;

void main() {
  late Directory tmp;
  late String main;
  late String wt;

  Future<void> git(List<String> args, String cwd) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) {
      fail('git ${args.join(' ')} (in $cwd) failed: ${r.stderr}');
    }
  }

  /// Waits for the first reported path satisfying [test], or fails.
  Future<String> waitFor(
    Stream<String> paths,
    bool Function(String) test, {
    Duration timeout = const Duration(seconds: 15),
  }) => paths
      .where(test)
      .first
      .timeout(
        timeout,
        onTimeout: () => fail('no matching path within $timeout'),
      );

  /// Arms the source for [path] and waits until it stops reporting anything.
  ///
  /// `setUp` does real git work, and FSEvents delivers those writes
  /// asynchronously — including under `<main>/.git/worktrees/…`, which this
  /// source legitimately observes. Without draining them first, a test
  /// asserting on its OWN change can be handed the tail of the setup. Bounded,
  /// because a loaded machine may never go a second without an event.
  Future<Stream<String>> quietSource(String path) async {
    final cancelled = Completer<void>();
    final outcome = await DirectoryWatchSource().arm(
      ArmRequest(repoPath: path, cancelled: cancelled.future, attempt: 1),
    );
    expect(outcome, isA<SourceArmed>());
    final armed = (outcome as SourceArmed).source;
    final paths = armed.signals
        .where((signal) => signal is PathChanged)
        .cast<PathChanged>()
        .map((signal) => signal.path)
        .asBroadcastStream();
    final keepAlive = paths.listen(null);
    addTearDown(() async {
      if (!cancelled.isCompleted) cancelled.complete();
      await armed.close();
      await keepAlive.cancel();
    });

    var lastSeen = DateTime.now();
    final probe = paths.listen((_) => lastSeen = DateTime.now());
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().difference(lastSeen) < const Duration(seconds: 1) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await probe.cancel();
    return paths;
  }

  setUp(() async {
    final base = await Directory.systemTemp.createTemp('wt_source_');
    // git realpath's every path it reports; on macOS /var is a symlink to
    // /private/var, so without this the worktree's `.git` file would name a
    // path that never prefix-matches the one watched.
    tmp = Directory(base.resolveSymbolicLinksSync());
    main = '${tmp.path}/main';
    wt = '${tmp.path}/feature';
    Directory(main).createSync();

    await git(['init', '-q', '-b', 'main'], main);
    await git(['config', 'user.email', 't@t'], main);
    await git(['config', 'user.name', 't'], main);
    await git(['config', 'commit.gpgsign', 'false'], main);
    File('$main/a.txt').writeAsStringSync('one\n');
    await git(['add', 'a.txt'], main);
    await git(['commit', '-q', '-m', 'first'], main);
    await git(['worktree', 'add', '-q', wt, '-b', 'feature'], main);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'a commit made IN the linked worktree is seen as a git-state change',
    () async {
      final paths = await quietSource(wt);

      // It writes the worktree's HEAD and index under
      // <main>/.git/worktrees/feature, and moves refs/heads/feature under
      // <main>/.git — none of it inside `wt`.
      File('$wt/a.txt').writeAsStringSync('two\n');
      await git(['add', 'a.txt'], wt);
      await git(['commit', '-q', '-m', 'from the worktree'], wt);

      final path = await waitFor(paths, _gitState);
      expect(
        path,
        startsWith('.git/'),
        reason:
            'without the common-git-dir root this never arrives, and the '
            'branch list and History stay stale after a commit',
      );
    },
  );

  test('a branch moved in the MAIN repo is seen from the worktree', () async {
    // Refs are shared: a commit on `main` changes a ref the worktree's own
    // Branches panel displays.
    final paths = await quietSource(wt);

    File('$main/a.txt').writeAsStringSync('changed in main\n');
    await git(['add', 'a.txt'], main);
    await git(['commit', '-q', '-m', 'from the main repo'], main);

    expect(await waitFor(paths, _gitState), startsWith('.git/'));
  });

  test(
    'an ordinary working-tree edit is NOT reported as a git-state change',
    () async {
      // Refresh gating uses touchesGitState to choose between a full repo
      // refresh and a status-only one; a plain edit must stay on the cheap path.
      final paths = await quietSource(wt);

      File('$wt/scratch.txt').writeAsStringSync('just a file\n');

      final path = await waitFor(paths, (p) => p == 'scratch.txt');
      expect(
        _gitState(path),
        isFalse,
        reason: 'reported repo-relative, and not as git state',
      );
    },
  );

  test('a worktree of a BARE repo sees git-state changes too', () async {
    // A bare repo's worktree admin dir is `<repo>.git/worktrees/<id>` — no
    // `.git` segment anywhere in the path. Classifying by that literal misses
    // it, the source gets no second root, and a commit made in the worktree is
    // invisible.
    final bare = '${tmp.path}/bare.git';
    await git(['clone', '-q', '--bare', main, bare], tmp.path);
    final bareWt = '${tmp.path}/bare-feature';
    await git(['worktree', 'add', '-q', bareWt, '-b', 'bare-feature'], bare);

    final paths = await quietSource(bareWt);

    File('$bareWt/a.txt').writeAsStringSync('changed in bare worktree\n');
    await git(['add', 'a.txt'], bareWt);
    await git(['commit', '-q', '-m', 'from the bare worktree'], bareWt);

    expect(await waitFor(paths, _gitState), startsWith('.git/'));
  });

  test('an ordinary repo watches exactly one root, as before', () async {
    // The main worktree's `.git` is already inside the folder: no second root,
    // no remapping.
    final paths = await quietSource(main);

    File('$main/a.txt').writeAsStringSync('edited\n');
    await git(['add', 'a.txt'], main);
    await git(['commit', '-q', '-m', 'in main'], main);

    expect(await waitFor(paths, _gitState), startsWith('.git/'));
  });
}
