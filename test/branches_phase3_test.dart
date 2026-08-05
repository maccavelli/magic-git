// Branches detail comparison commits (baseOid..branchOid) and keyboard
// navigation across all sections. The former HEAD-relative dashboard cleanup
// is intentionally absent until the base-safe Phase 4 flow replaces it.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

const _repo = '/repo';
const _mainOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _featureOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _otherOid = 'cccccccccccccccccccccccccccccccccccccccc';
const _remoteOid = 'dddddddddddddddddddddddddddddddddddddddd';
const _tagOid = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

const _refs = [
  GitRef(name: 'refs/heads/main', oid: _mainOid, isHead: true, subject: 's'),
  GitRef(
    name: 'refs/heads/feature',
    oid: _featureOid,
    isHead: false,
    subject: 's',
  ),
  GitRef(name: 'refs/heads/other', oid: _otherOid, isHead: false, subject: 's'),
  GitRef(
    name: 'refs/remotes/origin/topic',
    oid: _remoteOid,
    isHead: false,
    subject: 's',
  ),
  GitRef(name: 'refs/tags/v1', oid: _tagOid, isHead: false, subject: 's'),
];

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final deleted = <String>[];
  final checkouts = <String>[];
  final trackingCheckouts = <(String, String)>[]; // (localName, remoteRef)
  Map<String, List<GitCommit>> logsByRevision = const {};

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async {
    deleted.add(name);
  }

  @override
  Future<void> checkout(String repoPath, String ref) async {
    checkouts.add(ref);
  }

  @override
  Future<void> checkoutTrackingBranch(
    String repoPath, {
    required String localName,
    required String remoteRef,
  }) async {
    trackingCheckouts.add((localName, remoteRef));
  }

  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async {
    final allCommits = logsByRevision[revision] ?? const <GitCommit>[];
    if (skip >= allCommits.length) return const [];
    return allCommits.skip(skip).take(maxCount).toList();
  }
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-10T10:00:00Z',
  parents: const ['p'],
  subject: subject,
);

Future<_FakeGit> _pump(
  WidgetTester tester, {
  List<GitRef> refs = _refs,
  Set<String> merged = const {},
  Map<String, List<GitCommit>> logsByRevision = const {},
}) async {
  tester.view.physicalSize = const Size(1500, 1300);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final git = _FakeGit()..logsByRevision = logsByRevision;
  final container = ProviderContainer(
    overrides: [
      gitServiceProvider.overrideWithValue(git),
      refsProvider(_repo).overrideWith((ref) async => refs),
      remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
      remoteTagsProvider(_repo).overrideWith((ref) async => null),
      branchForgeProvider(_repo).overrideWith((ref) async => const {}),
      mergedBranchesProvider(_repo).overrideWith((ref) async => merged),
      statusProvider(_repo).overrideWith(
        (ref) async => GitStatus(
          branch: const GitBranchInfo(head: 'main', oid: _mainOid),
          files: const [],
        ),
      ),
      branchBaseProvider.overrideWith(
        (ref, key) async => const BranchBaseResolution(
          base: BranchBase(
            refName: 'refs/heads/main',
            displayName: 'main',
            oid: _mainOid,
            source: BranchBaseSource.localMain,
            isFallback: false,
          ),
        ),
      ),
      branchComparisonMetadataProvider.overrideWith(
        (ref, key) async => BranchComparisonMetadata.unrelated(
          baseOid: key.baseOid,
          branchOid: key.branchOid,
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
        home: BranchesView(repoPath: _repo),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('the detail pane shows unique commits vs the comparison base', (
    tester,
  ) async {
    await _pump(
      tester,
      logsByRevision: {
        '$_mainOid..$_featureOid': [
          _commit('abcdef1234abcdef1234abcdef1234abcdef1234', 'Wire the thing'),
          _commit('bbccdd5678bbccdd5678bbccdd5678bbccdd5678', 'Add a test'),
        ],
      },
    );

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    // Overview is default; open Commits tab for unique history.
    await tester.tap(find.text('Commits'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Commits only on feature'), findsOneWidget);
    expect(find.text('Wire the thing'), findsOneWidget);
    expect(find.text('Add a test'), findsOneWidget);
  });

  testWidgets('the dashboard has no HEAD-relative merged bulk delete', (
    tester,
  ) async {
    final git = await _pump(tester, merged: const {'feature', 'other'});

    expect(find.text('Branches'), findsOneWidget);
    expect(find.textContaining('Delete 2 merged'), findsNothing);
    expect(git.deleted, isEmpty);
  });

  testWidgets('arrow keys walk across local, remote and tag sections', (
    tester,
  ) async {
    await _pump(tester);

    // Select a local branch, then arrow down into the remote section.
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    // feature → other → origin/topic (remote). Two downs.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    // The detail pane now shows the remote's action — nav crossed sections.
    expect(
      find.widgetWithText(InlineActionButton, 'Check out tracking branch'),
      findsOneWidget,
    );
  });

  testWidgets('a remote with no matching local branch creates an explicit '
      'tracking branch (never a DWIM checkout)', (tester) async {
    final git = await _pump(tester);

    // origin/topic has no local `topic` — select it and check out.
    await tester.tap(find.text('origin/topic'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(InlineActionButton, 'Check out tracking branch'),
    );
    await tester.pumpAndSettle();

    expect(git.trackingCheckouts, [('topic', 'origin/topic')]);
    expect(git.checkouts, isEmpty, reason: 'must not fall back to DWIM');
  });

  testWidgets('double-clicking a local branch checks it out; a single click '
      'only selects', (tester) async {
    final git = await _pump(tester);

    // Single tap selects but does NOT check out. `.first`: once selected the
    // detail header also renders the branch name.
    await tester.tap(find.text('feature').first);
    await tester.pumpAndSettle();
    expect(git.checkouts, isEmpty, reason: 'one click only selects');

    // A quick second tap on the same row checks it out.
    await tester.tap(find.text('feature').first);
    await tester.pumpAndSettle();
    expect(git.checkouts, ['feature']);
  });

  testWidgets('a remote whose local branch already exists switches to it '
      '(plain checkout, no re-create)', (tester) async {
    const refs = [
      GitRef(
        name: 'refs/heads/main',
        oid: _mainOid,
        isHead: true,
        subject: 's',
      ),
      GitRef(
        name: 'refs/heads/topic',
        oid: _featureOid,
        isHead: false,
        subject: 's',
      ),
      GitRef(
        name: 'refs/remotes/origin/topic',
        oid: _remoteOid,
        isHead: false,
        subject: 's',
      ),
    ];
    final git = await _pump(tester, refs: refs);

    await tester.tap(find.text('origin/topic'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(InlineActionButton, 'Check out tracking branch'),
    );
    await tester.pumpAndSettle();

    expect(git.checkouts, ['topic']);
    expect(git.trackingCheckouts, isEmpty);
  });
}
