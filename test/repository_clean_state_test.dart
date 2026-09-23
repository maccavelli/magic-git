// The clean working tree shows the green check and "Working tree clean", and
// nothing else. The branch and the last commit's subject used to sit beneath
// it; after a commit that repeated what the Output panel already says (MADR
// 0005, Amendment 0005.2).

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/repository/repository_clean_state.dart';

void main() {
  testWidgets('shows only the check and "Working tree clean"', (tester) async {
    await tester.pumpWidget(
      const MacosApp(
        home: MacosWindow(child: RepositoryCleanState(branchLabel: 'main')),
      ),
    );

    expect(find.text('Working tree clean'), findsOneWidget);
    final icon = tester.widget<MacosIcon>(find.byType(MacosIcon));
    expect(icon.icon, CupertinoIcons.check_mark_circled);
    expect(icon.color, MacosColors.systemGreenColor);
    // Nothing beneath the headline: no branch name, no commit subject.
    expect(find.text('main'), findsNothing);
    expect(find.byType(Text), findsOneWidget);
    // The branch stays in the accessibility label, where it costs nothing.
    expect(find.bySemanticsLabel('Working tree clean on main'), findsOneWidget);
  });
}
