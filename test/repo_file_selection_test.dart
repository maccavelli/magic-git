// The repository pane's shared file selection (audit M13).
//
// Recorded as complete in plan 0004 but never built: the Changes list and the
// TWO FileView instances (docked pane + navigator tab) each kept their own,
// so switching Changes↔Files lost the highlight every time and the two trees
// could disagree about what was selected.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/repository/repo_change_model.dart';
import 'package:remote_magic_git/features/repository/repo_file_selection.dart';

const _repo = '/repo';

GitStatus _status({
  List<String> unstaged = const [],
  List<String> staged = const [],
}) => GitStatus(
  branch: const GitBranchInfo(head: 'main'),
  files: [
    for (final p in unstaged)
      GitFileStatus(path: p, statusX: '.', statusY: 'M'),
    for (final p in staged) GitFileStatus(path: p, statusX: 'M', statusY: '.'),
  ],
);

void main() {
  test('one repo, one selection — every surface reads the same value', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(repoFileSelectionProvider(_repo).notifier)
        .selectOnly('lib/main.dart');

    // Whichever surface asks, it is the same provider instance.
    expect(
      container.read(repoFileSelectionProvider(_repo)).paths,
      {'lib/main.dart'},
    );
  });

  test('selections do not leak between repositories', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(repoFileSelectionProvider(_repo).notifier).selectOnly('a');
    container.read(repoFileSelectionProvider('/other').notifier).selectOnly('b');

    expect(container.read(repoFileSelectionProvider(_repo)).paths, {'a'});
    expect(container.read(repoFileSelectionProvider('/other')).paths, {'b'});
  });

  test('selectOnly replaces rather than extends — trees are single-select', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(repoFileSelectionProvider(_repo).notifier);

    notifier.set(
      const RepoChangeSelection(
        section: RepoChangeSection.unstaged,
        paths: {'a', 'b'},
      ),
    );
    notifier.selectOnly('c');

    expect(container.read(repoFileSelectionProvider(_repo)).paths, {'c'});
    expect(
      container.read(repoFileSelectionProvider(_repo)).fromTree,
      isTrue,
      reason: 'origin is what lets reconcile spare a clean file',
    );
    expect(
      container.read(repoFileSelectionProvider(_repo)).section,
      RepoChangeSection.unstaged,
      reason: 'the tree picks the path; the host still owns the section',
    );
  });

  group('reconcile against a fresh status', () {
    test('drops a path that has left the working tree', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(repoFileSelectionProvider(_repo).notifier);

      notifier.set(
        const RepoChangeSelection(
          section: RepoChangeSection.unstaged,
          paths: {'gone.dart'},
        ),
      );
      notifier.reconcile(_status(unstaged: ['other.dart']));

      expect(container.read(repoFileSelectionProvider(_repo)).paths, isEmpty);
    });

    test('rehomes a path that merely moved section', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(repoFileSelectionProvider(_repo).notifier);

      notifier.set(
        const RepoChangeSelection(
          section: RepoChangeSection.unstaged,
          paths: {'a.dart'},
        ),
      );
      notifier.reconcile(_status(staged: ['a.dart']));

      final after = container.read(repoFileSelectionProvider(_repo));
      expect(after.paths, {'a.dart'});
      expect(after.section, RepoChangeSection.staged);
    });

    test('leaves a CLEAN file selected — the tree can select one, and it is '
        'not a stale Changes-list entry', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(repoFileSelectionProvider(_repo).notifier);

      // What the file tree produces when a clean file is clicked: a real
      // selection for a path that appears in NO status section.
      notifier.set(
        const RepoChangeSelection(section: RepoChangeSection.unstaged),
      );
      notifier.selectOnly('README.md');
      notifier.reconcile(_status(unstaged: ['other.dart']));

      // Clearing it would make the tree highlight flicker away on the next
      // `git status` tick — a regression the shared seam would otherwise
      // introduce, since the tree used to keep its own private highlight.
      expect(
        container.read(repoFileSelectionProvider(_repo)).paths,
        {'README.md'},
      );
    });
  });
}
