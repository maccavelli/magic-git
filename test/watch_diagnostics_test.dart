// The watcher mode-transition log (MADR 0026). Observational only: it records
// transitions the engine already performs, and must not become the memory leak
// it exists to investigate.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/watch_diagnostics.dart';

WatchTransitionRecord _rec(
  int i, {
  WatchTransition kind = WatchTransition.armed,
  String cause = 'test',
  int liveWatchers = 0,
  int restarts = 0,
}) => WatchTransitionRecord(
  at: DateTime.fromMillisecondsSinceEpoch(i),
  kind: kind,
  repoPath: '/repo',
  cause: cause,
  liveWatchers: liveWatchers,
  restarts: restarts,
);

void main() {
  test('the log is bounded and drops the oldest records', () {
    final log = WatchTransitionLog();
    for (var i = 0; i < 250; i++) {
      log.add(_rec(i));
    }
    expect(log.records, hasLength(WatchTransitionLog.maxRecords));
    // Oldest dropped, newest kept, order preserved.
    expect(log.records.first.at.millisecondsSinceEpoch, 50);
    expect(log.records.last.at.millisecondsSinceEpoch, 249);
  });

  test('records are retained oldest-first below the bound', () {
    final log = WatchTransitionLog();
    log
      ..add(_rec(1, kind: WatchTransition.armed))
      ..add(
        _rec(2, kind: WatchTransition.degradedToPolling, cause: 'ceiling 2/2'),
      );
    expect(log.records.map((r) => r.kind), [
      WatchTransition.armed,
      WatchTransition.degradedToPolling,
    ]);
    expect(log.records.last.cause, 'ceiling 2/2');
  });

  test('the discriminating fields survive a round trip', () {
    // H1 vs H3 is read off liveWatchers and restarts — MADR 0026's table.
    final log = WatchTransitionLog();
    log.add(
      _rec(
        1,
        kind: WatchTransition.degradedToPolling,
        cause: 'ceiling 2/2',
        liveWatchers: 2,
        restarts: 3,
      ),
    );
    final r = log.records.single;
    expect(r.liveWatchers, 2);
    expect(r.restarts, 3);
    expect(r.toString(), contains('ceiling 2/2'));
  });

  test('logs are per repo and independent', () {
    final d = WatchDiagnostics();
    d.forRepo('/a').add(_rec(1));
    d.forRepo('/b')
      ..add(_rec(2))
      ..add(_rec(3));
    expect(d.forRepo('/a').records, hasLength(1));
    expect(d.forRepo('/b').records, hasLength(2));
    expect(d.repoPaths, containsAll(<String>['/a', '/b']));
  });

  test('records are unmodifiable from outside', () {
    final log = WatchTransitionLog()..add(_rec(1));
    expect(() => log.records.add(_rec(2)), throwsUnsupportedError);
  });
}
