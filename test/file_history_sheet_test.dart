// Regression coverage: selecting a commit in the file-history view must fetch
// (and show) the diff scoped to the one file being inspected, not every file
// that commit touched — the file-history sheet exists specifically to look at
// a single file's history, so showing (and re-fetching) an unrelated file's
// changes in the same commit was both wasteful and confusing.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/history/file_history_sheet.dart';

const _repo = '/repo';
const _path = 'lib/a.dart';

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<(String hash, String? path)> showCommitCalls = [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async {
    showCommitCalls.add((hash, path));
    return 'diff for $hash scoped to $path';
  }
}

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

void main() {
  testWidgets(
    'selecting a commit fetches the diff scoped to this file, not the whole '
    'commit',
    (tester) async {
      final git = _FakeGit();
      final commits = [_c('aaa1111', 'First change'), _c('bbb2222', 'Second change')];
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          fileLogProvider(
            (_repo, _path),
          ).overrideWith((ref) async => commits),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: FileHistorySheet(repoPath: _repo, path: _path),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The most recent commit's diff loads by default.
      expect(git.showCommitCalls, [('aaa1111', _path)]);

      await tester.tap(find.text('Second change'));
      await tester.pumpAndSettle();

      expect(git.showCommitCalls, [('aaa1111', _path), ('bbb2222', _path)]);
    },
  );
}
