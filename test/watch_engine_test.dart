// MADR 0045 phase 4. The engine's specification: the nine tests that specified
// the lifecycle function in `watch_lifecycle.dart`, ported with their names and
// assertions, and the rules that function could not state — stale attempts,
// results after cancel — tested directly.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch/engine/engine_event.dart';
import 'package:remote_magic_git/core/git/watch/engine/watch_engine.dart';
import 'package:remote_magic_git/core/git/watch/source/watch_source.dart';
import 'package:remote_magic_git/core/git/watch/watch_timings.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';

import 'helpers/function_watch_source.dart';

void main() {
  group('WatchEngine', () {
    /// An engine with very fast timings so tests run at fake speed.
    ///
    /// Its own timings rather than [WatchTimings.forTest] (plan deviation (h)):
    /// the poll and recovery never fire inside a test, and recovery stays
    /// longer than the poll, as [WatchTimings.coherenceErrors] requires.
    WatchEngine fastEngine({
      required Future<SourceArm> Function(ArmRequest) arm,
      int maxRestarts = 3,
      WatchTransitionSink? onTransition,
      Stream<void>? budgetReleased,
    }) => WatchEngine(
      source: FunctionWatchSource(arm),
      repoPath: '/repo',
      timings: WatchTimings(
        trailing: Duration.zero,
        maxWait: const Duration(milliseconds: 10),
        minInterval: Duration.zero,
        pollInterval: const Duration(days: 1),
        recoveryInterval: const Duration(days: 2),
        maxRestarts: maxRestarts,
      ),
      onTransition: onTransition,
      budgetReleased: budgetReleased,
    );

    test('successful arm emits an immediate eventDriven tick', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        fastEngine(
          arm: (_) async => SourceArmed(FakeArmedSource()),
        ).events.listen(events.add);
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.mode, WatchMode.eventDriven);
        expect(events.first.paths, isEmpty);
      });
    });

    test('signalPath delivers coalesced paths in the next tick', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        FakeArmedSource? captured;
        fastEngine(
          arm: (_) async {
            final armed = FakeArmedSource();
            captured = armed;
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
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
        fastEngine(
          arm: (_) async =>
              const SourceUnavailable(WatchUnavailableReason.noTool),
        ).events.listen(events.add);
        async.elapse(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first.mode, WatchMode.polling);
      });
    });

    test('WatchAborted emits nothing — caller already cleaned up', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        fastEngine(
          arm: (_) async => const SourceAborted(),
        ).events.listen(events.add);
        async.elapse(Duration.zero);

        expect(events, isEmpty);
      });
    });

    test('scheduleRestart triggers re-arm after backoff', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        final arms = <int>[];
        FakeArmedSource? captured;
        fastEngine(
          arm: (_) async {
            final armed = FakeArmedSource();
            captured = armed;
            arms.add(arms.length);
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        captured!.die();
        async.elapse(const Duration(seconds: 2)); // backoff = 1 * 2s

        expect(arms, hasLength(2)); // initial + one restart
        expect(events.any((e) => e.mode == WatchMode.stopped), isTrue);
        expect(events.any((e) => e.mode == WatchMode.eventDriven), isTrue);
      });
    });

    test('exhausted restarts degrade to polling', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        FakeArmedSource? captured;
        fastEngine(
          maxRestarts: 0,
          arm: (_) async {
            final armed = FakeArmedSource();
            captured = armed;
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
        async.elapse(Duration.zero);
        events.clear();

        captured!.die();
        async.elapse(Duration.zero); // a death → polling

        expect(events.last.mode, WatchMode.polling);
      });
    });

    test('noteActivity resets the restart budget', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        FakeArmedSource? captured;
        int armCount = 0;
        fastEngine(
          maxRestarts: 1,
          arm: (_) async {
            final armed = FakeArmedSource();
            captured = armed;
            armCount++;
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
        async.elapse(Duration.zero);
        expect(armCount, 1);
        events.clear();

        // Consume the one allowed restart → re-arm succeeds.
        captured!.die();
        async.elapse(const Duration(seconds: 3)); // backoff 2s + re-arm
        expect(armCount, 2);
        events.clear();

        // Second restart exhausts the budget → polling.
        captured!.die();
        async.elapse(const Duration(seconds: 1));
        expect(events.any((e) => e.mode == WatchMode.polling), isTrue);

        // Activity resets restarts to 0, making room for another attempt.
        captured!.noteActivity();
        captured!.die();
        async.elapse(const Duration(seconds: 3)); // backoff 2s + re-arm
        expect(armCount, 3);
        expect(events.any((e) => e.mode == WatchMode.eventDriven), isTrue);
      });
    });

    test('path overflow at maxPaths emits empty paths set', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        FakeArmedSource? captured;
        fastEngine(
          arm: (_) async {
            final armed = FakeArmedSource();
            captured = armed;
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
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
        sub = fastEngine(
          arm: (_) async => SourceArmed(
            FakeArmedSource(onClose: () => teardownCalled = true),
          ),
        ).events.listen(events.add);
        async.elapse(Duration.zero);

        sub.cancel();
        async.elapse(Duration.zero);

        expect(teardownCalled, isTrue);
      });
    });

    // ---- the rules the lifecycle function could not state ----------------

    test('an arm result from a superseded attempt is closed, not adopted', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        final armed = <WatchTransition>[];
        final engine = fastEngine(
          arm: (_) async => SourceArmed(FakeArmedSource()),
          onTransition: (kind, _, _) {
            if (kind == WatchTransition.armed) armed.add(kind);
          },
        );
        engine.events.listen(events.add);
        async.elapse(Duration.zero);
        expect(events, hasLength(1));

        // Attempt 1 is current; no second arm starts while one is in flight,
        // so the public API cannot produce this late answer.
        final superseded = FakeArmedSource();
        engine.debugPost(ArmResolved(0, SourceArmed(superseded)));
        async.elapse(Duration.zero);

        expect(
          superseded.closed,
          isTrue,
          reason:
              'a late arm adopted, or dropped without closing, is a live '
              'watcher nothing holds (0026 H1)',
        );
        expect(events, hasLength(1), reason: 'no second armed tick');
        expect(armed, hasLength(1), reason: 'and no second armed record');
      });
    });

    test('a source arriving after cancel is closed', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final arriving = FakeArmedSource();
        final sub = fastEngine(
          arm: (_) async {
            await gate.future;
            return SourceArmed(arriving);
          },
        ).events.listen((_) {});
        async.elapse(Duration.zero);

        sub.cancel();
        async.elapse(Duration.zero);
        gate.complete();
        async.elapse(Duration.zero);

        expect(
          arriving.closed,
          isTrue,
          reason: 'armed for a subscriber who has left: nothing else closes it',
        );
      });
    });

    test('a refusal arriving after cancel starts no polling', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final transitions = <String>[];
        final sub = fastEngine(
          arm: (_) async {
            await gate.future;
            return const SourceUnavailable(
              WatchUnavailableReason.heldByAnother,
            );
          },
          onTransition: (kind, cause, _) =>
              transitions.add('${kind.name}: $cause'),
        ).events.listen((_) {});
        async.elapse(Duration.zero);

        sub.cancel();
        async.elapse(Duration.zero);
        gate.complete();
        async.elapse(Duration.zero);

        expect(
          async.periodicTimerCount,
          0,
          reason:
              'the lifecycle function started its poll and recovery timers '
              'here, for a stream that no longer existed (MADR amendment '
              '0045.2)',
        );
        expect(transitions, [
          'stopped: stream cancelled',
        ], reason: 'a watcher that is gone has nothing to degrade');
      });
    });

    test('many re-arms while arming collapse into a single follow-up', () {
      fakeAsync((async) {
        // The serialisation alone would QUEUE all of them, so three timers
        // firing during one slow arm would produce three sequential re-arms —
        // three SSH round trips and three watcher spawns to reach a state one
        // would have reached. At most one follow-up is kept.
        var armCalls = 0;
        final gate = Completer<void>();
        FakeArmedSource? captured;

        final sub = fastEngine(
          arm: (_) async {
            armCalls++;
            final armed = FakeArmedSource();
            captured = armed;
            if (armCalls == 1) await gate.future;
            return SourceArmed(armed);
          },
        ).events.listen((_) {});
        async.elapse(Duration.zero);
        expect(armCalls, 1);

        captured!
          ..rearm()
          ..rearm()
          ..rearm();
        gate.complete();
        async.elapse(Duration.zero);

        expect(
          armCalls,
          2,
          reason:
              'one in flight plus one collapsed follow-up, not one per request',
        );
        sub.cancel();
      });
    });

    test('overlapping starts tear down every armed source', () {
      fakeAsync((async) {
        // MADR 0026 H1. A second start entering the window where the first arm
        // had not yet returned armed again, and the later assignment
        // overwrote the first teardown — orphaning a live source and, in
        // RemoteWatchService, leaking the watcher slot it reserved.
        var armCalls = 0;
        var teardowns = 0;
        final gate = Completer<void>();
        FakeArmedSource? captured;

        final sub = fastEngine(
          arm: (_) async {
            armCalls++;
            final armed = FakeArmedSource(onClose: () => teardowns++);
            captured = armed;
            if (armCalls == 1) await gate.future;
            return SourceArmed(armed);
          },
        ).events.listen((_) {});
        async.elapse(Duration.zero);
        expect(
          armCalls,
          1,
          reason: 'the first arm is in flight, holding the gate',
        );

        // A legitimate re-arm (the watched path set changed) arriving while
        // the first arm has not yet returned.
        captured!.rearm();
        async.elapse(Duration.zero);
        expect(
          armCalls,
          1,
          reason: 'the re-arm must QUEUE behind the in-flight arm, not race it',
        );

        gate.complete();
        async.elapse(Duration.zero);
        expect(
          armCalls,
          2,
          reason: 'the queued re-arm runs once the first is done',
        );
        expect(
          teardowns,
          1,
          reason: 'the queued re-arm tore the first source down before arming',
        );

        sub.cancel();
        async.elapse(Duration.zero);

        expect(
          teardowns,
          2,
          reason:
              'both armed sources must be torn down; H1 is real if only one is',
        );
      });
    });

    test('a budget release wakes only a ceiling refusal', () {
      fakeAsync((async) {
        final releases = StreamController<void>.broadcast();
        var ceilingArms = 0;
        var noToolArms = 0;
        final ceiling = fastEngine(
          arm: (_) async {
            ceilingArms++;
            return const SourceUnavailable(WatchUnavailableReason.ceiling);
          },
          budgetReleased: releases.stream,
        ).events.listen((_) {});
        final noTool = fastEngine(
          arm: (_) async {
            noToolArms++;
            return const SourceUnavailable(WatchUnavailableReason.noTool);
          },
          budgetReleased: releases.stream,
        ).events.listen((_) {});
        async.elapse(Duration.zero);
        expect((ceilingArms, noToolArms), (1, 1));

        releases.add(null);
        async.elapse(Duration.zero);

        expect(
          ceilingArms,
          2,
          reason:
              'a ceiling refusal waits on exactly this, so it re-arms at once '
              'rather than polling out the recovery interval (0028 H2)',
        );
        expect(
          noToolArms,
          1,
          reason: 'a freed slot says nothing about a host with no watcher tool',
        );
        ceiling.cancel();
        noTool.cancel();
        releases.close();
      });
    });

    test('a re-arm spends no restart budget and emits no stopped tick', () {
      fakeAsync((async) {
        final events = <RepoWatchEvent>[];
        var arms = 0;
        FakeArmedSource? captured;
        fastEngine(
          maxRestarts: 1,
          arm: (_) async {
            arms++;
            final armed = FakeArmedSource();
            captured = armed;
            return SourceArmed(armed);
          },
        ).events.listen(events.add);
        async.elapse(Duration.zero);

        // Two legitimate re-arms, as a bounded surface makes when tracked files
        // appear in new directories (0022 H5).
        captured!.rearm();
        async.elapse(Duration.zero);
        captured!.rearm();
        async.elapse(Duration.zero);
        expect(arms, 3);
        expect(
          events.map((e) => e.mode),
          everyElement(WatchMode.eventDriven),
          reason:
              'a re-arm is not an outage: staging a file must not flicker the '
              'dot to stopped',
        );

        captured!.die();
        async.elapse(Duration.zero);
        expect(
          events.last.mode,
          WatchMode.stopped,
          reason:
              'one restart allowed and none spent, so a death backs off; had '
              'the re-arms spent it, this repository would now be polling',
        );
      });
    });
  });
}
