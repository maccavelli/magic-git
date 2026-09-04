// Bounded (scoped work-tree / dotfiles) watch on the LOCAL backend, against a
// real FSEvents watcher. The remote backend proves the same behaviour with
// inotifywait; this is the `Directory.watch` twin, so the feature works for
// both local and remote SSH repos.
//
// The setup is the dotfiles geometry in miniature: a git-dir whose work tree is
// a separate directory, `status.showUntrackedFiles=no`, and a large untracked
// subtree that must NOT be watched. The bounded watcher watches only the
// git-dir points and the parent dirs of tracked files, non-recursively — so:
//   * an edit to a tracked file fires,
//   * a git-state change (staging in the git-dir) sets touchesGitState, and
//   * churn in an untracked directory that holds no tracked file is invisible.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/local_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';

void main() {
  late Directory tmp;
  late String workTree;
  late String gitDir;
  late BoundedWatchSpec spec;

  Future<void> gd(List<String> args) async {
    final r = await Process.run('git', [
      '--git-dir=$gitDir',
      '--work-tree=$workTree',
      ...args,
    ], workingDirectory: workTree);
    if (r.exitCode != 0) fail('git ${args.join(' ')} failed: ${r.stderr}');
  }

  Future<RepoWatchEvent> waitFor(
    Stream<RepoWatchEvent> stream,
    bool Function(RepoWatchEvent) test, {
    Duration timeout = const Duration(seconds: 15),
  }) => stream
      .where(test)
      .first
      .timeout(
        timeout,
        onTimeout: () => fail('no matching watch event within $timeout'),
      );

  /// Starts a bounded watcher and lets setUp's own FS churn settle, so a test
  /// asserting on its own change isn't handed the tail of setup. Same approach
  /// as local_watch_worktree_test.
  /// Recomputes the bounded surface from the repo's CURRENT tracked files, the
  /// way the provider's supplier does — so a re-arm sees files added since.
  Future<BoundedWatchSpec> currentSpec() async {
    final tracked = await Process.run('git', [
      '--git-dir=$gitDir',
      '--work-tree=$workTree',
      'ls-files',
    ], workingDirectory: workTree);
    return computeBoundedWatchSpec(
      gitDir: gitDir,
      workTree: workTree,
      trackedFiles: (tracked.stdout as String).split('\n'),
    );
  }

  Future<Stream<RepoWatchEvent>> quietWatcher() async {
    final events = LocalWatchService()
        .watch(workTree, bounded: currentSpec)
        .asBroadcastStream();
    final sub = events.listen(null);
    addTearDown(sub.cancel);
    var lastSeen = DateTime.now();
    final probe = events.listen((_) => lastSeen = DateTime.now());
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().difference(lastSeen) < const Duration(seconds: 1) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await probe.cancel();
    return events;
  }

  setUp(() async {
    final base = await Directory.systemTemp.createTemp('bounded_watch_');
    tmp = Directory(base.resolveSymbolicLinksSync());
    workTree = '${tmp.path}/home';
    gitDir = '${tmp.path}/home/.home.git';
    Directory(workTree).createSync();
    Directory('$workTree/.config/bash').createSync(recursive: true);

    // A separate git-dir whose work tree is `workTree`, mirroring ~/.home.git.
    await Process.run('git', ['init', '-q', '--bare', gitDir]);
    await gd(['config', 'core.worktree', workTree]);
    await gd(['config', 'status.showUntrackedFiles', 'no']);
    await gd(['config', 'user.email', 't@t']);
    await gd(['config', 'user.name', 't']);
    await gd(['config', 'commit.gpgsign', 'false']);
    File('$workTree/.bashrc').writeAsStringSync('export A=1\n');
    File('$workTree/.config/bash/aliases.sh').writeAsStringSync('alias l=ls\n');
    await gd(['add', '.bashrc', '.config/bash/aliases.sh']);
    await gd(['commit', '-q', '-m', 'seed']);

    final tracked = await Process.run('git', [
      '--git-dir=$gitDir',
      '--work-tree=$workTree',
      'ls-files',
    ], workingDirectory: workTree);
    spec = computeBoundedWatchSpec(
      gitDir: gitDir,
      workTree: workTree,
      trackedFiles: (tracked.stdout as String).split('\n'),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the bounded surface is tiny, not the whole work tree', () {
    // git-dir root + refs/heads + refs/tags + workTree (.bashrc) + .config/bash.
    expect(spec.watchDirs.length, lessThanOrEqualTo(6));
    expect(spec.watchDirs, contains(gitDir));
    expect(spec.watchDirs, contains('$workTree/.config/bash'));
  });

  test('an edit to a tracked file fires a scoped, non-git event', () async {
    final events = await quietWatcher();

    File(
      '$workTree/.config/bash/aliases.sh',
    ).writeAsStringSync('alias l=ls -a\n');

    final event = await waitFor(events, (e) => e.paths.isNotEmpty);
    expect(event.paths, contains('.config/bash/aliases.sh'));
    expect(event.touchesGitState, isFalse);
  });

  test('staging in the git-dir is seen as a git-state change', () async {
    final events = await quietWatcher();

    // Writes the index (and objects) under the git-dir; the non-recursive
    // git-dir-root watch sees `index`, remapped to `.git/index`.
    File('$workTree/.bashrc').writeAsStringSync('export A=2\n');
    await gd(['add', '.bashrc']);

    final event = await waitFor(events, (e) => e.touchesGitState);
    expect(event.touchesGitState, isTrue);
  });

  test('churn in an untracked directory is invisible', () async {
    final events = await quietWatcher();

    // A directory holding no tracked file is not in the bounded surface, so a
    // recursive watch would flood on it but the bounded one must not — this is
    // the whole point of not watching all of $HOME.
    final noise = Directory('$workTree/.cache/build/deep')
      ..createSync(recursive: true);
    for (var i = 0; i < 5; i++) {
      File('${noise.path}/f$i.tmp').writeAsStringSync('x');
    }

    // Meanwhile touch a tracked file; only that event may surface.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    File('$workTree/.bashrc').writeAsStringSync('export A=3\n');

    final event = await waitFor(events, (e) => e.paths.isNotEmpty);
    expect(event.paths, contains('.bashrc'));
    expect(
      event.paths.any((p) => p.contains('.cache')),
      isFalse,
      reason: 'untracked-dir churn must never enter the bounded surface',
    );
  });

  test(
    'a file staged into a NEW directory becomes watched after re-arm',
    () async {
      // 0022 H5. The bounded surface is the parent directory of every tracked
      // file. Before the fix it was computed once and frozen for the life of the
      // stream, so a file added to a directory that held nothing tracked at arm
      // time was invisible forever — silently, with the watch indicator still
      // green — until the tab was closed or the connection dropped.
      final events = await quietWatcher();

      Directory('$workTree/.config/nvim').createSync(recursive: true);
      File('$workTree/.config/nvim/init.lua').writeAsStringSync('-- v1\n');
      // Staging writes the git-dir, which the surface always covers: that event
      // is what triggers the debounced recompute + re-arm.
      await gd(['add', '.config/nvim/init.lua']);

      // Wait out the re-arm debounce, then edit the newly tracked file.
      await Future<void>.delayed(const Duration(seconds: 3));
      File('$workTree/.config/nvim/init.lua').writeAsStringSync('-- v2\n');

      final event = await waitFor(
        events,
        (e) => e.paths.any((p) => p.contains('nvim')),
      );
      expect(event.paths.any((p) => p.contains('init.lua')), isTrue);
    },
  );
}
