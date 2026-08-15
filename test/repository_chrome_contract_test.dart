// The contract the six repository screens share through RepositoryContextBar.
//
// Each screen builds its own snapshot and primary action, and each used to bend
// the contract somewhere: four claimed `kind: fetch` while doing something
// else, one dropped the bar on four of its six router outcomes, one dropped it
// in tab mode and then nested a second one underneath, and five reported a
// working tree they had never looked at. These check the shape of the contract
// where it can be checked without standing up six live sessions.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/repository_context.dart';
import 'package:remote_magic_git/features/common/repository_context_bar.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';

const _screens = {
  'Repository': 'lib/features/repository/repo_status_view.dart',
  'History': 'lib/features/history/history_view.dart',
  'Branches': 'lib/features/branches/branches_view.dart',
  'Stashes': 'lib/features/stash/stash_view.dart',
  'Forge': 'lib/features/forge/forge_workspace.dart',
  'Worktrees': 'lib/features/worktrees/worktrees_view.dart',
};

String _read(String path) => File(path).readAsStringSync();

Future<void> _pumpBar(
  WidgetTester tester,
  RepositoryContextSnapshot snapshot,
) async {
  tester.view.physicalSize = const Size(1100, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: 1100,
          height: 200,
          child: RepositoryContextBar(
            snapshot: snapshot,
            primaryAction: resolvePrimaryRepositoryAction(snapshot),
            onPrimaryAction: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('no screen falsifies its primary action', () {
    test('none of them borrows a kind that names a different verb', () {
      // `fetch` is a real verb with a real button; a screen whose primary
      // action stashes, refreshes, prunes or adds a worktree names that.
      for (final MapEntry(key: screen, value: path) in _screens.entries) {
        final source = _read(path);
        final borrowsFetch = source.contains(
          'kind: RepositoryPrimaryActionKind.fetch,',
        );
        if (!borrowsFetch) continue;
        expect(
          RegExp(
            r"kind: RepositoryPrimaryActionKind\.fetch,\s*\n\s*label: 'Fetch",
          ).hasMatch(source),
          isTrue,
          reason: '$screen claims kind fetch for a non-fetch label',
        );
      }
    });

    test('every kind a screen names exists in the enum', () {
      final known = RepositoryPrimaryActionKind.values
          .map((kind) => kind.name)
          .toSet();
      final used = <String>{};
      for (final path in _screens.values) {
        for (final match in RegExp(
          r'kind: RepositoryPrimaryActionKind\.(\w+)',
        ).allMatches(_read(path))) {
          used.add(match.group(1)!);
        }
      }
      expect(used, isNotEmpty);
      expect(used.difference(known), isEmpty);
    });
  });

  group('the status summary only reports what a screen knows', () {
    testWidgets('a screen with no working-tree status says nothing about it', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        const RepositoryContextSnapshot(
          repositoryPath: '/srv/repo',
          repositoryName: 'repo',
          branchLabel: 'main',
        ),
      );

      // The old default of 0 made this read "Clean" on History, Branches,
      // Stashes, Forge and Worktrees — none of which runs `git status`.
      expect(find.text('Clean'), findsNothing);
    });

    testWidgets('a clean tree is still reported as clean', (tester) async {
      await _pumpBar(
        tester,
        const RepositoryContextSnapshot(
          repositoryPath: '/srv/repo',
          repositoryName: 'repo',
          branchLabel: 'main',
          changedCount: 0,
          conflictCount: 0,
        ),
      );

      expect(find.text('Clean'), findsOneWidget);
    });

    testWidgets('ahead/behind still show without working-tree status', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        const RepositoryContextSnapshot(
          repositoryPath: '/srv/repo',
          repositoryName: 'repo',
          branchLabel: 'main',
          ahead: 2,
          behind: 1,
        ),
      );

      expect(find.textContaining('↑2'), findsOneWidget);
      expect(find.textContaining('↓1'), findsOneWidget);
    });
  });

  group('the bar is never dropped and never doubled', () {
    test('the forge router keeps the shell on every outcome', () {
      final source = _read('lib/features/forge/forge_panel.dart');
      // Loading, error, none and unknown used to return bare content.
      expect(
        'ForgeRepositoryWorkspace('.allMatches(source).length,
        greaterThanOrEqualTo(4),
        reason: 'a forge router outcome renders without repository chrome',
      );
    });

    testWidgets('a nested workspace contributes content, not a second bar', (
      tester,
    ) async {
      Widget scaffold() => const RepositoryWorkspaceScaffold(
        repositoryContext: Text('inner bar'),
        canvas: Text('inner canvas'),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 1100,
              height: 600,
              child: NestedWorkspaceScope(child: scaffold()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('inner canvas'), findsOneWidget);
      expect(find.text('inner bar'), findsNothing);
    });

    testWidgets('a top-level workspace still renders its bar', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 1100,
              height: 600,
              child: RepositoryWorkspaceScaffold(
                repositoryContext: Text('outer bar'),
                canvas: Text('outer canvas'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('outer bar'), findsOneWidget);
      expect(find.text('outer canvas'), findsOneWidget);
    });
  });

  group('Back and Forward', () {
    testWidgets('are offered by the bar itself, so every screen has them', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        const RepositoryContextSnapshot(
          repositoryPath: '/srv/repo',
          repositoryName: 'repo',
          branchLabel: 'main',
        ),
      );

      // Present but honest about having nowhere to go — they used to be dead
      // on five of six screens because nothing handed them a callback.
      expect(
        find.bySemanticsLabel(RegExp('Back')),
        findsWidgets,
        reason: 'the Back control must exist on every screen',
      );
      expect(find.bySemanticsLabel(RegExp('Forward')), findsWidgets);
    });

    test('no screen passes navigation callbacks any more', () {
      for (final MapEntry(key: screen, value: path) in _screens.entries) {
        final source = _read(path);
        expect(
          source.contains('onBack:') || source.contains('onForward:'),
          isFalse,
          reason:
              '$screen still hands navigation down; the bar owns it now, and '
              'two mechanisms is how five screens ended up with neither',
        );
      }
    });
  });
}
