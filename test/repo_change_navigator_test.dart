import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/repository/repo_change_filter.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';
import 'package:remote_magic_git/features/repository/repo_change_navigator.dart';

Future<void> _pump(
  WidgetTester tester, {
  required TextEditingController controller,
  required RepoChangeFilter filter,
  required ValueChanged<RepoChangeFilter> onFilterChanged,
  RepositoryNavigatorMode mode = RepositoryNavigatorMode.changes,
  int hidden = 0,
}) async {
  await tester.pumpWidget(
    MacosApp(
      home: SizedBox(
        width: 420,
        height: 500,
        child: RepoChangeNavigator(
          mode: mode,
          onModeChanged: (_) {},
          filterController: controller,
          filter: filter,
          onFilterChanged: onFilterChanged,
          visibleCount: 2,
          totalCount: 4,
          hiddenSelectionCount: hidden,
          onRevealSelection: () {},
          onClearSelection: () {},
          changes: const Text('changes-body'),
          files: const Text('files-body'),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Escape clears filter before list selection can dismiss', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'dart');
    addTearDown(controller.dispose);
    RepoChangeFilter? next;
    await _pump(
      tester,
      controller: controller,
      filter: const RepoChangeFilter(query: 'dart'),
      onFilterChanged: (value) => next = value,
    );

    await tester.tap(find.byType(MacosTextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(next?.query, isEmpty);
  });

  testWidgets(
    'mode swaps one navigator body and hidden selection is explicit',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        controller: controller,
        filter: const RepoChangeFilter(),
        onFilterChanged: (_) {},
        mode: RepositoryNavigatorMode.files,
        hidden: 3,
      );

      expect(find.text('files-body'), findsOneWidget);
      expect(find.text('changes-body'), findsNothing);
      expect(
        find.textContaining('3 selected items are hidden'),
        findsOneWidget,
      );
      expect(find.text('Reveal'), findsOneWidget);
      expect(find.text('Clear Selection'), findsOneWidget);
    },
  );

  Finder tooltip(String message) =>
      find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

  testWidgets('status filters are distinct filled glyphs with section colors', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    RepoChangeFilter? next;
    await _pump(
      tester,
      controller: controller,
      filter: const RepoChangeFilter(),
      onFilterChanged: (value) => next = value,
    );

    Finder macosIcon(IconData icon) =>
        find.byWidgetPredicate((w) => w is MacosIcon && w.icon == icon);

    expect(
      macosIcon(CupertinoIcons.exclamationmark_triangle_fill),
      findsOneWidget,
    );
    expect(macosIcon(CupertinoIcons.checkmark_alt_circle_fill), findsOneWidget);
    expect(macosIcon(CupertinoIcons.pencil_circle_fill), findsOneWidget);
    expect(macosIcon(CupertinoIcons.plus_square_fill), findsOneWidget);
    expect(tooltip('Show only Conflicts'), findsOneWidget);
    expect(tooltip('Show only Unstaged'), findsOneWidget);

    await tester.tap(macosIcon(CupertinoIcons.exclamationmark_triangle_fill));
    await tester.pump();
    expect(next?.statuses, {RepoChangeSection.conflict});
  });
}
