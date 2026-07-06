// Covers the hook-aware commit sheet: a generated message opens review mode
// (Edit + Accept, no redundant "Commit"); accepting commits that exact message.
// With no hook it falls back to a manual field whose confirm button is Accept.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/repository/commit_dialog.dart';

class _FakeGit extends GitService {
  _FakeGit(this.generated) : super(SSHCommandExecutor(SSHClientManager()));
  final String? generated;
  String? committed;
  int fetchCalls = 0;

  @override
  Future<String?> generateCommitMessage(String repoPath) async => generated;

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    committed = message;
  }

  @override
  Future<SSHCommandResult> fetch(String repoPath) async {
    fetchCalls++;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<void> _openSheet(WidgetTester tester, _FakeGit git) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [gitServiceProvider.overrideWithValue(git)],
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) => Center(
            child: PushButton(
              controlSize: ControlSize.large,
              child: const Text('open'),
              onPressed: () => showMacosSheet<void>(
                context: context,
                builder: (_) =>
                    const CommitDialog(repoPath: '/srv/repo', stagedCount: 2),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('generated message → review mode → Accept commits it', (
    tester,
  ) async {
    final git = _FakeGit('feat: add widget');
    await _openSheet(tester, git);

    // Review mode: the generated message is shown with Edit + Accept, and there
    // is no redundant "Commit" button.
    expect(find.text('feat: add widget'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Commit'), findsNothing);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget');
    expect(find.byType(CommitDialog), findsNothing); // sheet dismissed
  });

  testWidgets('no hook → manual entry, Accept commits typed message', (
    tester,
  ) async {
    final git = _FakeGit(null);
    await _openSheet(tester, git);

    // Manual mode: Accept present (not Commit), Edit absent (nothing generated).
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);

    await tester.enterText(find.byType(MacosTextField), 'chore: tidy up');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(git.committed, 'chore: tidy up');
  });

  testWidgets('a successful commit fires a best-effort background fetch', (
    tester,
  ) async {
    final git = _FakeGit('feat: add widget');
    await _openSheet(tester, git);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget');
    expect(git.fetchCalls, 1);
  });
}
