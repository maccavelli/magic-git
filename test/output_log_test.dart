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
}
