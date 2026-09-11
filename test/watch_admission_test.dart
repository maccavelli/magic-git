// MADR 0045 phase 2. Admission composes exclusion and the host budget, and the
// ORDER is the property: a caller waiting for its predecessor's lock must not
// sit on a budget slot while it waits.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';
import 'package:remote_magic_git/core/git/watch/admission/watch_admission.dart';

const _grace = Duration(minutes: 3);

/// A cancellation that never happens.
Future<void> _never() => Completer<void>().future;

Future<AdmissionResult> _admit(
  WatchAdmission admission, {
  required String lockKey,
  int capacity = 2,
}) => admission.admit(
  host: 'host',
  capacity: capacity,
  lockKey: lockKey,
  grace: _grace,
  cancelled: _never(),
);

void main() {
  test('exclusion is acquired before the budget', () {
    fakeAsync((async) {
      final budget = HostWatcherBudget();
      final admission = WatchAdmission(budget: budget);

      AdmissionResult? first;
      unawaited(_admit(admission, lockKey: '/a/.git').then((r) => first = r));
      async.flushMicrotasks();
      expect(first, isA<Admitted>());

      // A second arm for the SAME repository waits for the first's lock.
      AdmissionResult? waiting;
      unawaited(_admit(admission, lockKey: '/a/.git').then((r) => waiting = r));
      async.elapse(const Duration(seconds: 10));
      expect(waiting, isNull);
      expect(
        budget.liveFor('host'),
        1,
        reason: 'the waiter holds no slot while it waits',
      );

      // So a different repository still gets the second slot of two.
      AdmissionResult? other;
      unawaited(_admit(admission, lockKey: '/b/.git').then((r) => other = r));
      async.flushMicrotasks();
      expect(
        other,
        isA<Admitted>(),
        reason:
            'had the waiter reserved first, this repository would have been '
            'refused by a ceiling spent on nobody',
      );

      (first! as Admitted).ticket.releaseAll();
      async.flushMicrotasks();
      expect(
        waiting,
        isA<Admitted>(),
        reason:
            'woken by the release, it reserves the slot the first gave back — '
            'the budget is consulted after the wait, not before it',
      );
      expect(budget.liveFor('host'), 2);
      (waiting! as Admitted).ticket.releaseAll();
      (other! as Admitted).ticket.releaseAll();
    });
  });

  test('a ceiling refusal installs no hold', () {
    fakeAsync((async) {
      final budget = HostWatcherBudget();
      final admission = WatchAdmission(budget: budget);
      budget.tryReserve('host', capacity: 1);

      AdmissionResult? result;
      unawaited(
        _admit(
          admission,
          lockKey: '/a/.git',
          capacity: 1,
        ).then((r) => result = r),
      );
      async.flushMicrotasks();

      expect(result, isA<RefusedCeiling>());
      final refused = result! as RefusedCeiling;
      expect((refused.live, refused.capacity), (1, 1));
      expect(
        admission.exclusion.isHeld('/a/.git'),
        isFalse,
        reason: 'nothing will arm, so nothing may keep the repository locked',
      );
    });
  });

  test('releaseAll is idempotent', () {
    fakeAsync((async) {
      final budget = HostWatcherBudget();
      final admission = WatchAdmission(budget: budget);
      var announced = 0;
      final sub = budget.releases('host').listen((_) => announced++);

      AdmissionResult? result;
      unawaited(_admit(admission, lockKey: '/a/.git').then((r) => result = r));
      async.flushMicrotasks();
      final ticket = (result! as Admitted).ticket;

      ticket.releaseAll();
      ticket.releaseAll();
      ticket.releaseBudget();
      ticket.releaseExclusion();
      async.flushMicrotasks();

      expect(budget.liveFor('host'), 0);
      expect(admission.exclusion.isHeld('/a/.git'), isFalse);
      expect(announced, 1, reason: 'one slot, one announcement');
      unawaited(sub.cancel());
    });
  });
}
