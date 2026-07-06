// BlameSheet's gutter grouping: consecutive lines from the same commit show
// the commit info (short hash/author/date) only once, at the start of each
// run. Regression coverage for computing this as a pure function of the line
// list (precomputed once) rather than a closure-mutated "previous hash"
// tracked inside ListView.builder's itemBuilder, which isn't guaranteed to
// run in strict forward index order.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/repository/blame_sheet.dart';

const _repo = '/repo';
const _path = 'lib/a.dart';

BlameLine _line(String hash, int lineNumber, String content) => BlameLine(
  hash: hash,
  author: 'Author $hash',
  date: '2026-07-0${hash == 'aaaaaaa1111111' ? 1 : 2}',
  summary: 'subject',
  lineNumber: lineNumber,
  content: content,
);

void main() {
  testWidgets(
    'gutter metadata shows once per commit run, not once per line',
    (tester) async {
      // Three runs: A (x2), B (x1), A again (x2) — a real reuse of the same
      // commit hash in a later, non-adjacent run, which must still show its
      // own metadata (it's a new run, even though hash "aaaaaaa1111111" was
      // seen before).
      final lines = [
        _line('aaaaaaa1111111', 1, 'one'),
        _line('aaaaaaa1111111', 2, 'two'),
        _line('bbbbbbb2222222', 3, 'three'),
        _line('aaaaaaa1111111', 4, 'four'),
        _line('aaaaaaa1111111', 5, 'five'),
      ];
      final container = ProviderContainer(
        overrides: [
          blameProvider((_repo, _path)).overrideWith((ref) async => lines),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: BlameSheet(repoPath: _repo, path: _path),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The short hash is the first 7 characters, shown once per run: for
      // "aaaaaaa1111111" that's exactly twice (run 1 and run 3), even though
      // 4 of the 5 lines share that commit.
      expect(find.text('aaaaaaa'), findsNWidgets(2));
      expect(find.text('bbbbbbb'), findsOneWidget);

      // Every line's own content and line number still render regardless.
      for (final content in ['one', 'two', 'three', 'four', 'five']) {
        expect(find.text(content), findsOneWidget);
      }
    },
  );

  testWidgets(
    'an abbreviated (<7 char) or empty hash renders without a RangeError',
    (tester) async {
      // git can hand back short/empty hashes (e.g. uncommitted "boundary"
      // lines); the gutter's substring(0, 7) must not throw on them.
      final lines = [
        _line('abc', 1, 'short'),
        _line('', 2, 'empty'),
      ];
      final container = ProviderContainer(
        overrides: [
          blameProvider((_repo, _path)).overrideWith((ref) async => lines),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: BlameSheet(repoPath: _repo, path: _path),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The short hash renders verbatim (not truncated) rather than crashing.
      expect(find.text('abc'), findsOneWidget);
    },
  );
}
