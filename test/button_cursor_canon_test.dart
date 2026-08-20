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

final _gestureDetector = RegExp(r'(?<![A-Za-z_$])GestureDetector\(');

/// A checkbox/radio glyph used without the labelled wrapper. On macOS the
/// label is part of an NSButton, so a bare glyph beside an inert Text drops
/// behaviour the platform provides. See common/labeled_controls.dart.
final _bareToggle = RegExp(
  r'(?<![A-Za-z_$])(MacosCheckbox\(|MacosRadioButton<)',
);

/// Files allowed to use the bare glyph, with how many sites. A control with
/// genuinely no label (nothing for the user to click) is the only legitimate
/// case; add it here with a reason rather than weakening the wrapper.
const _bareToggleAllowance = <String, int>{};

/// Files allowed to keep bare `GestureDetector(onTap:)` sites, with how many.
/// Two legitimate reasons exist: an invisible dismiss scrim (no affordance —
/// the arrow is correct), and a row inside `DragItemDraggable` (whose
/// grab-cursor MouseRegion must stay the deepest region under the pointer; a
/// Tappable inside it would steal the cursor back to the pointing hand).
/// A new bare site in one of these files pushes the count past its allowance
/// and fails — use Tappable (common/tappable.dart) instead.
const _bareTapAllowance = {
  'lib/features/common/context_menu.dart': 1, // menu-dismiss scrim
  'lib/features/connection/connection_landing.dart': 1, // menu-dismiss scrim
  'lib/features/repository/repo_status_view.dart': 1, // draggable file row
  'lib/features/history/history_view.dart': 1, // draggable commit row
  'lib/features/stash/stash_view.dart': 1, // draggable stash row
  'lib/features/branches/branches_view.dart': 1, // draggable branch row
};

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

  test('tappable surfaces use Tappable, not a bare GestureDetector', () {
    final sites = <String, List<int>>{};
    for (final f in _dartFiles()) {
      if (f.path.endsWith('lib/features/common/tappable.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (!_gestureDetector.hasMatch(lines[i])) continue;
        // Same 14-line window as above. `onTap:` can't false-match onTapDown:
        // (the colon) or onDoubleTap: (the capital T).
        final window = lines.skip(i).take(14).join('\n');
        if (window.contains('onTap:')) {
          (sites[f.path] ??= []).add(i + 1);
        }
      }
    }
    final offenders = <String>[];
    for (final entry in sites.entries) {
      final allowed = _bareTapAllowance[entry.key] ?? 0;
      if (entry.value.length > allowed) {
        offenders.add(
          '${entry.key}: lines ${entry.value.join(', ')} '
          '(${entry.value.length} bare, $allowed allowed)',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A clickable surface must show the pointing hand — use Tappable '
          '(common/tappable.dart) instead of a bare GestureDetector(onTap:). '
          'Deliberate arrow surfaces (scrims, rows inside DragItemDraggable) '
          'go in _bareTapAllowance with a reason. Found:\n'
          '${offenders.join('\n')}',
    );
  });

  test('checkbox and radio labels go through the labelled wrapper', () {
    final sites = <String, List<int>>{};
    for (final f in _dartFiles()) {
      if (f.path.endsWith('lib/features/common/labeled_controls.dart')) {
        continue;
      }
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (_bareToggle.hasMatch(lines[i])) {
          (sites[f.path] ??= []).add(i + 1);
        }
      }
    }
    final offenders = <String>[];
    for (final entry in sites.entries) {
      final allowed = _bareToggleAllowance[entry.key] ?? 0;
      if (entry.value.length > allowed) {
        offenders.add(
          '${entry.key}: lines ${entry.value.join(', ')} '
          '(${entry.value.length} bare, $allowed allowed)',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use LabeledCheckbox / LabeledRadio (common/labeled_controls.dart) '
          'so the label is clickable, the way an AppKit checkbox or radio '
          'title is. A control with no label at all goes in '
          '_bareToggleAllowance with a reason. Found:\n'
          '${offenders.join('\n')}',
    );
  });
}
