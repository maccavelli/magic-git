// The Connections panel's "Local Repositories" section: a header + a tile
// per saved local repo, and the "New local repository" toolbar button
// opening the picker sheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ToolIconButton wraps MacosTooltip (not Flutter's standard Tooltip), so
// find.byTooltip doesn't match it — match on the tooltip message directly.
Finder _byMacosTooltip(String message) =>
    find.byWidgetPredicate((w) => w is MacosTooltip && w.message == message);

Future<void> _pump(
  WidgetTester tester, {
  List<SavedLocalRepo> savedLocal = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedLocalReposProvider.overrideWith((ref) async => savedLocal),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: ConnectionsPanel(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the empty state with no saved connections at all', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('No saved connections'), findsOneWidget);
    expect(find.text('Local Repositories'), findsNothing);
  });

  testWidgets(
    'shows a "Local Repositories" section with a tile per saved repo',
    (tester) async {
      await _pump(
        tester,
        savedLocal: const [
          SavedLocalRepo(id: 'l1', label: 'My Project', repoPath: '/a/b/proj'),
          SavedLocalRepo(id: 'l2', label: '', repoPath: '/a/b/other-repo'),
        ],
      );

      expect(find.text('Local Repositories'), findsOneWidget);
      expect(find.text('My Project'), findsOneWidget);
      // No label given — falls back to the folder's basename.
      expect(find.text('other-repo'), findsOneWidget);
    },
  );

  testWidgets('New local repository opens the picker sheet', (tester) async {
    await _pump(tester);
    expect(find.text('Add Local Repository'), findsNothing);

    await tester.tap(_byMacosTooltip('New local repository'));
    await tester.pumpAndSettle();

    expect(find.text('Add Local Repository'), findsOneWidget);
  });
}
