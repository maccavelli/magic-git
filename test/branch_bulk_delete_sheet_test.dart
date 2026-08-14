// The base-safe bulk-delete preflight (plan 0003 §4.8), which shipped as a
// flat "Will delete (n)" list with no test coverage at all.
//
// Two properties matter most here: an unverifiable forge protection must be
// SAID rather than treated as clearance, and an eligible row must be
// individually droppable — otherwise a user wanting to spare one branch has to
// cancel and rebuild the whole selection.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/branch_comparison.dart';
import 'package:remote_magic_git/core/git/branch_review_query.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/branches/branch_bulk_delete_sheet.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';

const _repo = '/repo';
const _baseOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _RecordingGit extends GitService {
  _RecordingGit() : super(SSHCommandExecutor(SSHClientManager()));

  final List<String> deleted = [];

  @override
  Future<BaseDeleteResult> deleteBranchMergedIntoBase(
    String repoPath, {
    required String branchName,
    required String expectedBranchOid,
    required String baseOid,
  }) async {
    deleted.add(branchName);
    return BaseDeleteResult(
      branchName: branchName,
      status: BaseDeleteStatus.deleted,
    );
  }
}

BulkDeleteCandidate _candidate(
  String name, {
  String? skipReason,
  ProtectionKnowledge protection = const ProtectionKnowledge.unknown(),
  int? aheadOfBase,
  String? requestLabel,
}) => BulkDeleteCandidate(
  branchName: name,
  fullRef: 'refs/heads/$name',
  expectedOid: name.padRight(40, '0').substring(0, 40),
  skipReason: skipReason,
  protection: protection,
  aheadOfBase: aheadOfBase,
  requestLabel: requestLabel,
);

/// The sheet TITLE also starts with "Delete", so target the footer button.
Finder _deleteButton() => find.byWidgetPredicate(
  (w) => w is InlineActionButton && w.label.startsWith('Delete '),
);

Future<_RecordingGit> _openSheet(
  WidgetTester tester,
  List<BulkDeleteCandidate> candidates,
) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final git = _RecordingGit();
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Center(
          child: PushButton(
            controlSize: ControlSize.large,
            // A sheet that pops itself needs a route beneath it.
            onPressed: () => showBranchBulkDeleteSheet(
              context,
              git: git,
              repoPath: _repo,
              baseOid: _baseOid,
              baseDisplayName: 'main',
              candidates: candidates,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return git;
}

void main() {
  testWidgets('unverifiable protection is stated, not treated as clearance', (
    tester,
  ) async {
    await _openSheet(tester, [
      _candidate('feature'), // protection unknown by default
    ]);

    expect(
      find.textContaining('protection could not be verified'),
      findsOneWidget,
    );
    expect(find.textContaining('protection unknown'), findsOneWidget);
  });

  testWidgets('a confirmed-unprotected batch raises no warning', (
    tester,
  ) async {
    await _openSheet(tester, [
      _candidate(
        'feature',
        protection: const ProtectionKnowledge.unprotected(),
      ),
    ]);

    expect(
      find.textContaining('protection could not be verified'),
      findsNothing,
    );
    expect(find.textContaining('unprotected'), findsOneWidget);
  });

  testWidgets('a protected branch is skipped with the reason shown', (
    tester,
  ) async {
    final git = await _openSheet(tester, [
      _candidate(
        'main',
        skipReason: 'protected on the forge',
        protection: const ProtectionKnowledge.protected(),
      ),
      _candidate(
        'feature',
        protection: const ProtectionKnowledge.unprotected(),
      ),
    ]);

    expect(find.text('Skipped (1)'), findsOneWidget);
    expect(find.textContaining('protected on the forge'), findsOneWidget);
    expect(find.text('Will delete (1)'), findsOneWidget);

    await tester.tap(_deleteButton());
    await tester.pumpAndSettle();

    // The server would refuse it anyway; skipping explains why instead of
    // reporting a bare failure.
    expect(git.deleted, ['feature']);
  });

  testWidgets('an eligible row can be unchecked without redoing the whole '
      'selection', (tester) async {
    final git = await _openSheet(tester, [
      _candidate('one', protection: const ProtectionKnowledge.unprotected()),
      _candidate('two', protection: const ProtectionKnowledge.unprotected()),
    ]);

    expect(find.text('Will delete (2)'), findsOneWidget);

    await tester.tap(find.byType(MacosCheckbox).first);
    await tester.pumpAndSettle();
    expect(find.text('Will delete (1)'), findsOneWidget);

    await tester.tap(_deleteButton());
    await tester.pumpAndSettle();

    expect(git.deleted, ['two']);
  });

  testWidgets('the row carries the facts that decide the outcome', (
    tester,
  ) async {
    await _openSheet(tester, [
      _candidate(
        'feature',
        protection: const ProtectionKnowledge.unprotected(),
        aheadOfBase: 3,
        requestLabel: '#42',
      ),
    ]);

    // Tip, distance from base, protection and an open request that would be
    // orphaned — all on one line.
    expect(find.textContaining('↑3'), findsOneWidget);
    expect(find.textContaining('#42'), findsOneWidget);
    expect(find.textContaining('unprotected'), findsOneWidget);
  });
}
