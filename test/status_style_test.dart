// The shared git-status letter/color convention used by the working-tree
// badges and the file-view colored letters.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/status_style.dart';

void main() {
  test('gitStatusLetter maps status codes to letters + colors', () {
    (String, Color) g(String x, String y, {bool? staged}) => gitStatusLetter(
      GitFileStatus(path: 'f', statusX: x, statusY: y),
      staged: staged,
    );

    expect(g('?', '?'), ('U', MacosColors.systemGreenColor));
    expect(g('.', 'M'), ('M', MacosColors.systemYellowColor));
    expect(g('A', '.', staged: true), ('A', MacosColors.systemGreenColor));
    expect(g('.', 'D'), ('D', MacosColors.systemRedColor));
    expect(g('R', '.', staged: true), ('R', MacosColors.systemTealColor));
    // Staged add that was then modified in the worktree: the staged section
    // reads A, the changes section reads M.
    expect(g('A', 'M', staged: true), ('A', MacosColors.systemGreenColor));
    expect(g('A', 'M', staged: false), ('M', MacosColors.systemYellowColor));
    // Unmerged (both sides) → conflict.
    expect(g('U', 'U'), ('!', MacosColors.systemRedColor));
  });

  testWidgets('GitStatusBadge renders the letter in its status color', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MacosApp(
        debugShowCheckedModeBanner: false,
        home: Center(
          child: GitStatusBadge(
            GitFileStatus(path: 'f', statusX: '.', statusY: 'M'),
            staged: false,
          ),
        ),
      ),
    );
    expect(find.text('M'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('M')).style?.color,
      MacosColors.systemYellowColor,
    );
  });
}
