// Covers the hook-aware commit sheet: a generated message opens review mode
// (Edit + Accept, no redundant "Commit"); accepting commits that exact message.
// With no hook it falls back to a manual field whose confirm button is Accept.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/features/common/buttons.dart';
import 'package:remote_magic_git/features/common/escape_dismissible.dart';
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
  Future<SSHCommandResult> fetch(
    String repoPath, {
    bool background = false,
  }) async {
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
            child: AppPushButton(
              controlSize: ControlSize.large,
              child: const Text('open'),
              // Mirrors the real call site: the EscapeDismissible wrapper owns
              // Escape (registry-based), gated by the dialog's mid-commit
              // interceptor.
              onPressed: () => showMacosSheet<void>(
                context: context,
                builder: (_) => const EscapeDismissible(
                  child: CommitDialog(repoPath: '/srv/repo', stagedCount: 2),
                ),
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

/// A commit that hangs until the test releases it, counting entries — used to
/// prove a second activation while one is in flight can't start a second
/// commit.
class _GatedGit extends _FakeGit {
  _GatedGit(super.generated);
  final gate = Completer<void>();
  int commitCalls = 0;

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    commitCalls++;
    await gate.future;
    await super.commit(repoPath, message: message);
  }
}

void main() {
  testWidgets('two rapid ⌘↩ presses commit once, not twice', (tester) async {
    final git = _GatedGit('feat: add widget');
    await _openSheet(tester, git);

    // Both presses land in the same frame — before any rebuild disables the
    // shortcut binding — so only the method's own entry guard can stop the
    // second one.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    git.gate.complete();
    await tester.pumpAndSettle();

    expect(git.commitCalls, 1);
    expect(find.byType(CommitDialog), findsNothing); // sheet dismissed
  });

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

  testWidgets('Accept + Push commits and pops true so the caller pushes', (
    tester,
  ) async {
    final git = _FakeGit('feat: add widget');
    bool? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gitServiceProvider.overrideWithValue(git)],
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => Center(
              child: AppPushButton(
                controlSize: ControlSize.large,
                child: const Text('open'),
                onPressed: () async {
                  result = await showMacosSheet<bool>(
                    context: context,
                    builder: (_) => const CommitDialog(
                      repoPath: '/srv/repo',
                      stagedCount: 2,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept + Push'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget');
    // Pops `true` → the panel runs the push. And no background fetch here (the
    // push advances/refreshes the remote itself).
    expect(result, isTrue);
    expect(git.fetchCalls, 0);
  });

  testWidgets('Escape closes the sheet while the hook preview is still '
      'loading', (tester) async {
    // A slow (e.g. AI) prepare-commit-msg hook: the message field doesn't
    // exist yet, so nothing inside the sheet holds focus — dismissal must not
    // depend on it. Bounded pumps throughout: the loading spinner animates
    // forever, so pumpAndSettle would never settle.
    final git = _HangingPreviewGit();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gitServiceProvider.overrideWithValue(git)],
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => Center(
              child: AppPushButton(
                controlSize: ControlSize.large,
                child: const Text('open'),
                onPressed: () => showMacosSheet<void>(
                  context: context,
                  builder: (_) => const EscapeDismissible(
                    child: CommitDialog(repoPath: '/srv/repo', stagedCount: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition
    expect(find.byType(CommitDialog), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // pop transition
    expect(
      find.byType(CommitDialog),
      findsNothing,
      reason: 'Escape must work first try in a just-opened sheet',
    );
    git.release(); // let the orphaned preview future finish cleanly
    await tester.pumpAndSettle();
  });

  testWidgets('Escape works in review mode even with nothing focused', (
    tester,
  ) async {
    final git = _FakeGit('feat: add widget');
    await _openSheet(tester, git);
    // Review mode: the field is read-only; simulate focus having gone
    // nowhere (the pre-fix dead state).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommitDialog), findsNothing);
    expect(git.committed, isNull);
  });

  testWidgets('Escape is blocked while a commit is in flight', (tester) async {
    final git = _GatedGit('feat: add widget');
    await _openSheet(tester, git);

    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(git.commitCalls, 1);

    // Mid-commit: the sheet must not be yanked out from under the operation.
    // Bounded pumps — the committing state may animate.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CommitDialog), findsOneWidget);

    git.gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CommitDialog), findsNothing, reason: 'commit finished');
    expect(git.committed, 'feat: add widget');
  });
}

/// A hook preview that never resolves until [release] — models a slow AI
/// message generator holding the sheet in its loading state.
class _HangingPreviewGit extends _FakeGit {
  _HangingPreviewGit() : super(null);
  final _gate = Completer<String?>();

  void release() {
    if (!_gate.isCompleted) _gate.complete(null);
  }

  @override
  Future<String?> generateCommitMessage(String repoPath) => _gate.future;
}
