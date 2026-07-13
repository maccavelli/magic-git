// Unit test for OutputLogNotifier.logFiles: header, pretty rename arrow, and
// per-line color kinds by change type.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/output/output_log.dart';

void main() {
  test('logFiles formats a header and color-coded file lines', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);

    log.logFiles('Pushed', const [
      'A\tlib/a.dart',
      'M\tlib/b.dart',
      'D\told.dart',
      'R100\tfrom.dart\tto.dart',
      '', // blank lines are ignored
    ]);

    final lines = container.read(outputLogProvider).lines;
    final texts = lines.map((l) => l.text).toList();

    expect(texts.first, 'Pushed — 4 files');
    expect(texts.any((t) => t.contains('lib/a.dart')), isTrue);
    expect(texts.any((t) => t.contains('from.dart → to.dart')), isTrue);

    OutputLineKind kindOf(String needle) =>
        lines.firstWhere((l) => l.text.contains(needle)).kind;
    expect(kindOf('lib/a.dart'), OutputLineKind.success); // A → green
    expect(kindOf('lib/b.dart'), OutputLineKind.stderr); // M → yellow
    expect(kindOf('old.dart'), OutputLineKind.error); // D → red
  });

  test('logFiles is a no-op for an all-empty list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);
    log.logFiles('Pulled', const ['', '   ']);
    expect(container.read(outputLogProvider).lines, isEmpty);
  });

  test('appending still signals a change once the scrollback is full', () {
    // The output view follows the tail by listening for a change to this signal.
    // It used to listen on `lines.length` — which stops changing the moment the
    // buffer caps, because every append then also drops a line. So after 2000
    // lines (one long clone, or a busy session) the view silently stopped
    // scrolling to new output: it was still arriving, just never followed.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = container.read(outputLogProvider.notifier);

    var notified = 0;
    final sub = container.listen(
      outputLogProvider.select((s) => s.revision),
      (_, _) => notified++,
    );
    addTearDown(sub.close);

    for (var i = 0; i < OutputLogNotifier.maxLines; i++) {
      log.logInfo('line $i');
    }
    expect(
      container.read(outputLogProvider).lines,
      hasLength(OutputLogNotifier.maxLines),
      reason: 'the buffer is now full — the line count can no longer grow',
    );
    final whenFull = notified;

    for (var i = 0; i < 20; i++) {
      log.logInfo('overflow $i');
    }
    expect(
      notified - whenFull,
      20,
      reason: 'every appended line must still notify the tail-follower',
    );
    expect(container.read(outputLogProvider).lines.last.text, 'overflow 19');
  });
}
