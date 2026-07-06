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

const _repo = '/repo';

GitStatus _clean() => GitStatus(branch: const GitBranchInfo(), files: const []);
GitStatus _dirty() => GitStatus(
  branch: const GitBranchInfo(),
  files: const [GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M')],
);

class _FakeGit extends GitService {
  _FakeGit(this._status) : super(SSHCommandExecutor(SSHClientManager()));
  final GitStatus Function() _status;
  int statusCalls = 0;

  @override
  Future<GitStatus> status(String repoPath) async {
    statusCalls++;
    return _status();
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
    return PushButton(
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
}
