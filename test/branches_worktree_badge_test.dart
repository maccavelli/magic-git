// Branch rows for branches checked out in ANOTHER worktree: badge, "switch to
// worktree" in place of checkout, and a delete that is disabled (git refuses,
// with no override flag). Regression guard for the row still being selectable —
// the badge and the extra button sit in the same Row as the name.
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

const _repo = '/Users/x/wt-demo/app';

/// Mirrors the demo repo: `main` checked out here, `feature/auth` and `gonebr`
/// checked out in linked worktrees, `hotfix/login` free.
const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    subject: 's',
    worktreePath: _repo,
  ),
  GitRef(
    name: 'refs/heads/feature/auth',
    oid: 'bbb',
    isHead: false,
    subject: 's',
    worktreePath: '/Users/x/wt-demo/app-feature-auth',
  ),
  GitRef(
    name: 'refs/heads/gonebr',
    oid: 'ccc',
    isHead: false,
    subject: 's',
    worktreePath: '/Users/x/wt-demo/app-gone',
  ),
  GitRef(
    name: 'refs/heads/hotfix/login',
    oid: 'ddd',
    isHead: false,
    subject: 's',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

Future<void> pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(_FakeGit()),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      // The view now watches CONFIGURED remotes to pick the tag-push target
      // — unoverridden it would fall through to the executor.
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      // The real provider keeps a five-minute keepAlive timer that widget
      // tests would flag as still pending; null = unknown, no badges.
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(
        _repo,
      ).overrideWith((ref) async => const <String>{}),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: BranchesView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every branch row is selectable, badged or not', (tester) async {
    await pump(tester);

    // All four render.
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feature/auth'), findsOneWidget);
    expect(find.text('gonebr'), findsOneWidget);
    expect(find.text('hotfix/login'), findsOneWidget);

    // Selecting a badged branch must work — the badge and the extra "switch to
    // worktree" button live in the same Row as the name, and must not swallow
    // the row's tap or throw during layout.
    await tester.tap(find.text('feature/auth'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // And a plain one.
    await tester.tap(find.text('hotfix/login'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // And back to a badged one.
    await tester.tap(find.text('gonebr'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a branch checked out elsewhere shows a worktree badge', (
    tester,
  ) async {
    await pump(tester);

    // The badge names the worktree by its leaf directory.
    expect(find.text('app-feature-auth'), findsOneWidget);
    expect(find.text('app-gone'), findsOneWidget);

    // `main` is checked out HERE. git reports a worktreepath for it too (its
    // docs claim otherwise), so a naive check would badge the current branch.
    expect(find.text('app'), findsNothing);
  });

  testWidgets('a worktree-held branch offers switch-to-worktree in place of '
      'checkout, and no delete', (tester) async {
    await pump(tester);

    // The free branch: Check out is primary; Delete lives under More.
    await tester.tap(find.text('hotfix/login'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(InlineActionButton, 'Check out'),
      findsOneWidget,
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    // Dismiss the More menu so the next row tap is not blocked.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // A branch checked out elsewhere: Switch to worktree replaces Check out,
    // and Delete is withheld (git refuses, with no override flag).
    await tester.tap(find.text('feature/auth'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(InlineActionButton, 'Switch to worktree'),
      findsOneWidget,
    );
    expect(find.widgetWithText(InlineActionButton, 'Check out'), findsNothing);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
  });
}
