// The History filter, driven end to end: a real repo on disk, the real
// GitService + LocalCommandExecutor, and text typed into the real filter
// field. history_paging_test.dart proves the panel's wiring against a fake
// git; log_search_integration_test.dart proves the service against real git;
// this closes the loop — keystrokes → debounce → parseLogFilter → LogQuery →
// real `git log` → rows and footer count on screen, including the graph build
// over a FILTERED (disconnected) commit list.
//
// The zone dance: testWidgets runs in a fake-async zone where a subprocess
// started from widget build never completes (its callbacks are stuck on the
// fake microtask queue). So each expected LogQuery is PRE-WARMED through
// `tester.runAsync` — the provider fetch runs and lands in the real zone —
// and the typed interaction then re-keys the widget onto an already-settled
// provider. The keystroke path is still fully exercised; only the fetch's
// completion is moved somewhere it can actually happen.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late String repo;
  late ProviderContainer container;
  final keepAlive = <ProviderSubscription<Object?>>[];

  Future<void> raw(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: repo);
    expect(
      result.exitCode,
      0,
      reason: 'setup `git ${args.join(' ')}` failed: ${result.stderr}',
    );
  }

  Future<void> commitFile(
    String path,
    String content,
    String message, {
    String? author,
  }) async {
    final file = File('$repo/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    await raw(['add', '--all']);
    await raw([
      'commit',
      '-q',
      '-m',
      message,
      if (author != null) '--author=$author',
    ]);
  }

  LogQuery query({String? grep, String? path, String? sha}) => (
    repoPath: repo,
    grep: grep,
    author: null,
    since: null,
    until: null,
    path: path,
    sha: sha,
    noMerges: false,
    // Must match the historyAllBranches value seeded in SharedPreferences
    // above, otherwise the widget computes a different LogQuery key than the
    // one the test warmed and gets a loading spinner instead of data.
    all: false,
    revision: null,
  );

  setUp(() async {
    // macos_ui's AccentColorListener calls a real platform channel at MacosApp
    // mount. In an ordinary widget test the unanswered call never resolves;
    // under `runAsync` (which this file needs for real git IO) the
    // MissingPluginException actually surfaces and fails the test — answer it.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('appkit_ui_element_colors'),
      (call) async => <String, double>{'hueComponent': 0.6},
    );
    // Seed SharedPreferences with a known historyAllBranches value so the
    // HistoryView's _query computes the same LogQuery key the tests warm.
    SharedPreferences.setMockInitialValues({
      'historyAllBranches': false,
    });

    tempDir = Directory.systemTemp.createTempSync('history_e2e_');
    repo = '${tempDir.resolveSymbolicLinksSync()}/repo';
    Directory(repo).createSync(recursive: true);
    await raw(['init', '-q', '-b', 'main']);
    await raw(['config', 'user.name', 'Mac Smith']);
    await raw(['config', 'user.email', 'mac@example.com']);
    await raw(['config', 'commit.gpgsign', 'false']);
    await commitFile('lib/a.dart', 'a\n', 'feat: first feature');
    await commitFile('lib/b.dart', 'b\n', 'fix [WIP] patch collapse');
    await commitFile('docs/c.md', 'c\n', 'docs: user guide');
    // 'decade' is all hex digits — the bare-hash fallback's word case — and
    // the distinct author feeds the spaced `author:` form.
    await commitFile(
      'lib/d.dart',
      'd\n',
      'perf: decade of cleanup',
      author: 'Other Dev <other@example.com>',
    );

    container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(
          GitService(LocalCommandExecutor()),
        ),
        // The HistoryView listens to repoWatchProvider to refresh on file-
        // system changes. Without an override, it cascades into
        // connectionProvider which tries to resolve a real connection.
        // An empty stream (matching the secondary window's approach) keeps
        // the widget happy without spawning real file watchers.
        repoWatchProvider.overrideWith(
          (ref, repoPath) => const Stream<RepoWatchEvent>.empty(),
        ),
      ],
    );
  });

  tearDown(() {
    for (final sub in keepAlive) {
      sub.close();
    }
    keepAlive.clear();
    container.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// Runs the real `git log` for [q] in the real zone and pins the result so
  /// autoDispose can't drop it before the widget watches the same key.
  ///
  /// The listen must ALSO happen inside runAsync: listening is what creates
  /// the notifier and starts its fetch, and a subprocess started in the fake
  /// zone never completes — the exact trap this helper exists to avoid.
  Future<void> warm(WidgetTester tester, LogQuery q) async {
    await tester.runAsync(() async {
      keepAlive.add(container.listen(logSearchProvider(q), (_, _) {}));
      await container.read(logSearchProvider(q).future);
    });
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Refs feed the decoration chips; left to the widget's own watch they'd
    // start a for-each-ref subprocess from the fake zone, whose lane-watchdog
    // timer is still pending at teardown and trips the binding's invariant.
    await tester.runAsync(() async {
      keepAlive.add(container.listen(refsProvider(repo), (_, _) {}));
      await container.read(refsProvider(repo).future);
    });
    await warm(tester, query());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          // isActive: false skips the commit-patch PREFETCH, whose real
          // subprocesses would start in the fake zone: they never complete
          // there, and their lane-watchdog timers are still pending at
          // teardown, tripping the binding's timer invariant. Filtering
          // itself doesn't read isActive.
          home: HistoryView(repoPath: repo, isActive: false),
        ),
      ),
    );
    // AppSettings loads prefs async; rebuild onto the warmed LogQuery key.
    await tester.pump();
    await tester.pump();
    expect(find.text('feat: first feature'), findsOneWidget);
    expect(find.text('docs: user guide'), findsOneWidget);
  }

  /// Real git via [LocalCommandExecutor] schedules command-lane watchdog
  /// timers (60s/90s) in the fake-async zone. Advance past them before the
  /// test returns so the binding does not assert pending timers on teardown.
  Future<void> drainLaneWatchdogs(WidgetTester tester) async {
    await tester.pump(const Duration(minutes: 2));
  }

  /// Types [text] into the filter field and rides out the 350ms debounce; the
  /// query it produces must have been [warm]ed.
  Future<void> filter(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(MacosTextField).first, text);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('free text narrows the list to matching commits', (tester) async {
    await pump(tester);
    await warm(tester, query(grep: 'collapse'));

    await filter(tester, 'collapse');

    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('feat: first feature'), findsNothing);
    expect(find.text('docs: user guide'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('regex metacharacters in the term match literally', (
    tester,
  ) async {
    await pump(tester);
    await warm(tester, query(grep: '[WIP]'));

    await filter(tester, '[WIP]');

    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('file: narrows by path at any depth', (tester) async {
    await pump(tester);
    await warm(tester, query(path: 'b.dart'));

    await filter(tester, 'file:b.dart');

    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('feat: first feature'), findsNothing);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('a no-match filter shows the empty state, and clearing restores',
      (tester) async {
    await pump(tester);
    await warm(tester, query(grep: 'zzz-nothing-matches'));

    await filter(tester, 'zzz-nothing-matches');
    expect(find.text('No matching commits'), findsOneWidget);

    await filter(tester, '');
    expect(find.text('feat: first feature'), findsOneWidget);
    expect(find.text('docs: user guide'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('sha: finds a commit by prefix', (tester) async {
    // Even this setup subprocess needs the real zone — run inside runAsync.
    final prefix = (await tester.runAsync(() async {
      final r = await Process.run(
        'git',
        ['rev-parse', 'HEAD~2'],
        workingDirectory: repo,
      );
      return (r.stdout as String).trim().substring(0, 8);
    }))!;

    await pump(tester);
    await warm(tester, query(sha: prefix));

    await filter(tester, 'sha:$prefix');

    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('docs: user guide'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('a BARE hash prefix finds its commit — no sha: key needed', (
    tester,
  ) async {
    final prefix = (await tester.runAsync(() async {
      final r = await Process.run(
        'git',
        ['rev-parse', 'HEAD~2'],
        workingDirectory: repo,
      );
      return (r.stdout as String).trim().substring(0, 5);
    }))!;

    await pump(tester);
    await warm(tester, query(grep: prefix));

    await filter(tester, prefix);

    expect(find.text('fix [WIP] patch collapse'), findsOneWidget);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('a hex-shaped word still searches messages', (tester) async {
    await pump(tester);
    await warm(tester, query(grep: 'decade'));

    await filter(tester, 'decade');

    expect(find.text('perf: decade of cleanup'), findsOneWidget);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });

  testWidgets('author: with a space after the colon narrows by author', (
    tester,
  ) async {
    await pump(tester);
    await warm(tester, (
      repoPath: repo,
      grep: null,
      author: 'other',
      since: null,
      until: null,
      path: null,
      sha: null,
      noMerges: false,
      all: false,
    revision: null,
    ));

    await filter(tester, 'author: other');

    expect(find.text('perf: decade of cleanup'), findsOneWidget);
    expect(find.text('feat: first feature'), findsNothing);
    expect(find.text('1 matching commit'), findsOneWidget);
    await drainLaneWatchdogs(tester);
  });
}
