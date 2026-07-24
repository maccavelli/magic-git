// The date-misread warning in the History filter bar: git's date parser never
// rejects input (garbage → "now", year past 2099 → the current year — see
// dateTermProblem and log_search_integration_test), so the ONLY user-visible
// truth about a mistyped date is this caption. It must appear for a typed
// `after:`/`before:` term while the advanced row is collapsed, and disappear
// when the date is corrected.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubGit extends GitService {
  _StubGit() : super(SSHCommandExecutor(SSHClientManager()));

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => const [];

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];
}

void main() {
  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(_StubGit()),
        repoWatchProvider.overrideWith((ref, repoPath) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: HistoryView(repoPath: '/srv/repo'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(MacosTextField).first, text);
    await tester.pump(const Duration(milliseconds: 400)); // filter debounce
    await tester.pumpAndSettle();
  }

  testWidgets('a year git would coerce is flagged, and correcting clears it', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('1970–2099'), findsNothing);

    // Typed term — the advanced row is collapsed, the warning must not be.
    await type(tester, 'after:2990-01-01');
    expect(find.textContaining('1970–2099'), findsOneWidget);

    await type(tester, 'after:2026-01-01');
    expect(find.textContaining('1970–2099'), findsNothing);
  });

  testWidgets('an impossible calendar date is flagged', (tester) async {
    await pump(tester);
    await type(tester, 'before:2026-13-01');
    expect(find.textContaining('not a real calendar date'), findsOneWidget);

    // git's phrase grammar is not ours to judge — no warning.
    await type(tester, 'before:"2 weeks ago"');
    expect(find.textContaining('not a real calendar date'), findsNothing);
  });
}
