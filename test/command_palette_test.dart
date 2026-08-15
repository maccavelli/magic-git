// The ⌘K command palette: it lists navigation commands and local-branch
// checkout targets, filters as you type, and arrow-key + Enter runs the
// highlighted command (proving keyboard nav works from inside its search field).

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/storage/saved_workspace_set.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/command_palette.dart';
import 'package:remote_magic_git/features/common/escape_dismissible.dart';
import 'package:remote_magic_git/features/tabs/tabs_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: 'aaa', isHead: true, subject: 's'),
  GitRef(name: 'refs/heads/feature-x', oid: 'bbb', isHead: false, subject: 's'),
  GitRef(
    name: 'refs/remotes/origin/main',
    oid: 'aaa',
    isHead: false,
    subject: 's',
  ),
];

const _worktrees = [
  GitWorktree(
    path: _repo,
    headOid: 'aaa',
    branch: 'refs/heads/main',
    isMain: true,
  ),
  GitWorktree(
    path: '/repo-feature',
    headOid: 'bbb',
    branch: 'refs/heads/feature-x',
  ),
];

class _Recorder {
  int cloneOpened = 0;
  int createOpened = 0;
  int historyWindowOpened = 0;
  int? panel;
  String? checkedOut;
  String? openedWorktree;
  int refreshed = 0;
  int undone = 0;
  String? workspaceOpened;
  final dispatched = <(String, int)>[];
}

