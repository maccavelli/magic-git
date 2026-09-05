// MADR 0030 T1.3. Ordering invariants at seams between a component and the
// thing it launches or depends on.
//
// Defect 2 of the five was exactly this: the watcher's lease was stamped AFTER
// the script that checks for it was launched, so the script lost the race and
// exited in 5 ms — every arm. Each half was correct; the order was not, and
// nothing asserted an order.
//
// Invariant A (a scoped repo's env must reach the command that needs it) is
// NOT here: 0030 Phase 3 absorbed it as contract rows R2 and R5, which assert
// the merged env reaches both `execute` and `executeStream`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';

void main() {
  group('B — a watcher records its pid before it can be signalled', () {
    late Directory dir;
    late String shimDir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mg-order-');
      shimDir = '${dir.path}/bin';
      Directory(shimDir).createSync();
      Directory('${dir.path}/.git').createSync();
      // The shim reports whether the pid file existed AT THE MOMENT the
      // watcher binary started. That is the ordering question: a watcher the
      // sweep cannot name is a watcher it can never reclaim, which is what
      // made the host's orphans permanent (0027 amendment 0027.1).
      File('$shimDir/inotifywait').writeAsStringSync(
        '#!/bin/sh\n'
        'if [ -s "${dir.path}/.git/mg-watch.t.pid" ]; then\n'
        '  echo recorded >> "${dir.path}/order"\n'
        'else\n'
        '  echo MISSING >> "${dir.path}/order"\n'
        'fi\n'
        'sleep 0.2\n'
        'exit 2\n',
      );
      await Process.run('chmod', ['+x', '$shimDir/inotifywait']);
      File('${dir.path}/.git/mg-watch.t.hb').writeAsStringSync('');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('the pid file is populated before the watcher binary runs', () async {
      final p = await Process.start(
        'sh',
        [
          '-c',
          recursiveWatchScript(
            inotify: true,
            excludes: '',
            pidFile: '${dir.path}/.git/mg-watch.t.pid',
            heartbeat: '${dir.path}/.git/mg-watch.t.hb',
          ),
        ],
        workingDirectory: dir.path,
        environment: {'PATH': '$shimDir:${Platform.environment['PATH']}'},
      );
      addTearDown(() => p.kill(ProcessSignal.sigkill));

      for (var i = 0; i < 40; i++) {
        if (File('${dir.path}/order').existsSync()) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      final observed = File('${dir.path}/order').readAsLinesSync();
      expect(observed, isNotEmpty, reason: 'the shim must have run at all');
      expect(
        observed.first,
        'recorded',
        reason:
            'the pid must be on disk before the watcher starts; a watcher that '
            'runs before it is recorded is one the sweep can never reclaim',
      );
    });
  });

  group('C — forge reads wait for the connect-time login', () {
    // `_forgeAuthReady` holds a forge data provider until the session's
    // background CLI logins settle, so a panel visible at connect loads
    // against an authenticated CLI instead of flashing a transient auth
    // error. This asserts which providers honour it — an ordering property
    // between connect and the first gh/glab call.

    /// Providers that call a gh/glab service without awaiting the gate.
    ///
    /// Every entry is a REVIEWED decision, not a backlog. These are drill-in
    /// providers: nothing watches them until the user selects an issue, a
    /// milestone or a release, which cannot happen before connect completes.
    /// If one of them is ever watched from a restored selection at connect, it
    /// must move above this line and await the gate.
    const reviewedWithoutGate = <String>{
      'changeRequestCommentsProvider',
      'issueCommentsProvider',
      'issueDetailProvider',
      'projectLabelsProvider',
      'projectMilestonesProvider',
      'projectReleasesProvider',
    };

    test('every forge-reading provider awaits the gate or is reviewed', () {
      final src = File(
        'lib/core/providers/app_providers.dart',
      ).readAsStringSync();
      final decls = RegExp(
        r'^final (\w+Provider)\s*=',
        multiLine: true,
      ).allMatches(src).toList();

      final gated = <String>[];
      final ungated = <String>[];
      for (var i = 0; i < decls.length; i++) {
        final start = decls[i].start;
        final end = i + 1 < decls.length ? decls[i + 1].start : src.length;
        final body = src.substring(start, end);
        if (!RegExp(r'\b(gh|glab)\.\w+\(').hasMatch(body)) continue;
        (body.contains('_forgeAuthReady') ? gated : ungated).add(decls[i][1]!);
      }

      expect(gated, isNotEmpty, reason: 'the scan must find the gated ones');
      expect(
        ungated.toSet().difference(reviewedWithoutGate),
        isEmpty,
        reason:
            'a forge provider that reads before the connect-time login settles '
            'shows a transient auth error as its error state. Add the gate, or '
            'add it to reviewedWithoutGate with a reason: '
            '${ungated.toSet().difference(reviewedWithoutGate)}',
      );
      expect(
        reviewedWithoutGate.difference(ungated.toSet()),
        isEmpty,
        reason:
            'these are listed as reviewed-without-gate but now await it (or no '
            'longer read a forge): remove the stale entries',
      );
    });
  });
}
