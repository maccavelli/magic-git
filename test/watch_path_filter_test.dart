// shouldTriggerWatch decides which changed paths refresh status. It's shared by
// both the SSH (fswatch/inotifywait) and local (Directory.watch) backends, but
// no test exercised it — remote_watch_service_test's fakes return before any
// path is ever classified. A regression here silently makes the watcher either
// fire on every git-op lock churn or drop real edits, so pin the contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch_path_filter.dart';

void main() {
  group('shouldTriggerWatch', () {
    test('real edits and git state changes trigger a refresh', () {
      for (final path in [
        'lib/main.dart',
        'README.md',
        'a/b/c/deep.txt',
        // The whole point of the watcher: index/HEAD/refs changes (this app's
        // own or another process on the same filesystem) must trigger.
        '.git/index',
        '.git/HEAD',
        '.git/refs/heads/main',
        // A submodule's own index change is still a real change.
        'sub/.git/index',
      ]) {
        expect(shouldTriggerWatch(path), isTrue, reason: path);
      }
    });

    test('noisy paths inside .git are suppressed', () {
      for (final path in [
        '.git/index.lock',
        '.git/objects/ab/cdef0123',
        '.git/objects/pack/pack-1.pack',
        '.git/logs/HEAD',
        '.git/fsmonitor--daemon/cookies/x',
        'nested/.git/objects/ab/cd',
        // Written early in every commit, before the index/refs move; the
        // app's own commit would otherwise refresh partway through itself.
        '.git/COMMIT_EDITMSG',
        'sub/.git/COMMIT_EDITMSG',
      ]) {
        expect(shouldTriggerWatch(path), isFalse, reason: path);
      }
    });

    test('editor swap and atomic-write temp files are suppressed', () {
      for (final path in [
        'file.swp',
        'file.swo',
        'file.swn',
        'backup~',
        'dir/4913', // (n)vim's probe file
        '.goutputstream-ABC123',
        'a/b/.goutputstream-XYZ',
      ]) {
        expect(shouldTriggerWatch(path), isFalse, reason: path);
      }
    });

    test('a .lock file OUTSIDE .git is a real file, not git noise', () {
      // The .lock suppression is scoped to paths inside a .git dir.
      expect(shouldTriggerWatch('build/foo.lock'), isTrue);
      expect(shouldTriggerWatch('Podfile.lock'), isTrue);
    });

    test('the empty path never triggers', () {
      expect(shouldTriggerWatch(''), isFalse);
    });
  });

  test('the watcher registry files do not trigger the watcher (0025 C3)', () {
    // The pid file and heartbeat live in the git-dir, which a bounded watch
    // watches. Without this the heartbeat the app writes every minute would
    // trigger the refresh it exists to make unnecessary.
    expect(shouldTriggerWatch('.git/mg-watch.pid'), isFalse);
    expect(shouldTriggerWatch('.git/mg-watch.hb'), isFalse);
    expect(shouldTriggerWatch('worktree/.git/mg-watch.hb'), isFalse);
    // Since 0027 the lease files are tokenised per watcher instance. The
    // filter matches the `mg-watch.` prefix, so this still holds — but it is
    // now load-bearing for a name shape nothing else covers, and a heartbeat
    // that triggers a watch event would provoke the very refresh it exists to
    // make unnecessary, once a minute, forever.
    expect(shouldTriggerWatch('.git/mg-watch.m3k9x2a1.pid'), isFalse);
    expect(shouldTriggerWatch('.git/mg-watch.m3k9x2a1.hb'), isFalse);
    expect(shouldTriggerWatch('worktree/.git/mg-watch.m3k9x2a1.hb'), isFalse);
    // Anything else under .git still does.
    expect(shouldTriggerWatch('.git/index'), isTrue);
  });
}
