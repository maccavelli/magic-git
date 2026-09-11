// MADR 0045 phase 2. One watcher per repository lock within a session, owned by
// one class instead of emerging from `_SharedWatch`'s sharing.
//
// Driven in fake time: the grace is three minutes, and every property here is
// about what happens before or after a wait, which real time can only
// approximate.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/admission/repo_exclusion.dart';

const _grace = Duration(minutes: 3);
const _lock = '/repo/.git';

/// A cancellation that never happens.
Future<void> _never() => Completer<void>().future;

void main() {
  test('a second acquire waits for the first release', () {
    fakeAsync((async) {
      final exclusion = RepoExclusion();
      ExclusionHold? first;
      ExclusionHold? second;

      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => first = h),
      );
      async.flushMicrotasks();
      expect(first, isNotNull);

      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => second = h),
      );
      async.elapse(const Duration(seconds: 30));
      expect(second, isNull, reason: 'the lock is still held by the first');

      first!.release();
      async.flushMicrotasks();

      expect(second, isNotNull, reason: 'the release is what lets it through');
      expect(second!.graceExpired, isFalse);
      expect(exclusion.isHeld(_lock), isTrue);
      second!.release();
      expect(exclusion.isHeld(_lock), isFalse);
    });
  });

  test('a cancelled wait returns null and installs nothing', () {
    fakeAsync((async) {
      final exclusion = RepoExclusion();
      ExclusionHold? first;
      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => first = h),
      );
      async.flushMicrotasks();

      final leave = Completer<void>();
      var settled = false;
      ExclusionHold? waiter;
      unawaited(
        exclusion.acquire(_lock, grace: _grace, cancelled: leave.future).then((
          h,
        ) {
          waiter = h;
          settled = true;
        }),
      );
      async.elapse(const Duration(seconds: 1));
      leave.complete();
      async.flushMicrotasks();

      expect(settled, isTrue, reason: 'leaving ends the wait at once');
      expect(waiter, isNull);

      first!.release();
      async.flushMicrotasks();
      expect(
        exclusion.isHeld(_lock),
        isFalse,
        reason:
            'a subscriber who left while waiting must not take the lock from '
            'whoever arrives next',
      );
    });
  });

  test('the grace expiry proceeds and says so', () {
    fakeAsync((async) {
      final exclusion = RepoExclusion();
      unawaited(exclusion.acquire(_lock, grace: _grace, cancelled: _never()));
      async.flushMicrotasks();

      ExclusionHold? next;
      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => next = h),
      );
      async.elapse(_grace - const Duration(seconds: 1));
      expect(next, isNull, reason: 'inside the grace it waits');

      async.elapse(const Duration(seconds: 2));
      expect(
        next,
        isNotNull,
        reason:
            'a wedged teardown degrades to the old race rather than leaving the '
            'repository unwatchable',
      );
      expect(next!.graceExpired, isTrue);
    });
  });

  test('a stale release does not remove a newer hold', () {
    fakeAsync((async) {
      final exclusion = RepoExclusion();
      ExclusionHold? wedged;
      ExclusionHold? next;
      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => wedged = h),
      );
      async.flushMicrotasks();
      unawaited(
        exclusion
            .acquire(_lock, grace: _grace, cancelled: _never())
            .then((h) => next = h),
      );
      async.elapse(_grace + const Duration(seconds: 1));
      expect(next, isNotNull);

      wedged!.release();

      expect(
        exclusion.isHeld(_lock),
        isTrue,
        reason:
            'the wedged predecessor finally releasing must not open the door '
            'beside the watcher that replaced it',
      );
      next!.release();
      expect(exclusion.isHeld(_lock), isFalse);
    });
  });

  test('different keys never wait on each other', () {
    fakeAsync((async) {
      final exclusion = RepoExclusion();
      unawaited(
        exclusion.acquire('/one/.git', grace: _grace, cancelled: _never()),
      );
      async.flushMicrotasks();

      ExclusionHold? other;
      unawaited(
        exclusion
            .acquire('/two/.git', grace: _grace, cancelled: _never())
            .then((h) => other = h),
      );
      async.flushMicrotasks();

      expect(other, isNotNull, reason: 'different repositories are unrelated');
    });
  });
  test('whenIdle is immediate when nothing is held', () {
    fakeAsync((async) {
      var idle = false;
      unawaited(RepoExclusion().whenIdle().then((_) => idle = true));
      async.flushMicrotasks();

      expect(idle, isTrue, reason: 'nothing to give back, nothing to wait for');
    });
  });

  test('whenIdle waits until every hold is released', () {
    fakeAsync((async) {
      // MADR amendment 0045.4: what a transport close waits for, so a watcher's
      // host claims travel before the transport does.
      final exclusion = RepoExclusion();
      final holds = <ExclusionHold>[];
      for (final key in ['/a/.git', '/b/.git']) {
        unawaited(
          exclusion
              .acquire(key, grace: _grace, cancelled: _never())
              .then((h) => holds.add(h!)),
        );
      }
      async.flushMicrotasks();
      expect(holds, hasLength(2));

      var idle = false;
      unawaited(exclusion.whenIdle().then((_) => idle = true));
      holds.first.release();
      async.flushMicrotasks();
      expect(idle, isFalse, reason: 'one repository still holds its lock');

      holds.last.release();
      async.flushMicrotasks();
      expect(idle, isTrue, reason: 'the last release is what makes it idle');
    });
  });
}
