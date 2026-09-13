// Does any OTHER chip row in the app overflow the way the worktree row did?
//
// MADR 0049 reproduced exactly one surface and said so: F6 establishes that
// every navigator *can* overflow, not that any other does. Its "Not
// established" asked for the same pathological fixtures through the remaining
// chip rows before the class is called closed. This file is that measurement,
// and the answer it records is as much a finding when a surface is clean as
// when it is not.
//
// Two widget families are covered, because they fail differently:
//
//   * `LabelChip` rows (branches, stashes, the connection switcher) sit in a
//     `Row`, which paints its overflow OUTSIDE its bounds — the worktree
//     row's failure mode exactly.
//   * `ForgeLabelChip` / `MiniLabelChip` (the forge panels) sit in `Wrap`s.
//     A `Wrap` moves children to the next run instead of overflowing, so many
//     chips are safe; what it cannot do is split a SINGLE child. The fixture
//     there is therefore one very long label, not many.

@Tags(['integration'])
library;

import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/storage/repository_ui_identity.dart';
import 'package:remote_magic_git/core/storage/saved_local_repo.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/label_chip.dart';
import 'package:remote_magic_git/features/common/section_collapse.dart';
import 'package:remote_magic_git/features/forge/forge_widgets.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'package:remote_magic_git/features/switcher/connection_switcher.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';

const _repo = '/repo';
const _narrow = RepositoryWorkspacePrefs.minNavigatorWidth; // 240

/// Pathological but legal values — every one of these is something a forge or
/// a filesystem will hand the app.
const _longBranch =
    'refs/heads/feature/an-extremely-long-branch-name-that-nobody-would-type'
    '-but-a-generator-will';

/// `GitRef.shortName` — the key `branchForgeProvider` and `mergedBranches` are
/// looked up by. Keying the fixtures on the full ref instead silently yields a
/// row with ONE chip, which is a much weaker case than this file claims to
/// measure.
const _longBranchShort =
    'feature/an-extremely-long-branch-name-that-nobody-would-type'
    '-but-a-generator-will';
const _longWorktreePath =
    '/Users/<user>/code/checkouts/an-extremely-long-worktree-directory-name';
const _longLabel =
    'needs-triage-from-the-platform-team-before-the-next-release-window';

class _NoopGit extends GitService {
  _NoopGit() : super(SSHCommandExecutor(SSHClientManager()));
}

/// Pins the navigator to [width] the way `worktree_row_overflow_test` does:
/// `watchWorkspacePreferences` falls back to the screen's own default when the
/// repository identity is null, so the stored record needs an identity too.
List<Override> _pinnedNavigator(double width) => [
  repositoryUiIdentityProvider(_repo).overrideWith(
    (ref) async => RepositoryUiIdentity.local(
      localRepoId: 'L1',
      gitCommonDir: '$_repo/.git',
    ),
  ),
  repositoryWorkspacePrefsProvider(_repo).overrideWith(
    (ref) async => RepositoryWorkspacePrefs(navigatorWidth: width),
  ),
];

