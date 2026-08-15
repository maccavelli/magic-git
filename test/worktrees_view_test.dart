// The Worktrees panel, rendered from the output of REAL `git worktree list`.
//
// The data is produced by running real git against a real repo in setUp, then
// handed to the widget — rather than hand-writing a `GitWorktree` fixture, which
// would only prove the fixture matches the panel. (The git call cannot happen
// *inside* testWidgets: that runs on fake-async, so a real subprocess never
// completes and pumpAndSettle spins out. Every real-git test in this repo is a
// plain `test()` for the same reason.)
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/exec/local_command_executor.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/worktrees/worktree_access.dart';
import 'package:remote_magic_git/features/worktrees/worktree_tabs.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:riverpod/misc.dart' show Override;

/// Records grant releases instead of touching the real ScopedAccess.
class _RecordingAccess extends WorktreeAccess {
  _RecordingAccess(super.ref);
  final List<String> released = [];

  @override
  Future<void> release(String worktreePath) async {
    released.add(worktreePath);
  }
}

void main() {
  late Directory tmp;
  late String repo;
  late GitService git;

  /// What real git reports for the scratch repo — the panel's actual input.
  late List<GitWorktree> worktrees;

  Future<void> git_(List<String> args, String cwd) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    if (r.exitCode != 0) {
      fail('git ${args.join(' ')} (in $cwd) failed: ${r.stderr}');
    }
  }

  setUp(() async {
    final base = await Directory.systemTemp.createTemp('wt_view_');
    tmp = Directory(base.resolveSymbolicLinksSync());
    repo = '${tmp.path}/app';
    Directory(repo).createSync();
    git = GitService(LocalCommandExecutor());

    await git_(['init', '-q', '-b', 'main'], repo);
    await git_(['config', 'user.email', 't@t'], repo);
    await git_(['config', 'user.name', 't'], repo);
    await git_(['config', 'commit.gpgsign', 'false'], repo);
    await git_(['commit', '-q', '--allow-empty', '-m', 'init'], repo);

    // A healthy linked worktree, made outside the app — the panel must discover
    // it, which is the point of reading git rather than our own bookkeeping.
    await git_([
      'worktree',
      'add',
      '-q',
      '${tmp.path}/app-feature',
      '-b',
      'feature/auth',
    ], repo);

    // A stale one: the directory deleted behind git's back, which is how these
    // actually happen (an `rm -rf`, a cleaned-out Downloads folder).
    await git_([
      'worktree',
      'add',
      '-q',
      '${tmp.path}/app-gone',
      '-b',
      'gone',
    ], repo);
    Directory('${tmp.path}/app-gone').deleteSync(recursive: true);

    worktrees = await git.gitWorktrees(repo);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    List<GitWorktree>? data,
    List<Override> extraOverrides = const [],
  }) async {
    // A real desktop width. The 800x600 default overflows, and an overflow is a
    // test failure — and a worktree tab mounts the full RepoStatusView, whose
    // toolbar needs as much room here as it does as a top-level panel (the
    // nested workspace adds no horizontal chrome of its own).
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        gitWorktreesProvider(
          repo,
        ).overrideWith((ref) async => data ?? worktrees),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: WorktreesView(repoPath: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('lists every worktree real git reports', (tester) async {
    // Sanity: this is genuinely git's own output, not a fixture.
    expect(worktrees, hasLength(3));
    expect(worktrees.first.isMain, isTrue);

    await pump(tester);

    // The main worktree, labelled by its leaf directory name — never the full
    // path, which is the #1 labelling complaint about every other client.
    expect(find.text('app'), findsOneWidget);
    expect(find.text('main worktree'), findsOneWidget);

    // The linked worktree created in a terminal, discovered with no help.
    expect(find.text('app-feature'), findsOneWidget);
    expect(find.text('feature/auth'), findsOneWidget);

    // The stale one, flagged rather than silently listed as healthy.
    expect(find.text('app-gone'), findsOneWidget);
    expect(find.text('missing'), findsOneWidget);
    expect(find.byType(RepositoryWorkspaceScaffold), findsOneWidget);
  });

  testWidgets('selecting a worktree reveals its details and actions', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('app-feature'));
    // The row also supports double-click-to-open, so Flutter waits out the
    // double-click interval before dispatching the single-click selection.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Worktree: app-feature'), findsOneWidget);
    expect(find.text('${tmp.path}/app-feature'), findsWidgets);
    expect(find.text('Open Worktree'), findsOneWidget);
    expect(find.text('Lock'), findsOneWidget);
    expect(find.text('Move…'), findsOneWidget);
    expect(find.text('Remove…'), findsOneWidget);
  });

  testWidgets('a stale worktree offers Repair and Prune inline', (
    tester,
  ) async {
    await pump(tester);

    // Both remedies sit on the row itself rather than buried in a menu — a
    // broken worktree is a state the user wants gone, not one to go hunting for.
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.wrench,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MacosIcon && w.icon == CupertinoIcons.trash,
      ),
      findsOneWidget,
    );
  });

  testWidgets("the overflow menu's repair says it acts on every worktree", (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is MacosPulldownButton &&
            w.icon == CupertinoIcons.line_horizontal_3,
      ),
    );
    await tester.pumpAndSettle();

    // `git worktree repair` with no argument repairs ALL of them. Sitting a few
    // pixels from a selected row, the old bare "Repair worktree links" read as
    // the row's repair — the same words the inline wrench does for one worktree.
    expect(find.text('Repair worktree links'), findsNothing);
    expect(find.text('Repair all worktree links'), findsOneWidget);
  });

  // The tab strip's own behaviour is tested on the notifier rather than through
  // the widget, deliberately: opening a tab mounts the real Changes / History /
  // Branches / Stashes panels, and stubbing four panels' worth of providers to
  // keep them quiet would test the stubs, not the tabs. The nested workspace
  // rendering is verified in the running app instead.
  group('the tab strip', () {
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer();
      addTearDown(c.dispose);
    });

    test('opening selects; closing falls back to the Overview', () {
      final tabs = c.read(worktreeTabsProvider.notifier);
      expect(c.read(worktreeTabsProvider).open, isEmpty);
      expect(c.read(worktreeTabsProvider).selected, isNull);

      tabs.open('/wt/a');
      expect(c.read(worktreeTabsProvider).open, ['/wt/a']);
      expect(c.read(worktreeTabsProvider).selected, '/wt/a');

      // Opening an already-open worktree focuses it rather than duplicating it.
      tabs.open('/wt/b');
      tabs.open('/wt/a');
      expect(c.read(worktreeTabsProvider).open, ['/wt/a', '/wt/b']);
      expect(c.read(worktreeTabsProvider).selected, '/wt/a');

      tabs.close('/wt/a');
      expect(c.read(worktreeTabsProvider).open, ['/wt/b']);
      // Back to the Overview, not to a neighbour — the Overview is where you go
      // to pick another one anyway.
      expect(c.read(worktreeTabsProvider).selected, isNull);
    });

    test('a tab for a worktree that no longer exists is dropped', () {
      // Someone pruned it, or removed it from a terminal. Left alone, the tab
      // would point at a dead path and every git call in it would fail.
      final tabs = c.read(worktreeTabsProvider.notifier);
      tabs.open('/wt/a');
      tabs.open('/wt/gone');

      tabs.retain({'/wt/a'});

      expect(c.read(worktreeTabsProvider).open, ['/wt/a']);
      expect(c.read(worktreeTabsProvider).selected, isNull);
    });
  });

  testWidgets("a dead tab's sandbox grant is released, not just its tab", (
    tester,
  ) async {
    // A worktree pruned or removed in a terminal: build()'s dead-path sweep
    // drops the tab — and must ALSO release the security-scoped grant,
    // which used to leak until the whole container was disposed (the
    // explicit close/remove/move paths release theirs themselves).
    late _RecordingAccess access;
    final c = await pump(
      tester,
      extraOverrides: [
        worktreeAccessProvider.overrideWith((ref) {
          access = _RecordingAccess(ref);
          return access;
        }),
      ],
    );

    final tabs = c.read(worktreeTabsProvider.notifier);
    tabs.open('/dead/path');
    // Keep the Overview frontmost: selecting the dead tab would mount a
    // whole workspace against the nonexistent path (real subprocesses,
    // pending watchdog timers) — and the realistic scenario is exactly a
    // background tab whose worktree got pruned in a terminal.
    tabs.select(null);
    await tester.pumpAndSettle();

    expect(c.read(worktreeTabsProvider).open, isEmpty);
    expect(access.released, contains('/dead/path'));
  });

  testWidgets('a repo with only a main worktree explains what they are', (
    tester,
  ) async {
    await pump(tester, data: [worktrees.first]);

    expect(find.text('No worktrees yet'), findsOneWidget);
    expect(find.text('Add Worktree…'), findsOneWidget);
  });
}
