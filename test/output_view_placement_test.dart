// MADR 0064 F3: the Output view belongs to the shell, not to one page.
//
// ⇧⌘O ("Toggle Output View") is a global command — the keymap, the native
// View menu and the palette all flip `outputLogProvider.visible` from any
// page. The view itself used to be mounted only inside the Repository page,
// so from History, Branches, Stashes, Forge or Worktrees the command flipped
// the menu checkmark and nothing appeared. These tests drive a connected
// AppShell with real key events only — ⌘1…⌘6 to change page, ⇧⌘O to toggle —
// and assert on the rendered widget, not the provider, which is what every
// earlier test checked and why the defect shipped green.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/output_view.dart';
import 'package:remote_magic_git/features/forge/forge_panel.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A ConnectionController pinned to a connected state, so the shell renders
/// its pages without running a real connect.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

const _pageNames = [
  'Repository',
  'History',
  'Branches',
  'Stashes',
  'Forge',
  'Worktrees',
];

/// The widget each page mounts, so a test can prove the ⌘N switch landed.
const _pageTypes = [
  RepoStatusView,
  HistoryView,
  BranchesView,
  StashView,
  ForgePanel,
  WorktreesView,
];

const _pageKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

Future<void> _pumpConnectedShell(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionProvider.overrideWith(
          () => _StubConnection(
            const ConnectionState(
              phase: ConnectionPhase.connected,
              backend: ConnectionBackend.ssh,
              host: 'build01.example.com',
              repoPath: '/srv/repo',
              repoPaths: ['/srv/repo'],
            ),
          ),
        ),
        repoWatchProvider(
          '/srv/repo',
        ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        savedConnectionsProvider.overrideWith((ref) async => const []),
        savedLocalReposProvider.overrideWith((ref) async => const []),
      ],
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.expand(child: AppShell()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Presses [key] with the given modifiers held, as real key events.
Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

/// Switches to [page] with its ⌘N shortcut, then checks ⇧⌘O toggles the
/// visible Output view one → none → one (it is visible by default).
Future<void> _expectToggleOnPage(WidgetTester tester, int page) async {
  await _chord(tester, _pageKeys[page]);
  expect(
    find.byType(_pageTypes[page]),
    findsOneWidget,
    reason: '⌘${page + 1} shows the ${_pageNames[page]} page',
  );
  expect(
    find.byType(OutputView),
    findsOneWidget,
    reason: 'the Output view is visible by default on ${_pageNames[page]}',
  );

  await _chord(tester, LogicalKeyboardKey.keyO, shift: true);
  expect(
    find.byType(OutputView),
    findsNothing,
    reason: '⇧⌘O hides the Output view on ${_pageNames[page]}',
  );

  await _chord(tester, LogicalKeyboardKey.keyO, shift: true);
  expect(
    find.byType(OutputView),
    findsOneWidget,
    reason: '⇧⌘O shows the Output view again on ${_pageNames[page]}',
  );
}

void main() {
  for (var page = 0; page < _pageNames.length; page++) {
    testWidgets('⇧⌘O toggles the Output view on ${_pageNames[page]} '
        '(1400x900)', (tester) async {
      await _pumpConnectedShell(tester, const Size(1400, 900));
      await _expectToggleOnPage(tester, page);
      await _unmount(tester);
    });
  }

  // The supported minimum window. The sidebar is hidden at this width, so
  // the page is changed by its keyboard shortcut, which is also the only
  // route a real user has without reopening the sidebar.
  for (final page in const [1, 0]) {
    testWidgets('⇧⌘O toggles the Output view on ${_pageNames[page]} '
        '(640x480)', (tester) async {
      await _pumpConnectedShell(tester, const Size(640, 480));
      await _expectToggleOnPage(tester, page);
      await _unmount(tester);
    });
  }
}
