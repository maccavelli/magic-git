import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';

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
}
