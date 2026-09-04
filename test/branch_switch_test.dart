// guardedBranchSwitch: the uncommitted-work guardrail before any branch
// switch. Regression coverage for the case where no status has been cached
// yet (right after connecting or switching repos) — it must fetch fresh and
// still guard a dirty tree, never silently treat "unknown" as "clean".

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/common/branch_switch.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'helpers/fake_snapshot.dart';

const _repo = '/repo';

GitStatus _clean() => GitStatus(branch: const GitBranchInfo(), files: const []);
GitStatus _dirty() => GitStatus(
  branch: const GitBranchInfo(),
  files: const [GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M')],
);
// An untracked-only tree — `isClean` is false (files isn't empty), so the guard
// fires, but a plain `git stash push` would find nothing to save.
GitStatus _untrackedOnly() => GitStatus(
  branch: const GitBranchInfo(),
  files: const [GitFileStatus(path: 'new.dart', statusX: '?', statusY: '?')],
);

class _FakeGit extends GitService with FakeSnapshot {
  _FakeGit(this._status) : super(SSHCommandExecutor(SSHClientManager()));
  final GitStatus Function() _status;
  int statusCalls = 0;
  int stashCalls = 0;
  bool? stashIncludedUntracked;

  @override
  Future<GitStatus> status(String repoPath) async {
    statusCalls++;
    return _status();
  }

  @override
  Future<SSHCommandResult> stashPush(
    String repoPath, {
    String? message,
    bool includeUntracked = false,
    List<String> paths = const [],
  }) async {
    stashCalls++;
    stashIncludedUntracked = includeUntracked;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

class _Result {
  bool? value;
  int checkoutCalls = 0;
}

class _Harness extends ConsumerWidget {
  final _Result result;
  const _Harness({required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPushButton(
      controlSize: ControlSize.large,
      onPressed: () async {
        final r = await guardedBranchSwitch(context, ref, _repo, () async {
          result.checkoutCalls++;
        });
        result.value = r;
      },
      child: const Text('Switch'),
    );
  }
}

Future<_Result> _pumpAndTap(WidgetTester tester, GitService git) async {
  final container = ProviderContainer(
    overrides: [gitServiceProvider.overrideWithValue(git)],
  );
  addTearDown(container.dispose);
  final result = _Result();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: _Harness(result: result),
      ),
    ),
  );
  await tester.tap(find.text('Switch'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets(
    'no cached status yet (a fresh session): fetches fresh and still guards '
    'a dirty tree — must not silently treat "unknown" as "clean"',
    (tester) async {
      final git = _FakeGit(_dirty);
      // statusProvider is never pre-warmed here, so guardedBranchSwitch's
      // first read of it is genuinely null — exactly the race this fixes.
      final result = await _pumpAndTap(tester, git);

      expect(
        git.statusCalls,
        1,
        reason: 'fetched fresh since nothing was cached yet',
      );
      expect(
        result.checkoutCalls,
        0,
        reason: 'must not switch before the user decides on the dirty tree',
      );
      expect(find.text('Uncommitted changes'), findsOneWidget);
    },
  );

  testWidgets(
    'no cached status yet: fetches fresh and switches directly once it '
    'turns out clean',
    (tester) async {
      final git = _FakeGit(_clean);
      final result = await _pumpAndTap(tester, git);
      expect(git.statusCalls, 1);
      expect(find.text('Uncommitted changes'), findsNothing);
      expect(result.checkoutCalls, 1);
      expect(result.value, isTrue);
    },
  );

  testWidgets(
    'Stash & Switch stashes with untracked included — otherwise an '
    'untracked-only tree stashes nothing and the changes are silently carried',
    (tester) async {
      final git = _FakeGit(_untrackedOnly);
      final result = await _pumpAndTap(tester, git);

      // The guard fired (untracked counts as dirty); pick "Stash & Switch".
      expect(find.text('Uncommitted changes'), findsOneWidget);
      await tester.tap(find.text('Stash & Switch'));
      await tester.pumpAndSettle();

      expect(git.stashCalls, 1);
      expect(
        git.stashIncludedUntracked,
        isTrue,
        reason: 'must include untracked or the stash is an empty no-op',
      );
      expect(result.checkoutCalls, 1, reason: 'switch proceeds after stashing');
      expect(result.value, isTrue);
    },
  );
}
