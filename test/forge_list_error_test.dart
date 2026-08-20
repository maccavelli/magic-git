// 0009 M20: a forge list failure that looks like missing/expired credentials
// must say so and hand the user the fix (the Dashboard's Authentication
// section), instead of a bare red error dump.

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/forge/forge_widgets.dart';

/// A ConnectionController stuck at a fixed state, so a test can pin
/// `forgeAuthPending` without running a real connect.
class _StubConnection extends ConnectionController {
  final ConnectionState _state;
  _StubConnection(this._state);
  @override
  ConnectionState build() => _state;
}

/// Unmounts the tree and drains any ticker before the test ends: a mounted
/// [ProgressCircle] keeps a repeating animation alive, which fails the
/// binding's `!timersPending` assertion at teardown.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _pumpPane(
  WidgetTester tester,
  Object error, {
  required bool forgeAuthPending,
}) async {
  final container = ProviderContainer(
    overrides: [
      connectionProvider.overrideWith(
        () => _StubConnection(
          ConnectionState(
            phase: ConnectionPhase.connected,
            forgeAuthPending: forgeAuthPending,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: PaneError(error),
      ),
    ),
  );
  await tester.pump();
}

Future<ProviderContainer> _pump(WidgetTester tester, Object error) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: ForgeListError(error, cli: 'gh'),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  test('looksLikeAuthFailure matches real gh/glab phrasings only', () {
    expect(looksLikeAuthFailure(Exception('HTTP 401: Bad credentials')), true);
    expect(
      looksLikeAuthFailure(
        Exception(
          'To get started with GitLab CLI, please run: glab auth login',
        ),
      ),
      true,
    );
    expect(
      looksLikeAuthFailure(Exception('not logged in to github.com')),
      true,
    );
    expect(
      looksLikeAuthFailure(
        const GitException(
          'git status failed',
          SSHCommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'glab: not logged in',
          ),
        ),
      ),
      true,
    );
    expect(
      looksLikeAuthFailure(
        Exception("could not read Username for 'https://github.com'"),
      ),
      true,
    );
    expect(looksLikeAuthFailure(Exception('terminal prompts disabled')), true);
    expect(looksLikeAuthFailure(Exception('could not resolve host')), false);
  });

  testWidgets('an auth-looking failure shows the sign-in callout and a '
      'Dashboard link', (tester) async {
    final container = await _pump(
      tester,
      Exception('HTTP 401: Bad credentials'),
    );

    expect(find.textContaining('gh auth login'), findsOneWidget);
    expect(find.text('Open Dashboard'), findsOneWidget);

    await tester.tap(find.text('Open Dashboard'));
    await tester.pump();
    expect(
      container.read(dashboardVisibleProvider),
      isTrue,
      reason: 'the link must open the Dashboard (Authentication section)',
    );
  });

  testWidgets('a non-auth failure stays a plain section error', (tester) async {
    await _pump(tester, Exception('could not resolve host'));
    expect(find.textContaining('could not resolve host'), findsOneWidget);
    expect(find.text('Open Dashboard'), findsNothing);
  });

  testWidgets('PaneError shows a spinner for an auth failure while forge '
      'login is pending', (tester) async {
    await _pumpPane(
      tester,
      Exception('not logged in to github.com'),
      forgeAuthPending: true,
    );

    expect(find.byType(ProgressCircle), findsWidgets);
    expect(find.textContaining('not logged in'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('PaneError shows the dump once forge login has settled', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      Exception('not logged in to github.com'),
      forgeAuthPending: false,
    );

    expect(find.textContaining('not logged in'), findsOneWidget);
    expect(find.byType(ProgressCircle), findsNothing);
  });

  testWidgets('PaneError never swallows a non-auth failure, pending or not', (
    tester,
  ) async {
    await _pumpPane(
      tester,
      Exception('could not resolve host'),
      forgeAuthPending: true,
    );

    expect(find.textContaining('could not resolve host'), findsOneWidget);
    expect(find.byType(ProgressCircle), findsNothing);
  });
}
