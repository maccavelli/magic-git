// 0026 deviation (c), the local half. `watch_diagnostics_remote_test.dart` holds
// the SSH half.
//
// ON REAL TIME, and allow-listed for it in `watch_stack_structure_test.dart`:
// these arm a real `Directory.watch`, whose events come from the operating
// system, which fake time cannot drive (MADR 0045 plan, deviation (r)).
//
// The log was wired into RemoteWatchService only, so repos on this Mac produced
// no watcher lines and no transition records — while driving the same lifecycle
// engine, with the same restart budget and the same degrade-to-polling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/local_watch_service.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';

/// Lets a real `Directory.watch` arm: long enough for the platform to report
/// it, then the event queue.
Future<void> _letTheWatchArm() async {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await pumpEventQueue();
}

void main() {
  setUp(watchDiagnostics.clear);
  tearDown(() async {
    await _letTheWatchArm();
    watchDiagnostics.clear();
  });

  test('the LOCAL backend records its watch transitions too', () async {
    // The half that was missing. A real directory, because LocalWatchService
    // arms `Directory.watch` for real — no shim, no fake.
    final dir = await Directory.systemTemp.createTemp('mg-localwatch-');
    Directory('${dir.path}/.git').createSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final sub = LocalWatchService().watch(dir.path).listen((_) {});
    await _letTheWatchArm();

    final records = watchDiagnostics.forRepo(dir.path).records;
    expect(
      records,
      isNotEmpty,
      reason:
          'a local repo drives the same lifecycle engine and can degrade to '
          'polling the same way; if it records nothing, "why is this repo '
          'polling" is unanswerable for this backend',
    );
    expect(
      records.map((r) => r.kind),
      contains(WatchTransition.armed),
      reason: 'and a healthy local arm is recorded as armed',
    );
    await sub.cancel();
  });

  test(
    'a local watch on a missing path arms and then says nothing, forever',
    () async {
      // CHARACTERISATION, and a hazard worth naming. On macOS
      // `Directory.watch()` over a path that does not exist neither throws, nor
      // errors the stream, nor completes it — measured directly:
      //
      //     PROBE threwSync=false streamError=false done=false
      //
      // So the engine records `armed`, the UI shows a healthy watch, and no
      // event can ever arrive. Nothing in the app can tell this apart from a
      // quiet repository.
      //
      // This pins the behaviour, it does not bless it. If a future Dart or macOS
      // starts reporting the failure this goes red, and the right response is to
      // route it to onDiagnostic and rewrite this test — not to relax it.
      final lines = <String>[];
      final missing =
          '${Directory.systemTemp.path}/mg-missing-'
          '${DateTime.now().microsecondsSinceEpoch}';
      final sub = LocalWatchService(
        onDiagnostic: lines.add,
      ).watch(missing).listen((_) {}, onError: (Object _) {});
      await _letTheWatchArm();

      expect(
        watchDiagnostics.forRepo(missing).records.map((r) => r.kind),
        contains(WatchTransition.armed),
        reason: 'it believes it armed',
      );
      expect(
        lines,
        isEmpty,
        reason:
            'and reports nothing, because the platform gives it nothing to '
            'report. The onDiagnostic wiring on the local failure paths is '
            'therefore present but UNTESTED on macOS — 0026 deviation (c).',
      );
      await sub.cancel();
    },
  );
}
