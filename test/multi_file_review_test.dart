import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/features/repository/multi_file_review.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';
import 'package:remote_magic_git/features/repository/repo_review_state.dart';

const _diff = 'diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n';

void main() {
  testWidgets('watches active diff and prefetches no more than next two', (
    tester,
  ) async {
    final controller = RepoReviewController()
      ..open([
        for (var i = 0; i < 100; i++)
          ReviewItemId(
            section: RepoChangeSection.unstaged,
            path: '$i.dart',
            worktreeRevision: '1',
          ),
      ]);
    addTearDown(controller.dispose);
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        for (var i = 0; i < 100; i++)
          fileDiffProvider(('/repo', '$i.dart', false, false, 3)).overrideWith((
            ref,
          ) async {
            reads++;
            return _diff;
          }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MacosApp(
          home: SizedBox(
            width: 900,
            height: 500,
            child: MultiFileReviewView(
              repoPath: '/repo',
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(reads, lessThanOrEqualTo(3));
    expect(find.text('1 of 100'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 100'), findsOneWidget);
  });

  testWidgets('a failed active diff retains navigation and reviewed state', (
    tester,
  ) async {
    const first = ReviewItemId(
      section: RepoChangeSection.unstaged,
      path: 'bad.dart',
      worktreeRevision: '1',
    );
    const second = ReviewItemId(
      section: RepoChangeSection.unstaged,
      path: 'good.dart',
      worktreeRevision: '1',
    );
    final controller = RepoReviewController()..open(const [first, second]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileDiffProvider((
            '/repo',
            'bad.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => throw Exception('broken')),
          fileDiffProvider((
            '/repo',
            'good.dart',
            false,
            false,
            3,
          )).overrideWith((ref) async => _diff),
        ],
        child: MacosApp(
          home: SizedBox(
            width: 900,
            height: 500,
            child: MultiFileReviewView(
              repoPath: '/repo',
              controller: controller,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load bad.dart'), findsOneWidget);
    await tester.tap(find.text('Mark Reviewed'));
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    expect(controller.value.reviewed, contains(first));
  });
}
