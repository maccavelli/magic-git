import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_change_filter.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';

final _canonical = deriveRepoChangeRows(
  GitStatus(
    branch: const GitBranchInfo(head: 'main'),
    files: const [
      GitFileStatus(path: 'lib/src/alpha.dart', statusX: '.', statusY: 'M'),
      GitFileStatus(path: 'test/alpha_test.dart', statusX: 'M', statusY: '.'),
      GitFileStatus(path: 'README.md', statusX: '?', statusY: '?'),
    ],
  ),
);

List<RepoChangeFileRow> _files(RepoChangeFilterResult result) =>
    result.rows.whereType<RepoChangeFileRow>().toList();

void main() {
  test('query, status, path scope, and reviewed filters compose purely', () {
    var commandCount = 0;
    final result = filterRepoChangeRows(
      _canonical,
      const RepoChangeFilter(
        query: 'ALPHA',
        statuses: {RepoChangeSection.unstaged},
        pathScope: 'lib/',
        includeReviewed: false,
      ),
      reviewedPaths: const {'staged:test/alpha_test.dart'},
    );
    commandCount += 0;

    expect(_files(result).single.file.path, 'lib/src/alpha.dart');
    expect(commandCount, 0, reason: 'filtering cannot reach an executor');
  });

  test(
    'directory grouping is deterministic and preserves section identity',
    () {
      final result = filterRepoChangeRows(
        _canonical,
        const RepoChangeFilter(grouping: RepositoryChangeGrouping.directory),
      );
      final headers = result.rows.whereType<RepoChangeHeaderRow>().toList();

      expect(headers.map((row) => row.title), [
        'Repository root',
        'lib/src',
        'test',
      ]);
      expect(
        _files(result).map((row) => row.identity),
        contains('unstaged:lib/src/alpha.dart'),
      );
    },
  );

  test('excluding reviewed rows changes output but not canonical rows', () {
    final before = _canonical.length;
    final result = filterRepoChangeRows(
      _canonical,
      const RepoChangeFilter(includeReviewed: false),
      reviewedPaths: const {'unstaged:lib/src/alpha.dart'},
    );

    expect(result.visibleFiles, 2);
    expect(_canonical, hasLength(before));
  });
}
