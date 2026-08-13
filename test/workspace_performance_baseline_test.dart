import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/exec/command_telemetry.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/diff_view.dart';
import 'package:remote_magic_git/features/common/palette_models.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';
import 'package:remote_magic_git/features/repository/repo_change_filter.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';

const _phase0FilterBaselineMicros = 50000;
const _filterRegressionBudgetMicros =
    _phase0FilterBaselineMicros + _phase0FilterBaselineMicros ~/ 10;

int _payloadLength(String value) => value.length;

String _statusFixture(int count) {
  final output = StringBuffer()
    ..write('# branch.oid 0123456789abcdef\u0000')
    ..write('# branch.head main\u0000')
    ..write('# branch.upstream origin/main\u0000')
    ..write('# branch.ab +2 -1\u0000');
  for (var index = 0; index < count; index++) {
    output.write(
      '1 .M N... 100644 100644 100644 '
      '0123456789abcdef 0123456789abcdef '
      'lib/feature_$index/file_$index.dart\u0000',
    );
  }
  return output.toString();
}

String _diffFixture(int bodyLines) {
  final output = StringBuffer()
    ..write('diff --git a/huge.txt b/huge.txt\n')
    ..write('index 1111111..2222222 100644\n')
    ..write('--- a/huge.txt\n')
    ..write('+++ b/huge.txt\n')
    ..write('@@ -1,$bodyLines +1,$bodyLines @@\n');
  for (var index = 0; index < bodyLines; index++) {
    output.write(' context line $index\n');
  }
  return output.toString();
}

void main() {
  test('2,000-file porcelain fixture parses without loss', () {
    final fixture = _statusFixture(2000);
    final stopwatch = Stopwatch()..start();
    final status = GitPorcelainParser.parseV2(fixture);
    stopwatch.stop();

    debugPrint(
      'WORKSPACE_BASELINE status_parse_2000_us='
      '${stopwatch.elapsedMicroseconds}',
    );
    expect(status.files, hasLength(2000));
    expect(status.branch.head, 'main');
    expect(status.branch.ahead, 2);
    expect(status.branch.behind, 1);
    expect(status.parseWarnings, isEmpty);
  });

  test('20,000-line diff fixture parses and flattens without loss', () {
    final fixture = _diffFixture(20000);
    final stopwatch = Stopwatch()..start();
    final result = debugParseHunkDiff(fixture);
    stopwatch.stop();

    debugPrint(
      'WORKSPACE_BASELINE diff_parse_20000_us='
      '${stopwatch.elapsedMicroseconds}',
    );
    expect(result.parsed, isTrue);
    expect(result.hunks, 1);
    expect(result.items, 20001);
  });

  test('2,000-file filter stays within the Phase 0 +10% budget', () {
    final status = GitPorcelainParser.parseV2(_statusFixture(2000));
    final rows = deriveRepoChangeRows(status);
    const filter = RepoChangeFilter(
      query: 'feature_1',
      grouping: RepositoryChangeGrouping.directory,
    );
    // Warm the JIT and allocation paths before collecting a median.
    filterRepoChangeRows(rows, filter);
    final samples = <int>[];
    RepoChangeFilterResult? result;
    for (var run = 0; run < 7; run++) {
      final stopwatch = Stopwatch()..start();
      result = filterRepoChangeRows(rows, filter);
      stopwatch.stop();
      samples.add(stopwatch.elapsedMicroseconds);
    }
    samples.sort();
    final median = samples[samples.length ~/ 2];

    debugPrint(
      'WORKSPACE_GATE filter_2000_median_us=$median '
      'budget_us=$_filterRegressionBudgetMicros',
    );
    expect(result!.visibleFiles, 1111);
    expect(median, lessThanOrEqualTo(_filterRegressionBudgetMicros));
  });

  test('workspace paint and empty palette ranking add no command', () {
    CommandTelemetry.instance.reset();
    final ranked = rankPaletteEntries(const [
      PanelPaletteEntry(
        id: 'panel.repository',
        primaryLabel: 'Repository',
        panelIndex: 0,
      ),
    ], const PaletteQuery());

    expect(ranked, hasLength(1));
    expect(CommandTelemetry.instance.commandCount, 0);
  });

  test('20,000-line-class diff takes the off-isolate parser path', () async {
    final fixture = _diffFixture(20000);
    final completed = Completer<void>();
    final parser = DiffParser<int>(_payloadLength);
    final immediate = parser.parse(
      fixture,
      // flutter_test's custom zone may reject an isolate result. Both arms
      // prove that the parser left the synchronous UI-isolate path and
      // completed its guarded async lifecycle instead of hanging.
      onDone: (_) => completed.complete(),
      onFailed: completed.complete,
    );

    expect(diffLineCount(fixture), greaterThan(kDiffIsolateLineThreshold));
    expect(immediate, isNull);
    await completed.future;
  });
}
