// History search in the REAL app runtime: actual Flutter engine on macOS,
// real platform channels, real subprocess IO, real debounce timers — none of
// the fake-async accommodations the widget-test twin
// (test/history_search_e2e_test.dart) needs. If search misbehaves only in the
// running app, this is where it shows.
//
// Run: flutter test integration_test/history_search_test.dart -d macos
//
// NOTE: on a machine with no code-signing identity this build fails on the
// keychain-access-groups entitlement (same wall as `flutter build macos`;
// see build_macos.sh --unsigned). Temporarily deleting that key — and
// com.apple.security.app-sandbox, which would block this test's temp-dir git
// repos anyway — from macos/Runner/DebugProfile.entitlements lets it run;
// restore the file afterwards (it is committed).

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String repo;

  Future<void> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
  }

  Future<void> commitFile(String path, String content, String message) async {
    final file = File('$repo/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    await raw(['add', '--all']);
    await raw(['commit', '-q', '-m', message]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('history_int_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Mac Smith']);
    await raw(['config', 'user.email', 'mac@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await commitFile('lib/a.dart', 'a\n', 'feat: first feature');
    await commitFile('lib/b.dart', 'b\n', 'fix [WIP] patch collapse');
    await commitFile('docs/c.md', 'c\n', 'docs: user guide');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  /// Pumps real frames until [until] matches or the deadline passes.
  Future<void> settleUntil(
    WidgetTester tester,
    Finder until, {
    Duration deadline = const Duration(seconds: 20),
  }) async {
    final sw = Stopwatch()..start();
    while (until.evaluate().isEmpty) {
      if (sw.elapsed > deadline) {
        fail('nothing matched $until within $deadline');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(
          GitService(LocalCommandExecutor()),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: HistoryView(repoPath: repo),
        ),
      ),
    );
    await settleUntil(tester, find.text('feat: first feature'));
  }

  /// Types into the real filter field and waits out the real 350ms debounce.
  Future<void> filter(WidgetTester tester, String text, Finder until) async {
    await tester.enterText(find.byType(MacosTextField).first, text);
    await settleUntil(tester, until);
  }

  testWidgets('typing narrows, footer counts, clearing restores', (
    tester,
  ) async {
    await pumpHistory(tester);
    expect(find.text('docs: user guide'), findsOneWidget);

    await filter(tester, 'collapse', find.text('1 matching commit'));
    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('feat: first feature'), findsNothing);

    await filter(tester, '[WIP]', find.text('1 matching commit'));
    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);

    await filter(tester, 'file:b.dart', find.text('1 matching commit'));
    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);

    await filter(
      tester,
      'zzz-nothing-matches',
      find.text('No matching commits'),
    );

    await filter(tester, '', find.text('docs: user guide'));
    expect(find.text('feat: first feature'), findsOneWidget);
  });

  testWidgets('sha: finds a commit by prefix in the real runtime', (
    tester,
  ) async {
    final r = await Process.run('git', [
      'rev-parse',
      'HEAD~1',
    ], workingDirectory: repo);
    final prefix = (r.stdout as String).trim().substring(0, 8);

    await pumpHistory(tester);
    await filter(tester, 'sha:$prefix', find.text('1 matching commit'));
    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('docs: user guide'), findsNothing);
  });
}