Future<void> _open(
  WidgetTester tester,
  _Recorder rec, {
  Forge forge = Forge.github,
  bool provideLandedEntities = true,
  VoidCallback? onRefsLoad,
  List<SavedWorkspaceSet> savedWorkspaces = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        refsProvider(_repo).overrideWith((ref) async {
          onRefsLoad?.call();
          return _refs;
        }),
        // The palette lists worktrees by name too. Without this it would reach
        // for a real git through the unconnected executor and leave its retry
        // timer pending past the test.
        gitWorktreesProvider(_repo).overrideWith((ref) async => _worktrees),
        // The palette gates its forge commands by the detected forge.
        forgeProvider(_repo).overrideWith((ref) async => forge),
        savedWorkspaceSetsProvider.overrideWith((ref) async => savedWorkspaces),
      ],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Center(
            child: AppPushButton(
              controlSize: ControlSize.large,
              // Mirrors the app shell's call site: dismissal comes from the
              // registry-backed EscapeDismissible, not palette-internal
              // (focus-dependent) shortcuts.
              onPressed: () => showMacosSheet<void>(
                context: context,
                builder: (_) => EscapeDismissible(
                  child: CommandPalette(
                    repoPath: _repo,
                    landedRefs: provideLandedEntities ? _refs : const [],
                    landedWorktrees: provideLandedEntities
                        ? _worktrees
                        : const [],
                    landedForge: provideLandedEntities ? forge : null,
                    onGoToPanel: (i) => rec.panel = i,
                    onRefresh: () => rec.refreshed++,
                    onOpenSettings: () {},
                    onOpenShortcuts: () {},
                    onOpenConnections: () {},
                    onOpenWorkspaceSet: (set) => rec.workspaceOpened = set.id,
                    onCloneRepository: () => rec.cloneOpened++,
                    onCreateRepository: () => rec.createOpened++,
                    onOpenHistoryWindow: () => rec.historyWindowOpened++,
                    onUndo: () => rec.undone++,
                    onDispatchAction: (id, panel) =>
                        rec.dispatched.add((id, panel)),
                    onCheckoutBranch: (b) => rec.checkedOut = b,
                    onOpenWorktree: (p) => rec.openedWorktree = p,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tab aliases are searchable and switch the existing tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tabs = TabsController();
    addTearDown(tabs.dispose);
    tabs.ensureInitialTab();
    final backend = tabs.openOrFocus(
      connectionId: 'ssh-1',
      repoPath: '/srv/backend',
      savedKind: SavedRepositoryKind.ssh,
      connect: (_) {},
    );
    tabs.openOrFocus(
      connectionId: 'ssh-2',
      repoPath: '/srv/frontend',
      savedKind: SavedRepositoryKind.ssh,
      connect: (_) {},
    );
    await tabs.setAlias(backend, 'Backend API');
    TabsController.current = tabs;
    addTearDown(() => TabsController.current = null);

    await _open(tester, _Recorder());
    await tester.enterText(find.byType(MacosTextField), 'Backend API');
    await tester.pumpAndSettle();

    expect(find.text('Switch to tab Backend API'), findsOneWidget);
    await tester.tap(find.text('Switch to tab Backend API'));
    await tester.pumpAndSettle();
    expect(tabs.activeId, backend.id);
  });

  testWidgets('saved workspace commands are searchable and runnable', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _open(
      tester,
      recorder,
      savedWorkspaces: const [
        SavedWorkspaceSet(
          id: 'daily',
          displayName: 'Daily Work',
          repositories: [
            SavedWorkspaceRepositoryRef(
              kind: SavedRepositoryKind.ssh,
              savedId: 'ssh-1',
              repoPath: '/srv/backend',
              tabAlias: 'Backend',
            ),
          ],
          activeIndex: 0,
        ),
      ],
    );

    await tester.enterText(find.byType(MacosTextField), 'Daily Work');
    await tester.pumpAndSettle();
    expect(find.text('Open workspace Daily Work'), findsOneWidget);
    await tester.tap(find.text('Open workspace Daily Work'));
    await tester.pumpAndSettle();
    expect(recorder.workspaceOpened, 'daily');
  });

  testWidgets(
    'empty open is landed-only; entity prefix debounces and opens actions',
    (tester) async {
      var loads = 0;
      final recorder = _Recorder();
      await _open(
        tester,
        recorder,
        provideLandedEntities: false,
        onRefsLoad: () => loads++,
      );
      expect(loads, 0);

      await tester.enterText(find.byType(MacosTextField), 'branch: feature');
      await tester.pump(const Duration(milliseconds: 149));
      expect(loads, 0);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('Checkout feature-x'), findsOneWidget);

      await tester.tap(find.text('Checkout feature-x'));
      await tester.pump();
      expect(find.textContaining('Choose an action for'), findsOneWidget);
      await tester.tap(find.text('Checkout feature-x'));
      await tester.pumpAndSettle();
      expect(recorder.checkedOut, 'feature-x');
    },
  );

  // 0009 M7: issue:/request:/ci: parse but contribute nothing yet — the
  // hint must not teach scopes that always come back empty.
  testWidgets('the hint no longer advertises unimplemented scopes', (
    tester,
  ) async {
    await _open(tester, _Recorder());

    expect(find.textContaining('issue:'), findsNothing);
    expect(find.textContaining('request:'), findsNothing);
    expect(find.textContaining('ci:'), findsNothing);
    // The working scopes stay advertised.
    expect(find.textContaining('worktree:'), findsOneWidget);
  });

  testWidgets('lists navigation commands', (tester) async {
    await _open(tester, _Recorder());

    expect(find.text('Go to Repository'), findsOneWidget);
    expect(find.text('Go to History'), findsOneWidget);

    // The catalog is long now — rows below the fold build lazily, so reach
    // Refresh through the filter instead of expecting it on screen.
    await tester.enterText(find.byType(MacosTextField), 'refresh');
    await tester.pumpAndSettle();
    expect(find.text('Refresh'), findsOneWidget);
  });

  // 0009 M1: the catalog derives from kPanelActionOwner, so panel verbs the
  // menu offers can never be missing from ⌘K. Spot-check the ones the old
  // hardcoded list omitted.
  testWidgets('menu-only repository verbs are searchable', (tester) async {
    await _open(tester, _Recorder());

    for (final label in [
      'Pull (rebase)',
      'Unstage all',
      'Abort pending operation',
      'Amend last commit (working tree)',
    ]) {
      await tester.enterText(find.byType(MacosTextField), label);
      await tester.pumpAndSettle();
      // Two: the query text inside the field, and the matching row.
      expect(find.text(label), findsNWidgets(2), reason: '$label missing');
    }
  });

  testWidgets('Clone/Create Repository commands invoke their callbacks', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'clone');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone Repository'));
    await tester.pumpAndSettle();
    expect(rec.cloneOpened, 1);

    await _open(tester, rec);
    await tester.enterText(find.byType(MacosTextField), 'create');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Repository'));
    await tester.pumpAndSettle();
    expect(rec.createOpened, 1);
  });

  testWidgets('offers local-branch checkouts but not remote-tracking refs', (
    tester,
  ) async {
    await _open(tester, _Recorder());
    // Narrow to just the checkout rows (they live below the fold otherwise).
    await tester.enterText(find.byType(MacosTextField), 'checkout ');
    await tester.pumpAndSettle();

    expect(find.text('Checkout main'), findsOneWidget);
    expect(find.text('Checkout feature-x'), findsOneWidget);
    // A remote-tracking ref would detach HEAD, so it isn't offered.
    expect(find.text('Checkout origin/main'), findsNothing);
  });

  testWidgets('filters the list as the query is typed', (tester) async {
    await _open(tester, _Recorder());

    await tester.enterText(find.byType(MacosTextField), 'feat');
    await tester.pumpAndSettle();

    expect(find.text('Checkout feature-x'), findsOneWidget);
    expect(find.text('Go to Repository'), findsNothing);
  });

  testWidgets('Enter runs the highlighted command; Arrow-Down moves the '
      'highlight', (tester) async {
    final rec = _Recorder();
    await _open(tester, rec);

    // First command (Go to Repository, index 0) is highlighted by default.
    // Arrow-Down → History (panel 1), Enter runs it and closes the palette.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(rec.panel, 1);
    expect(find.byType(CommandPalette), findsNothing); // closed
  });

  testWidgets('running a checkout command invokes the guarded checkout', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'feature-x');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(rec.checkedOut, 'feature-x');
  });

  testWidgets('running a worktree target opens its stable path', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(
      find.byType(MacosTextField),
      'open worktree repo-feature',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open worktree repo-feature'));
    await tester.pumpAndSettle();

    expect(rec.openedWorktree, '/repo-feature');
  });

  testWidgets('Escape closes the palette even with nothing focused', (
    tester,
  ) async {
    await _open(tester, _Recorder());
    expect(find.byType(CommandPalette), findsOneWidget);

    // Simulate the "just opened, autofocus hasn't landed / focus got lost"
    // state that used to leave Escape dead until a click inside the sheet.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
  });

  testWidgets('rows expose one merged semantic label, not three fragments', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'fetch');
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.text('Fetch'));
    expect(node.label, contains('Fetch'));
    expect(
      node.label,
      contains('git'),
      reason: 'the category chip is a bare word on screen — VoiceOver needs '
          'it attached to the command, not read adrift',
    );
    expect(node.label, contains('item 1 of'));
    handle.dispose();
  });

  testWidgets('the three zoom rows are visually distinguishable', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'zoom');
    await tester.pumpAndSettle();

    // The palette row is the ONLY visual affordance for these — History has no
    // zoom toolbar — so three rows sharing two glyphs made Reset unfindable.
    final icons = tester
        .widgetList<MacosIcon>(find.byType(MacosIcon))
        .map((i) => i.icon)
        .toSet();
    expect(icons, contains(CupertinoIcons.zoom_in));
    expect(icons, contains(CupertinoIcons.zoom_out));
    expect(
      icons,
      contains(CupertinoIcons.fullscreen_exit),
      reason: 'Reset commit list zoom must not reuse the Zoom Out glyph',
    );
  });

  testWidgets('offers the full keymap catalog and dispatches panel actions '
      'as (actionId, panelIndex)', (tester) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'fetch');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(rec.dispatched, [('repository.fetch', 0)]);

    await _open(tester, rec);
    await tester.enterText(find.byType(MacosTextField), 'cherry');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cherry-pick selected commit'));
    await tester.pumpAndSettle();
    expect(rec.dispatched.last, ('history.cherryPick', 1));
  });

  testWidgets('a category prefix narrows the list, VS Code-style', (
    tester,
  ) async {
    await _open(tester, _Recorder());

    // `go:` keeps navigation, drops git commands.
    await tester.enterText(find.byType(MacosTextField), 'go: ');
    await tester.pumpAndSettle();
    expect(find.text('Go to Repository'), findsOneWidget);
    expect(find.text('Fetch'), findsNothing);

    // `git: fe` narrows within the git category.
    await tester.enterText(find.byType(MacosTextField), 'git: fetch');
    await tester.pumpAndSettle();
    expect(find.text('Fetch'), findsOneWidget);
    expect(find.text('Go to Repository'), findsNothing);

    // A colon prefix that names no category is plain text, not a filter.
    await tester.enterText(find.byType(MacosTextField), 'origin: x');
    await tester.pumpAndSettle();
    expect(find.text('No matching commands'), findsOneWidget);
  });

  testWidgets('forge commands follow the detected forge', (tester) async {
    await _open(tester, _Recorder()); // GitHub by default
    await tester.enterText(find.byType(MacosTextField), 'forge: ');
    await tester.pumpAndSettle();
    expect(find.text('New pull request'), findsOneWidget);
    expect(find.text('New merge request'), findsNothing);

    // Close this palette before re-pumping — a live sheet route across the
    // pumpWidget swap otherwise strands the second open.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await _open(tester, _Recorder(), forge: Forge.gitlab);
    await tester.enterText(find.byType(MacosTextField), 'forge: ');
    await tester.pumpAndSettle();
    expect(find.text('New merge request'), findsOneWidget);
    expect(find.text('New pull request'), findsNothing);
  });

  testWidgets('Undo Last Git Operation invokes the shell undo', (tester) async {
    final rec = _Recorder();
    await _open(tester, rec);
    await tester.enterText(find.byType(MacosTextField), 'undo');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo Last Git Operation'));
    await tester.pumpAndSettle();
    expect(rec.undone, 1);
  });

  testWidgets('Open History in New Window invokes its callback', (
    tester,
  ) async {
    final rec = _Recorder();
    await _open(tester, rec);

    await tester.enterText(find.byType(MacosTextField), 'history window');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open History in New Window'));
    await tester.pumpAndSettle();

    expect(rec.historyWindowOpened, 1);
  });
}
