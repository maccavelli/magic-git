// MADR 0045 phase 1. What a watcher's stderr means, decided in one pure place.
// The readiness race (MADR 0044) and the incumbent's name (MADR 0043) both hang
// on reading it exactly.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/bounded_watch.dart';
import 'package:remote_magic_git/core/git/watch/source/remote/stderr_line_reader.dart';

void main() {
  StderrLineReader reader({int budget = 20}) =>
      StderrLineReader(maxDiagnosticLines: budget, maxBufferChars: 1 << 20);

  test('only the exact marker is a readiness marker', () {
    final lines = reader().add(
      '$watchArmedMarker\n$watchArmedMarker later\nSetting up watches.\n',
    );
    expect(lines.whereType<ReadinessMarker>(), hasLength(1));
    expect(lines.whereType<Diagnostic>().map((d) => d.line), [
      '$watchArmedMarker later',
    ], reason: 'a line that merely starts like the marker is not the marker');
  });

  test('the incumbent token is read from a refusal line', () {
    final lines = reader().add('mg-watch: lock held by abc123\n');
    expect(lines.whereType<LockHeldBy>().single.token, 'abc123');
    expect(
      lines.whereType<Diagnostic>().single.line,
      'mg-watch: lock held by abc123',
      reason: 'the user should see who holds the repository',
    );
  });

  test('startup chatter is dropped', () {
    expect(
      reader().add('Setting up watches.\nWatches established.\n'),
      isEmpty,
    );
  });

  test('diagnostics stop at the budget', () {
    final lines = reader(budget: 2).add('one\ntwo\nthree\n');
    expect(lines.whereType<Diagnostic>().map((d) => d.line), ['one', 'two']);
  });

  test('a line split across chunks is read once', () {
    final r = reader();
    expect(r.add('mg-watch: ar'), isEmpty);
    expect(r.add('med\n'), [isA<ReadinessMarker>()]);
  });
}
