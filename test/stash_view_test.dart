// Verifies the Stashes namespace renders its list, its empty state, and the
// selected-stash preview. UI/UX polish is validated on macOS; this pins the
// data→render wiring and provider overrides.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';

/// Executor that never touches SSH — the view reads gitServiceProvider in build
/// but the render tests never fire a mutation.
class _FakeExecutor extends SSHCommandExecutor {
  _FakeExecutor() : super(SSHClientManager());
  @override
  Future<SSHCommandResult> execute({
    required String repoPath,
    required List<String> gitArgs,
    Map<String, String>? extraEnv,
    String? stdin,
    Duration timeout = SSHCommandExecutor.defaultTimeout,
    int retries = 0,
    ExecLane lane = ExecLane.exclusive,
    bool compress = false,
  }) async => const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
}

const _repo = '/repo';

final _stashes = [
  const GitStash(
    index: 0,
    branch: 'main',
    message: 'WIP on main: abc1234 tweak the parser',
    relativeDate: '2 hours ago',
  ),
  const GitStash(
    index: 1,
    branch: 'feature',
    message: 'On feature: manual note',
    relativeDate: '3 days ago',
  ),
];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<GitStash> stashes,
  String stashDiff = 'diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n',
}) async {
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(GitService(_FakeExecutor())),
      stashesProvider(_repo).overrideWith((ref) async => stashes),
      stashDiffProvider((_repo, 0)).overrideWith((ref) async => stashDiff),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1000,
          height: 700,
          child: StashView(repoPath: _repo),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('renders a card per stash with subject, ref, branch, and age', (
    tester,
  ) async {
    await _pump(tester, stashes: _stashes);

    expect(find.text('Stashes'), findsOneWidget);
    // subject strips the "WIP on <branch>: <sha> " boilerplate.
    expect(find.text('tweak the parser'), findsOneWidget);
    expect(find.text('manual note'), findsOneWidget);
    expect(find.text('stash@{0}'), findsOneWidget);
    expect(find.text('stash@{1}'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.textContaining('2 hours ago'), findsOneWidget);
    // Nothing selected yet — the preview shows its placeholder.
    expect(
      find.text('Select a stash to preview its contents'),
      findsOneWidget,
    );
  });

  testWidgets('shows the empty state when there are no stashes', (tester) async {
    await _pump(tester, stashes: const []);
    expect(find.text('No stashes'), findsOneWidget);
    expect(find.textContaining('stash your current changes'), findsOneWidget);
  });

  testWidgets('selecting a stash previews its patch', (tester) async {
    await _pump(tester, stashes: _stashes);
    await tester.tap(find.text('tweak the parser'));
    await tester.pumpAndSettle();

    // The placeholder is replaced by the stash's diff content.
    expect(
      find.text('Select a stash to preview its contents'),
      findsNothing,
    );
    expect(find.textContaining('@@ -1 +1 @@'), findsOneWidget);
  });
}
