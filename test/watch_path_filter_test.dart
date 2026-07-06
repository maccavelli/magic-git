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
}
