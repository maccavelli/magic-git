// MADR 0029. Every shell script this app sends to a host must be either
// EXECUTED by a test or exempt with a written reason.
//
// The rule exists because `watcherSweepScript` shipped, passed its tests, and
// had never once been able to reclaim a process: its test asserted
// `contains('inotifywait')` and `contains('kill -TERM')`, both true, while the
// two halves contradicted each other. Substring matching cannot see that. A
// `contains(...)` on script text may pin COMPOSITION — a path was interpolated,
// a caller's flag came through — but never BEHAVIOUR.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Builders proven by a test that RUNS the script and observes its effect.
const _executed = <String>{
  'watcherSweepScript',
  'catFileBatchScript',
  'recursiveWatchScript',
  'boundedInotifyScript',
  'boundedFswatchScript',
};

/// Builders that cannot be executed on the development machine.
///
/// Every entry states why. **An entry is a debt, not a dismissal** — the point
/// of naming them is that "what is untested here" is answerable without an
/// audit.
const _exempt = <String, String>{
  'rootlessInstallScript':
      'Installs binaries into the developer machine. Executing it in a test '
      'would mutate the machine running the suite, which no test may do. This '
      'one is expected to remain exempt permanently; its composition is '
      'checked in install_planner_test.dart, and that is all a string '
      'assertion is allowed to claim (0029).',
};

/// Top-level Dart functions that build a shell script, found by reading the
/// source rather than from a hand-maintained list — a hand-list would be the
/// same class of check this record exists to constrain.
Set<String> findScriptBuilders(Directory root) {
  final re = RegExp(r'^String\s+(\w*Script)\s*\(', multiLine: true);
  final found = <String>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final m in re.allMatches(f.readAsStringSync())) {
      found.add(m[1]!);
    }
  }
  return found;
}

void main() {
  test(
    'every host-script builder is executed by a test or named as exempt',
    () {
      final builders = findScriptBuilders(Directory('lib'));
      expect(builders, isNotEmpty, reason: 'the scan must actually find them');

      final classified = {..._executed, ..._exempt.keys};
      final unclassified = builders.difference(classified);
      expect(
        unclassified,
        isEmpty,
        reason:
            'a new host script must be executed by a test or added to _exempt '
            'with a reason. Unclassified: $unclassified',
      );

      final both = _executed.intersection(_exempt.keys.toSet());
      expect(both, isEmpty, reason: 'a builder cannot be both: $both');

      final stale = classified.difference(builders);
      expect(
        stale,
        isEmpty,
        reason: 'these are classified but no longer exist: $stale',
      );
    },
  );

  test('every claim of "executed" is backed by a test that runs a process', () {
    // Keeps `_executed` honest: membership is verified, not asserted.
    for (final name in _executed) {
      final backing = Directory('test')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.readAsStringSync())
          .where((src) => src.contains(name))
          .where(
            (src) =>
                src.contains('Process.run') || src.contains('Process.start'),
          );
      expect(
        backing,
        isNotEmpty,
        reason:
            '$name is listed as executed, but no test both references it and '
            'starts a process',
      );
    }
  });

  test('every exemption states a reason', () {
    for (final e in _exempt.entries) {
      expect(
        e.value.trim().length,
        greaterThan(20),
        reason: '${e.key} is exempt without a real reason',
      );
    }
  });

  test('the scan reports an unclassified builder', () {
    // THE NEGATIVE CASE. Against a fixture, so lib/ is never dirtied.
    final tmp = Directory.systemTemp.createTempSync('mg-scan-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File(
      '${tmp.path}/thing.dart',
    ).writeAsStringSync('String brandNewScript(String a) => "echo \$a";\n');

    final found = findScriptBuilders(tmp);
    expect(
      found,
      contains('brandNewScript'),
      reason:
          'if the scan cannot see a new builder, it cannot enforce anything — '
          'this is the assertion that makes the other three mean something',
    );
    expect(found.difference({..._executed, ..._exempt.keys}), isNotEmpty);
  });
}
