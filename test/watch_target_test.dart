// MADR 0045 phase 1. A watcher's identity is a value: equal fields, equal
// target — so a provider family keyed by it shares a watcher exactly when the
// parameters are the same, and never otherwise.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/watch_target.dart';

void main() {
  test('targets with equal fields are equal and hash alike', () {
    const a = WatchTarget(
      repoPath: '/repo',
      surface: RecursiveSurface(),
      backend: WatchBackend.ssh,
    );
    const b = WatchTarget(
      repoPath: '/repo',
      surface: RecursiveSurface(),
      backend: WatchBackend.ssh,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('a bounded surface differs from a recursive one on the same path', () {
    const recursive = WatchTarget(
      repoPath: '/home/u',
      surface: RecursiveSurface(),
      backend: WatchBackend.ssh,
    );
    const bounded = WatchTarget(
      repoPath: '/home/u',
      surface: BoundedSurface(gitDir: '/home/u/.home.git', workTree: '/home/u'),
      backend: WatchBackend.ssh,
    );
    expect(recursive, isNot(bounded));
  });

  test('a different git dir is a different target', () {
    const one = WatchTarget(
      repoPath: '/home/u',
      surface: BoundedSurface(gitDir: '/home/u/.a.git', workTree: '/home/u'),
      backend: WatchBackend.ssh,
    );
    const two = WatchTarget(
      repoPath: '/home/u',
      surface: BoundedSurface(gitDir: '/home/u/.b.git', workTree: '/home/u'),
      backend: WatchBackend.ssh,
    );
    expect(one, isNot(two));
  });
}
