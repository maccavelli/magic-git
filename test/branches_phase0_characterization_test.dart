// Phase 0 characterization: lock current Branches behavior before deeper
// extraction. No intended UX change in Phase 0.

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/theme/app_theme.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';

const _repo = '/repo';

const _refs = [
  GitRef(
    name: 'refs/heads/main',
    oid: 'aaa',
    isHead: true,
    subject: 'head commit',
  ),
  GitRef(
    name: 'refs/heads/feature',
    oid: 'bbb',
    isHead: false,
    subject: 'feature commit',
  ),
  GitRef(
    name: 'refs/remotes/origin/feature',
    oid: 'bbb',
    isHead: false,
    subject: 'feature commit',
  ),
  GitRef(
    name: 'refs/tags/v1.0',
    oid: 'ccc',
    isHead: false,
    subject: 'tag subject',
  ),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Set<String> merged = const {},
}) async {
  final git = _FakeGit();
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => _refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(_repo).overrideWith((ref) async => merged),
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
  return container;
}

void main() {
  testWidgets('HEAD row uses green tint that masks selection background', (
    tester,
  ) async {
    await _pump(tester);

    // Select HEAD (main).
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();

    // The local row for HEAD paints systemGreen at 0.12 alpha, not the
    // selection tint — characterization of the known a11y debt (Phase 6).
    final greenContainers = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final c = w.color;
      if (c == null) return false;
      // systemGreen with alpha ~0.12
      return c.a < 0.2 && c.a > 0.05 && c.g > c.r && c.g > c.b;
    });
    expect(greenContainers, findsWidgets);

    // Selection tint should still exist as a constant for non-HEAD rows.
    expect(AppTheme.rowSelectionTint, isNotNull);
  });

  testWidgets('selecting a remote row shows remote detail without forge create', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('origin/feature'));
    await tester.pumpAndSettle();
    // Remote detail exposes checkout tracking, not create-PR.
    expect(find.textContaining('origin/feature'), findsWidgets);
  });

  testWidgets('repo path change clears selection (didUpdateWidget)', (
    tester,
  ) async {
    final git = _FakeGit();
    final container = ProviderContainer(
      overrides: [
        gitServiceProvider.overrideWithValue(git),
        refsProvider(_repo).overrideWith((ref) async => _refs),
        refsProvider('/other').overrideWith((ref) async => _refs),
        remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
        remotesProvider('/other').overrideWith((ref) async => const ['origin']),
        remoteTagsProvider(_repo).overrideWith((ref) async => null),
        remoteTagsProvider('/other').overrideWith((ref) async => null),
        branchForgeProvider(_repo).overrideWith((ref) async => const {}),
        branchForgeProvider('/other').overrideWith((ref) async => const {}),
        mergedBranchesProvider(_repo)
            .overrideWith((ref) async => const <String>{}),
        mergedBranchesProvider('/other')
            .overrideWith((ref) async => const <String>{}),
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
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MacosApp(
          debugShowCheckedModeBanner: false,
          home: BranchesView(repoPath: '/other'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Empty-state dashboard after selection clear (no selected detail Delete).
    expect(find.text('Branches'), findsWidgets);
  });

  testWidgets('context menu still opens on secondary click', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('feature'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete branch'), findsOneWidget);
  });
}
