// 0009 H10: while PR detail is in flight the readiness strip must say
// Checking — a list-tier plan's canMergeNow means "not hard-blocked" (list
// JSON has no mergeable/mergeStateStatus), never "Ready to merge".

import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/merge_plan.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/features/forge/merge_readiness.dart';

const _listTierPr = PullRequest(
  number: 7,
  title: 'Add the parser',
  state: 'open',
  merged: false,
  draft: false,
  headRefName: 'feat',
  baseRefName: 'main',
  url: '',
);

Future<void> _pump(
  WidgetTester tester,
  MergePlan plan, {
  required bool detailLoading,
}) async {
  await tester.pumpWidget(
    MacosApp(
      home: MergeReadinessStrip(plan: plan, detailLoading: detailLoading),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Checking wins over a list-tier canMergeNow', (tester) async {
    final plan = mergePlanForGitHub(pr: _listTierPr);
    // The intentional list-row contract (see merge_plan_test): unknown
    // mergeability must not hard-block a row…
    expect(plan.canMergeNow, isTrue);

    // …but the detail strip must not read it as Ready while detail loads.
    await _pump(tester, plan, detailLoading: true);
    expect(find.text('Checking mergeability…'), findsOneWidget);
    expect(find.text('Ready to merge'), findsNothing);
  });

  testWidgets('a detail-tier ready plan still reads Ready to merge', (
    tester,
  ) async {
    final plan = mergePlanForGitHub(
      pr: const PullRequest(
        number: 7,
        title: 'Add the parser',
        state: 'open',
        merged: false,
        draft: false,
        headRefName: 'feat',
        baseRefName: 'main',
        url: '',
        headOid: 'aabbccddeeff00112233445566778899aabbccdd',
        mergeable: GhMergeable.mergeable,
        mergeStateStatus: 'CLEAN',
        reviewDecision: 'APPROVED',
      ),
    );
    await _pump(tester, plan, detailLoading: false);
    expect(find.text('Ready to merge'), findsOneWidget);
  });

  testWidgets('blocked reasons render once detail has landed', (tester) async {
    final plan = mergePlanForGitHub(
      pr: const PullRequest(
        number: 7,
        title: 'Add the parser',
        state: 'open',
        merged: false,
        draft: true,
        headRefName: 'feat',
        baseRefName: 'main',
        url: '',
      ),
    );
    await _pump(tester, plan, detailLoading: false);
    expect(find.text('Ready to merge'), findsNothing);
    expect(find.textContaining('Draft pull requests'), findsOneWidget);
  });
}
