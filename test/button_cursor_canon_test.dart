// Pins the canonical cursor policy for clickable controls (see
// lib/features/common/buttons.dart): every enabled button shows the macOS
// pointing hand. macos_ui buttons hardcode an inner basic-cursor MouseRegion,
// so the hand can only be injected via their `mouseCursor` parameter — which
// means the policy is enforceable only if call sites go through the canonical
// wrappers. This test scans the source so an off-policy button can't slip
// back in.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 'Push' + 'Button(' spliced so this file's own scan can't match its source.
final _rawPushButton = RegExp('(?<![A-Za-z_\$A])${'Push'}${'Button'}\\(');
final _iconButton = RegExp(r'(?<![A-Za-z_$])(MacosIconButton|HelpButton)\(');

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no raw macos_ui push button outside the AppPushButton wrapper', () {
    final offenders = <String>[];
    for (final f in _dartFiles()) {
      if (f.path.endsWith('lib/features/common/buttons.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (_rawPushButton.hasMatch(line)) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use AppPushButton (common/buttons.dart) so the canonical '
          'pointing-hand cursor applies. Raw push buttons found at:\n'
          '${offenders.join('\n')}',
    );
  });

  test('every raw MacosIconButton/HelpButton passes mouseCursor '
      'explicitly', () {
    final offenders = <String>[];
    for (final f in _dartFiles()) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (!_iconButton.hasMatch(lines[i])) continue;
        // The cursor argument must appear within the constructor call; a
        // 14-line window comfortably covers every real call shape here.
        final window = lines.skip(i).take(14).join('\n');
        if (!window.contains('mouseCursor:')) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'macos_ui icon buttons default to an arrow cursor; pass '
          'mouseCursor (hand when enabled — or use ToolIconButton, which '
          'does it for you). Missing at:\n${offenders.join('\n')}',
    );
  });
}
