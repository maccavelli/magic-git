// The HunkDiffView inline blame gutter: when blame is supplied, each line shows
// the commit that last touched it (mapped by new-file line number), collapsing
// runs of the same commit so a block reads as a block.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/repository/hunk_diff_view.dart';

const _diff =
    'diff --git a/f.dart b/f.dart\n'
    'index 111..222 100644\n'
    '--- a/f.dart\n'
    '+++ b/f.dart\n'
    '@@ -1,3 +1,3 @@\n'
    ' line one\n'
    '-line two old\n'
    '+line two new\n'
    ' line three\n';

// line 1 & 3 are commit A; the changed line 2 is commit B.
const _blame = [
  BlameLine(
    hash: 'aaaaaaa1111',
    author: 'Alice',
    date: '2024-01-01',
    summary: 'first',
    lineNumber: 1,
    content: 'line one',
  ),
  BlameLine(
    hash: 'bbbbbbb2222',
    author: 'Bob',
    date: '2024-02-02',
    summary: 'second',
    lineNumber: 2,
    content: 'line two new',
  ),
  BlameLine(
    hash: 'aaaaaaa1111',
    author: 'Alice',
    date: '2024-01-01',
    summary: 'first',
    lineNumber: 3,
    content: 'line three',
  ),
];

Future<void> _pump(WidgetTester tester, {List<BlameLine>? blame}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 600));
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(
        width: 1000,
        height: 600,
        child: HunkDiffView(
          diff: _diff,
          staged: false,
          onAction: (_, _, _) {},
          blame: blame,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no gutter without blame data', (tester) async {
    await _pump(tester);
    expect(find.text('aaaaaaa'), findsNothing);
  });

  testWidgets('shows the short hash of the commit that touched each line', (
    tester,
  ) async {
    await _pump(tester, blame: _blame);
    // Commit A heads line 1 and (after the B run) line 3; commit B heads the
    // changed line 2. Removed lines get no gutter entry.
    expect(find.text('aaaaaaa'), findsNWidgets(2));
    expect(find.text('bbbbbbb'), findsOneWidget);
    // The author date rides alongside the hash.
    expect(find.text('2024-02-02'), findsOneWidget);
  });
}
