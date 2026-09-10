// MADR 0045 phase 1. The bounded re-arm rule, once, where it used to be written
// twice. 0022 H5 is why it exists; the debounce is why a `git add` costs one
// re-arm and not four.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/source/surface_rearm_policy.dart';

void main() {
  const debounce = Duration(seconds: 2);

  test('a .git path on a bounded surface re-arms once after the debounce', () {
    fakeAsync((async) {
      var rearms = 0;
      SurfaceRearmPolicy(debounce: debounce).onPath(
        '.git/index',
        bounded: true,
        rearm: () => rearms++,
        cancelled: () => false,
      );
      async.elapse(debounce - const Duration(milliseconds: 1));
      expect(rearms, 0, reason: 'not before the burst has gone quiet');
      async.elapse(const Duration(milliseconds: 1));
      expect(rearms, 1);
    });
  });

  test('repeated .git paths inside the debounce collapse to one re-arm', () {
    fakeAsync((async) {
      var rearms = 0;
      final policy = SurfaceRearmPolicy(debounce: debounce);
      for (final path in [
        '.git/index.lock',
        '.git/index',
        '.git/refs/heads/x',
      ]) {
        policy.onPath(
          path,
          bounded: true,
          rearm: () => rearms++,
          cancelled: () => false,
        );
        async.elapse(const Duration(milliseconds: 500));
      }
      async.elapse(debounce);
      expect(rearms, 1, reason: 'one git add writes the index several times');
    });
  });

  test('a work-tree path never re-arms', () {
    fakeAsync((async) {
      var rearms = 0;
      SurfaceRearmPolicy(debounce: debounce).onPath(
        '.bashrc',
        bounded: true,
        rearm: () => rearms++,
        cancelled: () => false,
      );
      async.elapse(debounce * 2);
      expect(rearms, 0);
    });
  });

  test('a recursive surface never re-arms', () {
    fakeAsync((async) {
      var rearms = 0;
      SurfaceRearmPolicy(debounce: debounce).onPath(
        '.git/index',
        bounded: false,
        rearm: () => rearms++,
        cancelled: () => false,
      );
      async.elapse(debounce * 2);
      expect(rearms, 0, reason: 'a recursive watch already covers every dir');
    });
  });

  test('cancel stops a pending re-arm', () {
    fakeAsync((async) {
      var rearms = 0;
      SurfaceRearmPolicy(debounce: debounce)
        ..onPath(
          '.git/index',
          bounded: true,
          rearm: () => rearms++,
          cancelled: () => false,
        )
        ..cancel();
      async.elapse(debounce * 2);
      expect(rearms, 0);
    });
  });

  test('a cancelled engine is not re-armed', () {
    fakeAsync((async) {
      var rearms = 0;
      SurfaceRearmPolicy(debounce: debounce).onPath(
        '.git/index',
        bounded: true,
        rearm: () => rearms++,
        cancelled: () => true,
      );
      async.elapse(debounce * 2);
      expect(rearms, 0);
    });
  });
}
