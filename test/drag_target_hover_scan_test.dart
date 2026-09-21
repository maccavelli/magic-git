// MADR 0064 F2 (Confirmation 2): every drop target for the app's drag payload
// reports hover, so the drag image can collapse to its compact chip and stop
// hiding the target under the pointer.
//
// A `DragTarget<DragItem>` that never calls `setOverTarget` would bring the
// occlusion back for that one target, silently. This scan finds every such
// target in lib/ and requires both halves of the report; it also pins the set
// of files, so adding a target is a conscious decision, not an accident.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _marker = 'DragTarget<DragItem>';

/// The drop targets known when F2 landed. A new one must be added here, and
/// must report hover like these do.
const _knownTargets = {
  'lib/features/dnd/drop_zone.dart',
  'lib/features/branches/branch_navigator.dart',
  'lib/features/history/history_view.dart',
  'lib/features/dnd/staging_drop_banner.dart',
};

/// Every .dart file under lib/, as a POSIX path relative to the package root.
List<File> _libDartFiles() {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    throw StateError('lib/ not found: run from the package root');
  }
  return [
    for (final entity in lib.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];
}

String _posix(File file) => file.path.replaceAll(r'\', '/');

void main() {
  late List<File> files;
  late Set<String> targets;

  setUpAll(() {
    files = _libDartFiles();
    targets = {
      for (final file in files)
        if (file.readAsStringSync().contains(_marker)) _posix(file),
    };
  });

  test('the scan actually read lib/', () {
    // A scan that found nothing to read would pass every check below.
    expect(files.length, greaterThan(100));
    expect(targets, isNotEmpty);
  });

  test('the DragTarget<DragItem> sites are exactly the known four', () {
    expect(
      targets,
      equals(_knownTargets),
      reason:
          'A drop target was added or removed. Make it report hover '
          '(setOverTarget(true) in onMove, setOverTarget(false) in onLeave '
          'and on accept), then update _knownTargets.',
    );
  });

  test('every DragTarget<DragItem> reports hover both ways', () {
    final missing = <String>[];
    for (final path in targets.toList()..sort()) {
      final source = File(path).readAsStringSync();
      for (final call in const [
        'setOverTarget(true)',
        'setOverTarget(false)',
      ]) {
        if (!source.contains(call)) missing.add('$path: no $call');
      }
    }
    expect(missing, isEmpty);
  });
}
