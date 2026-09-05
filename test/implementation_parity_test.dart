// MADR 0030 T1.2. When one abstraction has several implementations, tests must
// not cover a subset of them.
//
// That is shape C, and it produced a real defect: the watcher transition log
// was wired into `RemoteWatchService` and not `LocalWatchService`, so repos on
// this Mac were silent while repos on the host reported — with a green suite
// (0026 deviation (c)).
//
// This is a NAME-COUNTING scan and its limit is stated rather than implied: it
// catches "no test mentions this implementation at all". It cannot tell whether
// the tests that do mention one assert anything about it. Real parity is
// asserted by `executor_contract_test.dart`, which runs one body against every
// implementation.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `implements <Abstraction>` occurrences, as {abstraction: {class names}}.
///
/// Grouped by the name as **written**, so a class implementing a typedef alias
/// lands in its own group: `_ProcessStreamHandle implements SSHStreamHandle`
/// does not join the `CommandStreamHandle` seam even though the two names are
/// the same type. It is private and therefore exempt either way, so this costs
/// nothing today — but a public class written against an alias would slip the
/// rule, and that is worth knowing before it happens.
Map<String, Set<String>> findImplementations(Directory root) {
  final decl = RegExp(
    r'^class\s+(\w+)[^{]*?\bimplements\s+([\w\s,<>]+?)\s*\{',
    multiLine: true,
  );
  final out = <String, Set<String>>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final m in decl.allMatches(f.readAsStringSync())) {
      final impl = m[1]!;
      for (final raw in m[2]!.split(',')) {
        final abstraction = raw.trim().split('<').first.trim();
        if (abstraction.isEmpty) continue;
        (out[abstraction] ??= <String>{}).add(impl);
      }
    }
  }
  return out;
}

/// Abstractions whose implementations are a detail rather than a seam —
/// `Exception` subclasses are not a contract anyone tests for parity.
const _notSeams = <String>{'Exception', 'Comparable', 'Sink'};

/// The rule, with its inputs injected so it can be driven over a fixture rather
/// than only over the real tree. Without that the negative case below could not
/// exist, and this file would assert a coincidence.
({List<String> unnamed, List<String> privateExempt}) applyRule(
  Map<String, Set<String>> impls,
  int Function(String symbol) namingCount,
) {
  final unnamed = <String>[];
  final privateExempt = <String>[];
  for (final e in impls.entries) {
    if (_notSeams.contains(e.key) || e.value.length < 2) continue;
    for (final impl in e.value) {
      if (impl.startsWith('_')) {
        // A private class cannot be named by a test by construction. Listed,
        // not silently skipped — its parity rides on the public factory that
        // hands it out.
        privateExempt.add('${e.key}.$impl');
        continue;
      }
      if (namingCount(impl) == 0) unnamed.add('${e.key}.$impl');
    }
  }
  return (unnamed: unnamed, privateExempt: privateExempt);
}

int testFilesNaming(String symbol) => Directory('test')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => f.readAsStringSync().contains(symbol))
    .length;

void main() {
  test('every public implementation of a multi-impl abstraction is named by a '
      'test', () {
    final impls = findImplementations(Directory('lib'));
    final seams = {
      for (final e in impls.entries)
        if (!_notSeams.contains(e.key) && e.value.length > 1) e.key: e.value,
    };
    expect(
      seams,
      isNotEmpty,
      reason: 'the scan must find the multi-implementation seams at all',
    );

    final result = applyRule(impls, testFilesNaming);
    // ignore: avoid_print
    print('SEAMS: ${seams.map((k, v) => MapEntry(k, v.length))}');
    // ignore: avoid_print
    print('PRIVATE (exempt by construction): ${result.privateExempt}');

    expect(
      result.unnamed,
      isEmpty,
      reason:
          'these implement an abstraction that has siblings, and no test names '
          'them — the condition that let one watch service be instrumented and '
          'the other not:\n${result.unnamed.join('\n')}',
    );
  });

  test('the rule flags a sibling that no test names', () {
    // THE NEGATIVE CASE, over a fixture so lib/ is never dirtied, and with the
    // naming function stubbed so it cannot accidentally find this very file.
    final tmp = Directory.systemTemp.createTempSync('mg-parity-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/a.dart').writeAsStringSync(
      'class Alpha implements Seam {}\n'
      'class Beta implements Seam {}\n'
      'class _Gamma implements Seam {}\n',
    );

    final found = findImplementations(tmp);
    expect(found['Seam'], containsAll(<String>['Alpha', 'Beta', '_Gamma']));

    final flagged = applyRule(found, (s) => s == 'Alpha' ? 1 : 0);
    expect(
      flagged.unnamed,
      ['Seam.Beta'],
      reason:
          'if the rule cannot flag a sibling that no test names, the live '
          'assertion above is a coincidence that holds today',
    );
    expect(flagged.privateExempt, [
      'Seam._Gamma',
    ], reason: 'and a private sibling is listed, not silently dropped');

    // It must also NOT flag one that is named.
    expect(applyRule(found, (_) => 1).unnamed, isEmpty);
  });
}
