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
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';
import 'package:remote_magic_git/features/repository/commit_dialog.dart';

class _FakeGit extends GitService {
  _FakeGit(this.generated) : super(SSHCommandExecutor(SSHClientManager()));
  final String? generated;
  String? committed;
  int fetchCalls = 0;
  int pushCalls = 0;

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
    FetchScope scope = FetchScope.allRemotes,
    CommandOutputCallback? onOutput,
    OperationId? operationId,
    String? upstreamRemote,
  }) async {
    fetchCalls++;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// The sheet no longer declares the staged set — `RepoStatusView` owns it and
/// pushes it post-frame, so in production the signature is already real by the
/// time the sheet opens (the collapsed commit bar has been mounted the whole
/// time the tree was dirty). Standalone tests reproduce that ordering: seed the
/// controller first, then open.
void _seedStaged(WidgetTester tester, {int count = 2}) {
  final container = ProviderScope.containerOf(
    tester.element(find.text('open')),
  );
  final epoch = container.read(connectionProvider).sessionEpoch;
  container
      .read(
        commitComposerControllerProvider(CommitComposerKey('/srv/repo', epoch)),
      )
      .updateStaged(count: count, signature: 'seed:$count');
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
                builder: (_) => EscapeDismissible(
                  child: CommitDialog(
                    repoPath: '/srv/repo',
                    stagedCount: 2,
                    branchLabel: 'master',
                    onPush: () async {
                      git.pushCalls++;
                      return true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _seedStaged(tester);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Samples the own-mutation tracker from *inside* the commit, which is the
/// only place the difference between bracketing and stamping shows up.
class _TrackerProbeGit extends _FakeGit {
  _TrackerProbeGit(super.generated);
  bool Function()? probe;
  bool? suppressedDuringCommit;

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    suppressedDuringCommit = probe?.call();
    await super.commit(repoPath, message: message);
  }
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

  testWidgets('Accept + Push runs the push itself, in one submit', (
    tester,
  ) async {
    // The sheet used to commit and pop `true`, leaving the push to whoever
    // opened it. It now sequences both through one `submit()`, so a push
    // failure is reported against the commit that caused it.
    final git = _FakeGit('feat: add widget');
    final order = <String>[];
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
                    builder: (_) => CommitDialog(
                      repoPath: '/srv/repo',
                      stagedCount: 2,
                      branchLabel: 'master',
                      onPush: () async {
                        order.add('push');
                        return true;
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    _seedStaged(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept + Push'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget');
    expect(order, ['push'], reason: 'the push ran, and ran once');
    expect(result, isTrue, reason: 'the commit landed');
    // No background fetch on this path — the push advances the remote itself.
    expect(git.fetchCalls, 0);
  });

  // The sheet and the composer inside it each bind commit.* (0009 G-H8 added
  // the composer's copy while the sheet was unreachable). Now that both are on
  // screen together, one press must still mean one commit.
  group('the chords fire from the sheet, with the field focused', () {
    testWidgets('⌘↩ commits exactly once', (tester) async {
      final git = _FakeGit(null);
      await _openSheet(tester, git);
      await tester.enterText(find.byType(MacosTextField), 'fix: a bug');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(git.committed, 'fix: a bug');
      expect(git.pushCalls, 0);
    });

    testWidgets('⇧⌘↩ commits and pushes exactly once', (tester) async {
      final git = _FakeGit(null);
      await _openSheet(tester, git);
      await tester.enterText(find.byType(MacosTextField), 'fix: a bug');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(git.committed, 'fix: a bug');
      expect(git.pushCalls, 1);
    });
  });

  testWidgets('a failed commit reports in the sheet, keeping the message', (
    tester,
  ) async {
    // The failure used to arrive as a modal alert stacked on top of the sheet
    // — the message it was about was behind it.
    final git = _FailingCommitGit();
    await _openSheet(tester, git);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(find.byType(CommitDialog), findsOneWidget, reason: 'still open');
    expect(find.byType(MacosAlertDialog), findsNothing);
    expect(find.textContaining('Could not commit'), findsOneWidget);
    expect(
      find.text('feat: add widget'),
      findsOneWidget,
      reason: 'the draft it refers to is still there to fix',
    );
  });

  testWidgets('a failed push is not reported as a failed commit', (
    tester,
  ) async {
    // The commit landed and the draft is gone, so treating the push failure as
    // a commit failure left the sheet open on an empty field.
    final git = _FakeGit('feat: add widget');
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
                onPressed: () => showMacosSheet<bool>(
                  context: context,
                  builder: (_) => CommitDialog(
                    repoPath: '/srv/repo',
                    stagedCount: 2,
                    branchLabel: 'master',
                    onPush: () async => throw Exception('remote rejected'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _seedStaged(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept + Push'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget', reason: 'the commit landed');
    expect(
      find.byType(CommitDialog),
      findsNothing,
      reason: 'a landed commit closes the sheet; the push reports on its own',
    );
  });

  testWidgets('the header states the scope: how many files, and where', (
    tester,
  ) async {
    // `branchLabel` used to be the literal 'current branch'. A focused sheet
    // covers the workspace, so it has to carry the scope itself.
    final git = _FakeGit('feat: add widget');
    await _openSheet(tester, git);

    expect(find.text('Commit 2 files'), findsOneWidget);
    expect(find.text('on master'), findsOneWidget);
    expect(find.textContaining('current branch'), findsNothing);
  });

  testWidgets('Accept does not push', (tester) async {
    final git = _FakeGit('feat: add widget');
    await _openSheet(tester, git);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(git.committed, 'feat: add widget');
    expect(git.pushCalls, 0);
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
                  builder: (_) => EscapeDismissible(
                    child: CommitDialog(
                      repoPath: '/srv/repo',
                      stagedCount: 2,
                      branchLabel: 'master',
                      onPush: () async => true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _seedStaged(tester);
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

  testWidgets('the sheet closes when the COMMIT lands, not when the push does', (
    tester,
  ) async {
    // 0023 P1. Holding this modal across the push is what made a working app
    // read as frozen: every control disabled, Escape swallowed, no indicator,
    // for the whole network wait — while `git push --progress` was already
    // streaming its transcript to the output log underneath.
    final git = _FakeGit('feat: add widget');
    final pushGate = Completer<bool>();
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
                onPressed: () => showMacosSheet<bool>(
                  context: context,
                  builder: (_) => CommitDialog(
                    repoPath: '/srv/repo',
                    stagedCount: 2,
                    branchLabel: 'master',
                    onPush: () => pushGate.future,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _seedStaged(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept + Push'));
    // Frames, not pumpAndSettle: the committing spinner animates forever while
    // the push is outstanding, so settling would time out. These let the pop's
    // route transition finish.
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The commit has landed; the push is still outstanding.
    expect(git.committed, 'feat: add widget');
    expect(pushGate.isCompleted, isFalse);
    expect(
      find.byType(CommitDialog),
      findsNothing,
      reason: 'the sheet must not outlive the commit it was opened for',
    );

    pushGate.complete(true);
    await tester.pumpAndSettle();
  });

  // 0025 F3a. repo_status_view.dart brackets its mutations with
  // withOwnMutation (4 call sites); this sheet had none and relied on
  // refreshAfterMutation, which only mark()s AFTER the command returns. A
  // point-in-time stamp cannot suppress an echo that already arrived — and
  // `git add -A`, the commit's index/ref writes and the push all generate
  // watcher events *while the gesture is still running*. Each surviving event
  // buys a full refresh wave (0025 Finding B).
  testWidgets('the commit sheet suppresses the echo of its own commit', (
    tester,
  ) async {
    final git = _TrackerProbeGit('feat: x');
    await _openSheet(tester, git);
    final container = ProviderScope.containerOf(
      tester.element(find.text('open')),
    );
    final tracker = container.read(ownMutationTrackerProvider);
    git.probe = () => tracker.isRecent(
      '/srv/repo',
      DateTime.now(),
      const Duration(seconds: 3),
    );

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(git.committed, isNotNull, reason: 'sanity: it committed');
    expect(
      git.suppressedDuringCommit,
      isTrue,
      reason: 'the mutation must be bracketed, not stamped after it returns',
    );
  });
}

/// A commit that always fails, to exercise in-sheet error reporting.
class _FailingCommitGit extends _FakeGit {
  _FailingCommitGit() : super('feat: add widget');

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    throw Exception('nothing to commit, working tree clean');
  }
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
