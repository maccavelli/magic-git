import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';
import 'package:remote_magic_git/features/repository/repo_review_state.dart';

void main() {
  test('queue follows canonical row order rather than Set iteration', () {
    final rows = deriveRepoChangeRows(
      GitStatus(
        branch: const GitBranchInfo(head: 'main'),
        files: const [
          GitFileStatus(path: 'z.dart', statusX: '.', statusY: 'M'),
          GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M'),
        ],
      ),
    );
    final items = reviewItemsFromRows(
      rows,
      paths: {'a.dart', 'z.dart'},
      section: RepoChangeSection.unstaged,
    );
    expect(items.map((item) => item.path), ['z.dart', 'a.dart']);
  });

  test('reviewed identity resets only when worktree revision changes', () {
    const old = ReviewItemId(
      section: RepoChangeSection.unstaged,
      path: 'a.dart',
      worktreeRevision: '.M:',
    );
    const changed = ReviewItemId(
      section: RepoChangeSection.staged,
      path: 'a.dart',
      worktreeRevision: 'M.:',
    );
    final reviewed = const RepoReviewState(
      items: [old],
    ).toggleReviewed(old).replaceItems(const [old]);
    expect(reviewed.reviewed, {old});
    expect(reviewed.replaceItems(const [changed]).reviewed, isEmpty);
  });

  test('navigation clamps and preserves active identity on refresh', () {
    const one = ReviewItemId(
      section: RepoChangeSection.unstaged,
      path: 'one',
      worktreeRevision: '1',
    );
    const two = ReviewItemId(
      section: RepoChangeSection.unstaged,
      path: 'two',
      worktreeRevision: '1',
    );
    final state = const RepoReviewState(
      items: [one, two],
    ).move(50).replaceItems(const [two, one]);
    expect(state.active, two);
    expect(state.activeIndex, 0);
  });
}
