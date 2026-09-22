// MADR 0066: a collapsed navigator must stay visible and reversible.
//
// The Minimal preset sets `navigatorCollapsed`, and the layout used to render
// the pane as a zero-width box with no child — on History that is the commit
// list, so the page looked broken and Refresh looked dead, with nothing on
// screen to undo it. These tests pin the two ways back: the reveal rail, and
// the ⇧⌘N command. They assert the rendered pane, not the preference, which is
// what the earlier tests checked and why nobody noticed the pane was
// unreachable.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/app_shell.dart';
import 'package:remote_magic_git/features/common/adaptive_workspace_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _railKey = Key('workspace-navigator-reveal');

Future<RepositoryWorkspacePrefs?> _pumpLayout(
  WidgetTester tester, {
  required Size size,
  required bool collapsed,
}) async {
  RepositoryWorkspacePrefs? saved;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(
        width: size.width,
        height: size.height,
        child: AdaptiveWorkspaceLayout(
          navigator: const SizedBox(key: Key('navigator')),
          canvas: const SizedBox(key: Key('canvas')),
          navigatorLabel: 'Commits',
          preferences: RepositoryWorkspacePrefs(navigatorCollapsed: collapsed),
          onPreferencesChanged: (next) => saved = next,
        ),
      ),
    ),
  );
  await tester.pump();
  return saved;
}

/// A ConnectionController pinned to a connected state, so the shell renders
/// its pages without running a real connect.
class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

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

void main() {
  testWidgets('a collapsed navigator leaves a named rail, not a void', (
    tester,
  ) async {
    await _pumpLayout(tester, size: const Size(1400, 900), collapsed: true);

    expect(
      find.byKey(const Key('navigator')),
      findsNothing,
      reason: 'the pane itself is still collapsed',
    );
    expect(
      find.byKey(_railKey),
      findsOneWidget,
      reason: 'the collapsed pane leaves something to click',
    );
    expect(
      find.descendant(of: find.byKey(_railKey), matching: find.text('Commits')),
      findsOneWidget,
      reason: 'the rail says which pane is hidden',
    );
    expect(tester.getSize(find.byKey(_railKey)).width, 28);
  });

  testWidgets('tapping the rail restores the pane and persists it', (
    tester,
  ) async {
    await _pumpLayout(tester, size: const Size(1400, 900), collapsed: true);

    // The callback fires on tap; the layout is rebuilt with the new record the
    // way the owning page would rebuild it.
    RepositoryWorkspacePrefs? saved;
    await tester.pumpWidget(
      MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1400,
          height: 900,
          child: AdaptiveWorkspaceLayout(
            navigator: const SizedBox(key: Key('navigator')),
            canvas: const SizedBox(key: Key('canvas')),
            navigatorLabel: 'Commits',
            preferences: const RepositoryWorkspacePrefs(
              navigatorCollapsed: true,
            ),
            onPreferencesChanged: (next) => saved = next,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_railKey));
    await tester.pump();

    expect(saved, isNotNull, reason: 'the tap published a preference change');
    expect(saved!.navigatorCollapsed, isFalse);
  });

  testWidgets('an expanded navigator has no rail', (tester) async {
    await _pumpLayout(tester, size: const Size(1400, 900), collapsed: false);

    expect(find.byKey(const Key('navigator')), findsOneWidget);
    expect(find.byKey(_railKey), findsNothing);
  });

  testWidgets('compact keeps its back bar and grows no rail', (tester) async {
    await _pumpLayout(tester, size: const Size(640, 480), collapsed: true);

    expect(
      find.byKey(_railKey),
      findsNothing,
      reason: 'compact navigation is the back bar (0064 F1), not a rail',
    );
  });

  testWidgets('⇧⌘N hides the navigator and shows it again', (tester) async {
    await _pumpConnectedShell(tester, const Size(1400, 900));
    await _chord(tester, LogicalKeyboardKey.digit2); // History
    expect(find.byKey(_railKey), findsNothing, reason: 'starts expanded');

    await _chord(tester, LogicalKeyboardKey.keyN, shift: true);
    expect(
      find.byKey(_railKey),
      findsOneWidget,
      reason: '⇧⌘N collapsed the navigator, and the rail says so',
    );

    await _chord(tester, LogicalKeyboardKey.keyN, shift: true);
    expect(
      find.byKey(_railKey),
      findsNothing,
      reason: '⇧⌘N brought the navigator back',
    );
    await _unmount(tester);
  });
}
