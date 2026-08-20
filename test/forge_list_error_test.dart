// 0009 M20: a forge list failure that looks like missing/expired credentials
// must say so and hand the user the fix (the Dashboard's Authentication
// section), instead of a bare red error dump.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/forge/forge_widgets.dart';

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
}
