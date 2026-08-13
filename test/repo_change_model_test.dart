import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';

GitStatus _status(List<GitFileStatus> files) => GitStatus(
  branch: const GitBranchInfo(head: 'main'),
  files: files,
);

void main() {
  test('partially staged path has independent row identities', () {
    final rows = deriveRepoChangeRows(
      _status(const [
        GitFileStatus(path: 'lib/mixed.dart', statusX: 'M', statusY: 'M'),
      ]),
    ).whereType<RepoChangeFileRow>().toList();

    expect(rows, hasLength(2));
    expect(
      rows.map((row) => row.identity),
      containsAll(['staged:lib/mixed.dart', 'unstaged:lib/mixed.dart']),
    );
  });

  test('selection never spans status sections and ranges stay local', () {
    final rows = deriveRepoChangeRows(
      _status(const [
        GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'b.dart', statusX: '.', statusY: 'M'),
        GitFileStatus(path: 'c.dart', statusX: 'M', statusY: '.'),
      ]),
    );
    final first = const RepoChangeSelection.empty().select(
      rows,
      'a.dart',
      RepoChangeSection.unstaged,
    );
    final range = first.select(
      rows,
      'b.dart',
      RepoChangeSection.unstaged,
      range: true,
    );
    final replaced = range.select(
      rows,
      'c.dart',
      RepoChangeSection.staged,
      toggle: true,
    );

    expect(range.paths, {'a.dart', 'b.dart'});
    expect(replaced.section, RepoChangeSection.staged);
    expect(replaced.paths, {'c.dart'});
  });

  test('refresh rehomes a complete selection and prunes a partial move', () {
    final staged =
        const RepoChangeSelection(
          section: RepoChangeSection.unstaged,
          paths: {'a.dart', 'b.dart'},
          anchor: 'a.dart',
        ).reconcile(
          _status(const [
            GitFileStatus(path: 'a.dart', statusX: 'M', statusY: '.'),
            GitFileStatus(path: 'b.dart', statusX: 'M', statusY: '.'),
          ]),
        );
    expect(staged.section, RepoChangeSection.staged);
    expect(staged.paths, {'a.dart', 'b.dart'});

    final pruned =
        const RepoChangeSelection(
          section: RepoChangeSection.unstaged,
          paths: {'a.dart', 'b.dart'},
          anchor: 'a.dart',
        ).reconcile(
          _status(const [
            GitFileStatus(path: 'a.dart', statusX: 'M', statusY: '.'),
            GitFileStatus(path: 'b.dart', statusX: '.', statusY: 'M'),
          ]),
        );
    expect(pruned.section, RepoChangeSection.unstaged);
    expect(pruned.paths, {'b.dart'});
    expect(pruned.anchor, 'b.dart');
  });
}
