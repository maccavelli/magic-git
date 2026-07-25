import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/git/watch_lifecycle.dart';

void main() {
  group('watchLifecycle', () {
    /// Returns a lifecycle with very fast timings so tests run at fake speed.
    // ignore: no_leading_underscores_for_local_identifiers
    Stream<RepoWatchEvent> fastLifecycle({
      required Future<WatchArm> Function(WatchHooks) arm,
      int maxRestarts = 3,
    }) =>
        watchLifecycle(
          arm: arm,
          trailing: Duration.zero,
          maxWait: const Duration(milliseconds: 10),
          minInterval: Duration.zero,
          pollInterval: const Duration(days: 1),
          recoveryInterval: const Duration(days: 1),
          maxRestarts: maxRestarts,
        );

    test('successful arm emits an immediate eventDriven tick', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        fastLifecycle(
          arm: (_) async => WatchArmed(() async {}),
        ).listen(events.add);
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.mode, WatchMode.eventDriven);
        expect(events.first.paths, isEmpty);
      });
    });

    test('signalPath delivers coalesced paths in the next tick', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        WatchHooks? captured;
        fastLifecycle(
          arm: (hooks) async {
            captured = hooks;
            return WatchArmed(() async {});
          },
        ).listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        captured!.signalPath('foo.txt');
        captured!.signalPath('bar.txt');
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.paths, contains('foo.txt'));
        expect(events.first.paths, contains('bar.txt'));
      });
    });

    test('WatchUnavailable degrades to polling immediately', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        fastLifecycle(
          arm: (_) async => const WatchUnavailable(),
        ).listen(events.add);
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.mode, WatchMode.polling);
      });
    });

    test('WatchAborted emits nothing — caller already cleaned up', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        fastLifecycle(
          arm: (_) async => const WatchAborted(),
        ).listen(events.add);
        async.elapse(Duration.zero);

        expect(events, isEmpty);
      });
    });

    test('scheduleRestart triggers re-arm after backoff', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        final arms = <int>[];
        WatchHooks? captured;
        fastLifecycle(
          arm: (hooks) async {
            captured = hooks;
            arms.add(arms.length);
            return WatchArmed(() async {});
          },
        ).listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        captured!.scheduleRestart();
        async.elapse(const Duration(seconds: 2)); // backoff = 1 * 2s

        expect(arms, hasLength(2)); // initial + one restart
        expect(events.any((e) => e.mode == WatchMode.stopped), isTrue);
        expect(events.any((e) => e.mode == WatchMode.eventDriven), isTrue);
      });
    });

    test('exhausted restarts degrade to polling', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        WatchHooks? captured;
        fastLifecycle(
          maxRestarts: 0,
          arm: (hooks) async {
            captured = hooks;
            return WatchArmed(() async {});
          },
        ).listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        captured!.scheduleRestart();
        async.elapse(Duration.zero); // scheduleRestart → startPolling

        expect(events.last.mode, WatchMode.polling);
      });
    });

    test('noteActivity resets the restart budget', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        WatchHooks? captured;
        int armCount = 0;
        fastLifecycle(
          maxRestarts: 1,
          arm: (hooks) async {
            captured = hooks;
            armCount++;
            return WatchArmed(() async {});
          },
        ).listen(events.add);
        async.elapse(Duration.zero);
        expect(armCount, 1);
        events.clear();

        // Consume the one allowed restart → re-arm succeeds.
        captured!.scheduleRestart();
        async.elapse(const Duration(seconds: 3)); // backoff 2s + re-arm
        expect(armCount, 2);
        events.clear();

        // Second restart exhausts the budget → polling.
        captured!.scheduleRestart();
        async.elapse(const Duration(seconds: 1));
        expect(events.any((e) => e.mode == WatchMode.polling), isTrue);

        // noteActivity resets restarts to 0, making room for another attempt.
        captured!.noteActivity();
        captured!.scheduleRestart();
        async.elapse(const Duration(seconds: 3)); // backoff 2s + re-arm
        expect(armCount, 3);
        expect(events.any((e) => e.mode == WatchMode.eventDriven), isTrue);
      });
    });

    test('path overflow at maxPaths emits empty paths set', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        WatchHooks? captured;
        fastLifecycle(
          arm: (hooks) async {
            captured = hooks;
            return WatchArmed(() async {});
          },
        ).listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        // 513 paths triggers overflow (maxPaths = 512).
        for (var i = 0; i < 513; i++) {
          captured!.signalPath('file_$i.txt');
        }
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.paths, isEmpty, reason: 'overflow clears paths');
      });
    });

    test('cancellation tears down and closes the stream', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        var teardownCalled = false;
        late final StreamSubscription<RepoWatchEvent> sub;
        sub = fastLifecycle(
          arm: (_) async => WatchArmed(() async {
            teardownCalled = true;
          }),
        ).listen(events.add);
        async.elapse(Duration.zero);

        sub.cancel();
        async.elapse(Duration.zero);

        expect(teardownCalled, isTrue);
      });
    });
  });
}