Future<void> _pumpView(
  WidgetTester tester,
  Widget home, {
  required List<Override> overrides,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(debugShowCheckedModeBanner: false, home: home),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Branches page at the narrowest pane, with a branch that carries every
/// badge at once: checked out in a long-named worktree, merged, and with an
/// open request. The forge and merged fixtures are keyed by `shortName`
/// because that is what the row looks them up by — keyed by the full ref they
/// silently yield a one-chip row.
Future<void> _pumpBranches(WidgetTester tester) => _pumpView(
  tester,
  const MacosWindow(child: BranchesView(repoPath: _repo)),
  overrides: [
    gitServiceProvider.overrideWithValue(_NoopGit()),
    refsProvider(_repo).overrideWith(
      (ref) async => const [
        GitRef(name: 'refs/heads/main', oid: 'a', isHead: true, subject: 's'),
        GitRef(
          name: _longBranch,
          oid: 'b',
          isHead: false,
          subject: 's',
          // Drives the purple "checked out elsewhere" chip, whose label is the
          // worktree directory's last path segment.
          worktreePath: _longWorktreePath,
        ),
      ],
    ),
    remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
    remoteTagsProvider(_repo).overrideWith((ref) async => null),
    branchForgeProvider(_repo).overrideWith(
      (ref) async => const <String, BranchForge>{
        _longBranchShort: BranchForge(requestNumber: 12345, isMr: true),
      },
    ),
    mergedBranchesProvider(
      _repo,
    ).overrideWith((ref) async => const <String>{_longBranchShort}),
    ..._pinnedNavigator(_narrow),
  ],
);

void main() {
  group('LabelChip rows', () {
    testWidgets('a branch row with a long name and a long worktree chip', (
      tester,
    ) async {
      await _pumpBranches(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a branch badge still has width at 240 pt', (tester) async {
      // `chipsMayShrink` buys containment by letting chips give way — and a
      // flex child of a row with no free space gives way to NOTHING. History's
      // pop-out once rendered commit subjects with no badges at all for that
      // reason. Containment that erases the badge is not a fix, so the branch
      // row's chips are held to a visible width at the narrowest pane.
      await _pumpBranches(tester);

      final chips = tester.widgetList<LabelChip>(find.byType(LabelChip));
      expect(chips, isNotEmpty, reason: 'the fixture renders no chips at all');
      for (final chip in chips) {
        final size = tester.getSize(find.byWidget(chip));
        expect(
          size.width,
          greaterThan(8),
          reason: 'chip "${chip.text}" collapsed to ${size.width} pt',
        );
      }
    });

    testWidgets('a section header title truncates on one line', (tester) async {
      // Bounding the cluster alone is not enough: a title that WRAPS inside its
      // bound keeps the header from overflowing sideways by making it taller,
      // which is a different way to break the row (plan deviation (d.2)).
      await _pumpBranches(tester);

      final headers = tester.widgetList<CollapsibleSectionHeader>(
        find.byType(CollapsibleSectionHeader),
      );
      expect(headers, isNotEmpty, reason: 'the fixture renders no headers');
      for (final header in headers) {
        final title = tester.widget<Text>(
          find.descendant(
            of: find.byWidget(header),
            matching: find.text(header.title),
          ),
        );
        expect(title.maxLines, 1, reason: 'header "${header.title}"');
        expect(title.overflow, TextOverflow.ellipsis);
        expect(title.softWrap, isFalse);
      }
    });

    testWidgets('a stash row with a long subject and branch', (tester) async {
      await _pumpView(
        tester,
        const SizedBox(
          width: _narrow,
          height: 700,
          child: StashView(repoPath: _repo),
        ),
        overrides: [
          gitServiceProvider.overrideWithValue(_NoopGit()),
          stashesProvider(_repo).overrideWith(
            (ref) async => const [
              GitStash(
                index: 0,
                oid: 'deadbeef',
                branch:
                    'feature/an-extremely-long-branch-name-nobody-would-type',
                message:
                    'WIP on feature: a stash note long enough to need the '
                    'whole row and then a good deal more besides',
                relativeDate: '2 hours ago',
              ),
            ],
          ),
          ..._pinnedNavigator(_narrow),
        ],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a switcher tile for a long-labelled linked worktree', (
      tester,
    ) async {
      await _pumpView(
        tester,
        const SizedBox(width: _narrow, height: 700, child: ConnectionsPanel()),
        overrides: [
          savedLocalReposProvider.overrideWith(
            (ref) async => const [
              SavedLocalRepo(
                id: 'l1',
                label:
                    'an extremely long saved repository label that will '
                    'not fit in a narrow sidebar tile',
                repoPath: _longWorktreePath,
                mainRepoPath: '/Users/<user>/code/main-repo',
              ),
            ],
          ),
          savedConnectionsProvider.overrideWith((ref) async => const []),
          forgeRepoListProvider.overrideWith((ref, key) async => const []),
          forgeAuthHostProvider.overrideWith((ref, key) async => null),
        ],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('forge chips', () {
    // A Wrap cannot split ONE child, so a single over-long label is the only
    // way these can overflow — many labels simply take more runs.
    testWidgets('a single over-long MiniLabelChip in a narrow Wrap', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: _narrow,
              child: Wrap(children: [MiniLabelChip(_longLabel, null)]),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a single over-long ForgeLabelChip in a narrow Wrap', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: _narrow,
              child: Wrap(
                children: [
                  ForgeLabelChip(ForgeLabel(name: _longLabel, color: 'ff0000')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
