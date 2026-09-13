// A worktree row must stay inside the navigator pane at every width the user
// can drag it to (240–720 pt), however long the name, branch or lock reason.
//
// Reported from a running build: with a long-named worktree the row's name and
// its branch chip crossed the divider and painted over the detail pane, while
// the path line beneath them ellipsized correctly — the clue that parts of the
// row are bounded and parts are not (MADR 0049).
//
// A RenderFlex overflow is thrown as a test exception, so `takeException`
// catches the regression rather than a human noticing a screenshot.

@Tags(['integration'])
library;

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/features/common/label_chip.dart';
import 'package:remote_magic_git/features/worktrees/worktrees_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';

/// The reported case: a 60-character directory name on a 50-character branch.
const _longName =
    'magic-git-scratch-scratch-branch-for-margain-testing-overflow';
const _longBranch =
    'refs/heads/scratch/scratch-branch-for-margain-testing-overflow';

/// A lock reason is free text a user types, so it has no natural bound.
const _longReason =
    'held while the release branch is being cut, do not remove this worktree '
    'until the release manager says the tag has been pushed and verified';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

List<GitWorktree> _worktrees({bool locked = false}) => [
  const GitWorktree(
    path: '$_repo/magic-git',
    branch: 'refs/heads/master',
    isMain: true,
  ),
  GitWorktree(
    path: '$_repo/$_longName',
    branch: _longBranch,
    isLocked: locked,
    lockReason: locked ? _longReason : null,
  ),
];

/// Pumps the Worktrees page with the navigator pinned to [paneWidth].
///
/// Both providers are overridden: `watchWorkspacePreferences` falls back to the
/// screen's own default when repository identity is null, so pinning the width
/// needs an identity as well as the stored record.
Future<void> _pump(
  WidgetTester tester, {
  required double paneWidth,
  bool locked = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      gitWorktreesProvider(
        _repo,
      ).overrideWith((ref) async => _worktrees(locked: locked)),
      repositoryUiIdentityProvider(_repo).overrideWith(
        (ref) async => RepositoryUiIdentity.local(
          localRepoId: 'L1',
          gitCommonDir: '$_repo/.git',
        ),
      ),
      repositoryWorkspacePrefsProvider(_repo).overrideWith(
        (ref) async => RepositoryWorkspacePrefs(navigatorWidth: paneWidth),
      ),
      connectionProvider.overrideWith(
        () => _StubConnection(
          const ConnectionState(
            backend: ConnectionBackend.local,
            phase: ConnectionPhase.connected,
            repoPath: _repo,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MacosApp(
        debugShowCheckedModeBanner: false,
        home: MacosWindow(child: WorktreesView(repoPath: _repo)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Truncation is only acceptable because the full text stays reachable — the
  // whole argument for bounding these chips (MADR 0049's Decision Outcome).
  // A chip capped at 100 pt with no hover is not a fix, it is a different
  // defect, and moving the strip to ChipStrip once shipped exactly that:
  // a strip tooltips the chips it HIDES, so every VISIBLE chip lost its
  // hover (plan deviation (b)). The tooltip now lives in LabelChip itself.
  testWidgets('the worktree name ellipsizes rather than widening the row', (
    tester,
  ) async {
    await _pump(tester, paneWidth: RepositoryWorkspacePrefs.minNavigatorWidth);

    final name = tester.widget<Text>(find.text(_longName));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(
      name.softWrap,
      isFalse,
      reason: 'a wrapping name grows the row taller instead of truncating',
    );
  });

  testWidgets('a chip never draws wider than its cap, on one line', (
    tester,
  ) async {
    await _pump(tester, paneWidth: RepositoryWorkspacePrefs.maxNavigatorWidth);

    // At the WIDEST pane, where nothing else forces the chips smaller: the cap
    // is the chip's own, not something the row imposed on it.
    final chips = tester.widgetList<LabelChip>(find.byType(LabelChip));
    expect(chips, isNotEmpty);
    for (final chip in chips) {
      final size = tester.getSize(find.byWidget(chip));
      expect(
        size.width,
        lessThanOrEqualTo(chip.maxWidth),
        reason: 'chip "${chip.text}" drew ${size.width} pt past its cap',
      );
      // Without the ellipsis inside the chip its label WRAPS within the cap,
      // which trades a too-wide chip for a too-tall one.
      expect(
        size.height,
        lessThan(24),
        reason: 'chip "${chip.text}" wrapped to ${size.height} pt tall',
      );
    }
  });

  testWidgets('a visible, truncated chip is still reachable by tooltip', (
    tester,
  ) async {
    await _pump(tester, paneWidth: RepositoryWorkspacePrefs.minNavigatorWidth);

    final messages = tester
        .widgetList<MacosTooltip>(find.byType(MacosTooltip))
        .map((t) => t.message)
        .toList();

    // The branch chip is shown, and ellipsized at _rowChipMaxWidth — so its
    // full label has to be somewhere a person can get at.
    expect(
      messages,
      contains('Branch: ${_longBranch.replaceFirst('refs/heads/', '')}'),
      reason: 'the branch chip is truncated with no way to read it',
    );
    // And the name beside it, for the same reason.
    expect(messages, contains(_longName));
  });

  testWidgets('a lock reason is reachable even when the chip is capped', (
    tester,
  ) async {
    await _pump(
      tester,
      paneWidth: RepositoryWorkspacePrefs.minNavigatorWidth,
      locked: true,
    );

    final messages = tester
        .widgetList<MacosTooltip>(find.byType(MacosTooltip))
        .map((t) => t.message)
        .toList();
    expect(
      messages.any((m) => m.contains(_longReason)),
      isTrue,
      reason:
          'the lock reason exists nowhere else in the panel; messages '
          'were: $messages',
    );
  });

  for (final width in <double>[
    RepositoryWorkspacePrefs.minNavigatorWidth,
    RepositoryWorkspacePrefs.defaultNavigatorWidth,
    RepositoryWorkspacePrefs.maxNavigatorWidth,
  ]) {
    testWidgets('a long name and branch stay inside a ${width.toInt()}pt '
        'navigator', (tester) async {
      await _pump(tester, paneWidth: width);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a lock reason of arbitrary length does not overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      paneWidth: RepositoryWorkspacePrefs.minNavigatorWidth,
      locked: true,
    );
    expect(tester.takeException(), isNull);
  });
}
