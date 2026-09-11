// MADR 0045 phase 2. The host watcher budget, as a value a test can own.
//
// These pinned the process-wide statics in `RemoteWatchService` before: every
// ceiling test had to reset a counter that every other test shared. Each test
// here builds its own budget, so none of them can see another's slots.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/admission/host_watcher_budget.dart';

void main() {
  test('reserve refuses at capacity', () {
    final budget = HostWatcherBudget();

    expect(budget.tryReserve('host', capacity: 2), isNotNull);
    expect(budget.tryReserve('host', capacity: 2), isNotNull);
    expect(
      budget.tryReserve('host', capacity: 2),
      isNull,
      reason: 'a third watcher on a host allowing two is refused, not queued',
    );
    expect(budget.liveFor('host'), 2);
  });

  test('release credits the reserving host', () {
    final budget = HostWatcherBudget();
    final alpha = budget.tryReserve('alpha', capacity: 2)!;
    budget.tryReserve('beta', capacity: 2);

    alpha.release();

    expect(alpha.host, 'alpha');
    expect(
      budget.liveFor('alpha'),
      0,
      reason: 'alpha reserved, so alpha is credited',
    );
    expect(
      budget.liveFor('beta'),
      1,
      reason: 'beta paid for nothing that was released',
    );
  });

  test('a release is announced on its own host only', () async {
    final budget = HostWatcherBudget();
    var onAlpha = 0;
    var onBeta = 0;
    final alphaSub = budget.releases('alpha').listen((_) => onAlpha++);
    final betaSub = budget.releases('beta').listen((_) => onBeta++);
    addTearDown(alphaSub.cancel);
    addTearDown(betaSub.cancel);

    budget.tryReserve('alpha', capacity: 1)!.release();
    await pumpEventQueue();

    expect(onAlpha, 1);
    expect(
      onBeta,
      0,
      reason:
          'a repository waiting on a full host must not be woken into an arm '
          'it can only lose',
    );
  });

  test('release is idempotent', () async {
    final budget = HostWatcherBudget();
    var announced = 0;
    final sub = budget.releases('host').listen((_) => announced++);
    addTearDown(sub.cancel);
    final held = budget.tryReserve('host', capacity: 2)!;
    final released = budget.tryReserve('host', capacity: 2)!;

    released.release();
    released.release();
    await pumpEventQueue();

    expect(
      budget.liveFor('host'),
      1,
      reason:
          'a second release must not take the slot another watcher still holds',
    );
    expect(announced, 1);
    expect(held.isReleased, isFalse);
    expect(released.isReleased, isTrue);
  });

  test('the host entry empties at zero', () {
    final budget = HostWatcherBudget();

    budget.tryReserve('host', capacity: 1)!.release();

    expect(budget.liveFor('host'), 0);
    expect(
      budget.liveTotal,
      0,
      reason:
          'a released slot must not linger as a zero entry that reads as a '
          'leaked watcher in diagnostics',
    );
    expect(budget.tryReserve('host', capacity: 1), isNotNull);
  });
}
