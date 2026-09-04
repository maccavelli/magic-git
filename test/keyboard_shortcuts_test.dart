// Verifies the actual wiring of a few representative shortcuts end-to-end
// (default binding → widget's CallbackShortcuts map → real action firing),
// and that a background (isActive: false) panel's shortcuts go quiet rather
// than firing while another sidebar page is shown.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/common/panel_shortcuts.dart';
import 'package:remote_magic_git/features/history/history_view.dart';
import 'package:remote_magic_git/features/repository/commit_composer_controller.dart';
import 'package:remote_magic_git/features/repository/commit_dialog.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';
import 'package:remote_magic_git/features/stash/stash_view.dart';
import 'helpers/fake_snapshot.dart';

const _repo = '/srv/repo';

/// Finds the callback bound to [key]/[meta]/[shift]/[control] across every
/// [CallbackShortcuts] and [PanelShortcuts] currently in the tree — proof
/// that the widget actually wired this key combination up, not just that some
/// handler exists somewhere. Compared field-by-field rather than via `Map.[]`
/// because [SingleActivator] doesn't override `==`, so a freshly-constructed
/// activator never matches an existing map key by identity.
VoidCallback? _bindingFor(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
  bool control = false,
  bool alt = false,
}) {
  final maps = [
    for (final element in find.byType(CallbackShortcuts).evaluate())
      (element.widget as CallbackShortcuts).bindings,
    for (final element in find.byType(PanelShortcuts).evaluate())
      (element.widget as PanelShortcuts).bindings,
  ];
  for (final bindings in maps) {
    for (final entry in bindings.entries) {
      final activator = entry.key;
      if (activator is SingleActivator &&
          activator.trigger == key &&
          activator.meta == meta &&
          activator.shift == shift &&
          activator.control == control &&
          activator.alt == alt) {
        return entry.value;
      }
    }
  }
  return null;
}

class _FakeGit extends GitService with FakeRefsSnapshot {
  _FakeGit({this.commits = const []})
    : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> staged = [];
  final List<String> unstaged = [];
  final List<GitCommit> commits;
  String? committed;
  bool stageAllCalled = false;

  @override
  Future<void> stage(String repoPath, String path) async => staged.add(path);

  @override
  Future<void> unstage(String repoPath, String path) async =>
      unstaged.add(path);

  @override
  Future<void> stageAll(String repoPath) async => stageAllCalled = true;

  String? merged;
  final List<String> deletedBranches = [];

  @override
  Future<SSHCommandResult> merge(
    String repoPath,
    String branch, {
    MergeMode mode = MergeMode.normal,
  }) async {
    merged = branch;
    return const SSHCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> deleteBranch(
    String repoPath,
    String name, {
    bool force = false,
  }) async => deletedBranches.add(name);

  @override
  Future<String?> generateCommitMessage(String repoPath) async => null;

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    committed = message;
  }

  // ---- History-panel support ------------------------------------------
  @override
  Future<List<GitCommit>> log(
    String repoPath, {
    String revision = 'HEAD',
    int maxCount = 200,
    int skip = 0,
    String? grep,
    String? author,
    String? since,
    String? until,
    String? path,
    String? pathQuery,
    String? sha,
    bool all = false,
    bool follow = false,
    bool noMerges = false,
    bool fullHistory = false,
  }) async => commits;

  @override
  Future<List<GitRef>> refs(String repoPath) async => const [];

  @override
  Future<String> showCommit(
    String repoPath,
    String hash, {
    String? path,
    int? context,
  }) async => 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b';

  // The repository panel prefetches diffs for the changed files whenever
  // status lands — serve them here rather than letting the prefetch fall
  // through to the real (unconfigured) executor.
  @override
  Future<String> diffFile(
    String repoPath, {
    required String path,
    required bool staged,
    bool ignoreWhitespace = false,
    int? context,
  }) async => 'diff --git a/$path b/$path\n';

  @override
  Future<String> diffUntracked(String repoPath, String path) async =>
      'diff --git a/dev/null b/$path\n';
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-04T10:00',
  parents: const [],
  subject: subject,
);

class _HiddenFileView extends FileViewVisibility {
  @override
  bool build() => false;
}

void main() {
  group('commit dialog', () {
    testWidgets('⌘↩ confirms the commit once a message is typed', (
      tester,
    ) async {
      final git = _FakeGit();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [gitServiceProvider.overrideWithValue(git)],
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: CommitDialog(
              repoPath: _repo,
              stagedCount: 1,
              branchLabel: 'master',
              onPush: () async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The sheet no longer declares the staged set — RepoStatusView owns it
      // and pushes it post-frame. Stand in for that here, or nothing is
      // staged and Accept can never arm.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CommitDialog)),
      );
      container
          .read(
            commitComposerControllerProvider(
              CommitComposerKey(
                _repo,
                container.read(connectionProvider).sessionEpoch,
              ),
            ),
          )
          .updateStaged(count: 1, signature: 'seed:1');
      await tester.pumpAndSettle();

      // No message yet — canAccept is false, so the shortcut is a no-op.
      expect(_bindingFor(tester, LogicalKeyboardKey.enter, meta: true), isNull);

      await tester.enterText(find.byType(MacosTextField), 'fix: a bug');
      await tester.pumpAndSettle();

      final confirm = _bindingFor(tester, LogicalKeyboardKey.enter, meta: true);
      expect(confirm, isNotNull);
      confirm!();
      await tester.pumpAndSettle();

      expect(git.committed, 'fix: a bug');
    });
  });

  group('branches panel', () {
    Future<void> pump(WidgetTester tester, {required bool isActive}) async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGit()),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
          // The Branches tab watches the forge fusion + merged-branch signal;
          // unoverridden they hit the fake executor and leave a retry timer.
          branchForgeProvider(_repo).overrideWith((ref) async => const {}),
          mergedBranchesProvider(
            _repo,
          ).overrideWith((ref) async => const <String>{}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: BranchesView(repoPath: _repo, isActive: isActive),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('⌘B opens the new-branch prompt', (tester) async {
      await pump(tester, isActive: true);

      // No prompt until the shortcut fires.
      expect(find.text('New branch'), findsNothing);

      _bindingFor(tester, LogicalKeyboardKey.keyB, meta: true)!();
      await tester.pumpAndSettle();

      // The multi-field New branch form is up (name + start-at).
      expect(find.text('New branch'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MacosTextField &&
              (w.placeholder == 'feature/my-work' ||
                  w.placeholder == 'branch name'),
        ),
        findsWidgets,
      );
    });

    testWidgets(
      'a backgrounded panel (isActive: false) registers no shortcuts',
      (tester) async {
        await pump(tester, isActive: false);

        expect(
          _bindingFor(tester, LogicalKeyboardKey.keyB, meta: true),
          isNull,
        );
      },
    );

    testWidgets('selecting a branch enables ⌘⇧M merge / ⌘⌫ delete, which act '
        'on the selection', (tester) async {
      final git = _FakeGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          refsProvider(_repo).overrideWith(
            (ref) async => const [
              GitRef(
                name: 'refs/heads/main',
                oid: 'a',
                isHead: true,
                subject: 's',
              ),
              GitRef(
                name: 'refs/heads/feature',
                oid: 'b',
                isHead: false,
                subject: 's',
              ),
            ],
          ),
          // The view watches configured remotes (tag-push target) and the
          // remote-tag listing — unoverridden they'd error against the fake
          // executor and leave Riverpod retry timers pending.
          remotesProvider(_repo).overrideWith((ref) async => const ['origin']),
          remoteTagsProvider(_repo).overrideWith((ref) async => null),
          branchForgeProvider(_repo).overrideWith((ref) async => const {}),
          mergedBranchesProvider(
            _repo,
          ).overrideWith((ref) async => const <String>{}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: BranchesView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing selected yet → merge/delete fall through.
      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyM, meta: true, shift: true),
        isNull,
      );

      await tester.tap(find.text('feature'));
      await tester.pumpAndSettle();

      final merge = _bindingFor(
        tester,
        LogicalKeyboardKey.keyM,
        meta: true,
        shift: true,
      );
      expect(merge, isNotNull);
      expect(
        _bindingFor(tester, LogicalKeyboardKey.backspace, meta: true),
        isNotNull,
      );

      // ⌘⇧M → the confirm dialog → Merge runs against the selected branch.
      merge!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();
      expect(git.merged, 'feature');
    });
  });

  group('repository panel', () {
    Future<_FakeGit> pump(WidgetTester tester) async {
      final git = _FakeGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith(
            (ref) async => GitStatus(
              branch: const GitBranchInfo(),
              files: const [
                GitFileStatus(path: 'lib/a.dart', statusX: '.', statusY: 'M'),
              ],
            ),
          ),
          pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return git;
    }

    testWidgets(
      'Space toggles stage for the selected file, and is a no-op with '
      'nothing selected',
      (tester) async {
        final git = await pump(tester);

        // Nothing selected yet.
        expect(_bindingFor(tester, LogicalKeyboardKey.space), isNull);

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();

        final toggle = _bindingFor(tester, LogicalKeyboardKey.space);
        expect(toggle, isNotNull);
        toggle!();
        await tester.pumpAndSettle();

        expect(git.staged, ['lib/a.dart']);
      },
    );

    testWidgets('⌘⇧⌫ discards the selected unstaged file', (tester) async {
      await pump(tester);
      await tester.tap(find.text('lib/a.dart'));
      await tester.pumpAndSettle();

      final discard = _bindingFor(
        tester,
        LogicalKeyboardKey.backspace,
        meta: true,
        shift: true,
      );
      expect(discard, isNotNull);
    });

    testWidgets('⌘⇧A stages all when there are unstaged changes', (
      tester,
    ) async {
      final git = await pump(tester);
      final stageAll = _bindingFor(
        tester,
        LogicalKeyboardKey.keyA,
        meta: true,
        shift: true,
      );
      expect(stageAll, isNotNull);
      stageAll!();
      await tester.pumpAndSettle();
      expect(git.stageAllCalled, isTrue);
    });

    testWidgets('⌘⇧Y (sync) is wired on the active repository panel', (
      tester,
    ) async {
      await pump(tester);
      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyY, meta: true, shift: true),
        isNotNull,
      );
    });

    testWidgets('↑/↓ walk the file selection, and Space stages the row '
        'arrowed to', (tester) async {
      final git = _FakeGit();
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(git),
          statusProvider(_repo).overrideWith(
            (ref) async => GitStatus(
              branch: const GitBranchInfo(),
              files: const [
                GitFileStatus(path: 'a.dart', statusX: '.', statusY: 'M'),
                GitFileStatus(path: 'b.dart', statusX: '.', statusY: 'M'),
              ],
            ),
          ),
          pendingOpProvider(_repo).overrideWith((ref) async => PendingOp.none),
          repoWatchProvider(
            _repo,
          ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
          // Sibling of the refs override: the views now read CONFIGURED
          // remotes (remotesProvider), not remote-tracking refs.
          remotesProvider(_repo).overrideWith((ref) async => const <String>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: RepoStatusView(repoPath: _repo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Select the first file (also focuses the list), then arrow down to b.dart.
      await tester.tap(find.text('a.dart'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // Space now stages whichever row the arrow landed on.
      final space = _bindingFor(tester, LogicalKeyboardKey.space);
      expect(space, isNotNull);
      space!();
      await tester.pumpAndSettle();
      expect(git.staged, ['b.dart']);
    });

    testWidgets(
      'the ⌥⌘S side-by-side diff toggle only binds once a file is selected',
      (tester) async {
        await pump(tester);
        // No diff on screen yet → the toggle falls through (unbound).
        expect(
          _bindingFor(tester, LogicalKeyboardKey.keyS, meta: true, alt: true),
          isNull,
        );

        await tester.tap(find.text('lib/a.dart'));
        await tester.pumpAndSettle();

        expect(
          _bindingFor(tester, LogicalKeyboardKey.keyS, meta: true, alt: true),
          isNotNull,
        );
      },
    );
  });

  group('history panel', () {
    Future<void> pump(
      WidgetTester tester,
      List<GitCommit> commits, {
      bool isActive = true,
    }) async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGit(commits: commits)),
          repoWatchProvider.overrideWith(
            (ref, repoPath) => const Stream.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: HistoryView(repoPath: _repo, isActive: isActive),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('⌘C copies the SHA of the selected commit (and is unbound '
        'with no selection)', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final head = _commit('aaaaaaa1111111', 'head commit');
      await pump(tester, [head]);

      // Nothing selected → copy-SHA falls through.
      expect(_bindingFor(tester, LogicalKeyboardKey.keyC, meta: true), isNull);

      await tester.tap(find.text('head commit'));
      await tester.pumpAndSettle();

      final copy = _bindingFor(tester, LogicalKeyboardKey.keyC, meta: true);
      expect(copy, isNotNull);
      copy!();
      await tester.pumpAndSettle();
      expect(copied, head.hash);
    });

    testWidgets('⌘F (filter commits) is bound while the panel is active', (
      tester,
    ) async {
      await pump(tester, [_commit('aaaaaaa1111111', 'c')]);
      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyF, meta: true),
        isNotNull,
      );
    });

    testWidgets('↓ moves the commit selection (⌘C then copies the new row)', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final head = _commit('aaaaaaa1111111', 'head commit');
      final older = _commit('bbbbbbb2222222', 'old commit');
      await pump(tester, [head, older]);

      // Select the top row (focuses the list), arrow down to the older commit.
      await tester.tap(find.text('head commit'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      _bindingFor(tester, LogicalKeyboardKey.keyC, meta: true)!();
      await tester.pumpAndSettle();
      expect(copied, older.hash);
    });

    testWidgets('a backgrounded History panel registers no shortcuts', (
      tester,
    ) async {
      await pump(tester, [_commit('aaaaaaa1111111', 'c')], isActive: false);
      expect(_bindingFor(tester, LogicalKeyboardKey.keyF, meta: true), isNull);
    });
  });

  group('stashes panel', () {
    Future<void> pump(
      WidgetTester tester,
      List<GitStash> stashes, {
      bool isActive = true,
    }) async {
      final container = ProviderContainer(
        overrides: [
          gitServiceProvider.overrideWithValue(_FakeGit()),
          stashesProvider(_repo).overrideWith((ref) async => stashes),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MacosApp(
            debugShowCheckedModeBanner: false,
            home: SizedBox(
              width: 1000,
              height: 700,
              child: StashView(repoPath: _repo, isActive: isActive),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('⌥⌘A (apply) binds only once a stash is selected', (
      tester,
    ) async {
      await pump(tester, const [
        GitStash(
          index: 0,
          oid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          branch: 'main',
          message: 'WIP on main: tweak parser',
          relativeDate: '2 hours ago',
        ),
      ]);

      // Nothing selected → apply falls through.
      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyA, meta: true, alt: true),
        isNull,
      );

      await tester.tap(find.textContaining('tweak parser'));
      await tester.pumpAndSettle();

      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyA, meta: true, alt: true),
        isNotNull,
      );
    });
  });

  test('every default binding is unique within its overlapping scope', () {
    for (final action in kKeymapActions) {
      for (final binding in action.defaultBindings) {
        final conflicts = <String>[];
        for (final other in kKeymapActions) {
          if (other.id == action.id) continue;
          final overlaps =
              other.category == action.category ||
              other.category == KeymapCategory.global ||
              action.category == KeymapCategory.global;
          if (overlaps && other.defaultBindings.contains(binding)) {
            conflicts.add(other.id);
          }
        }
        expect(
          conflicts,
          isEmpty,
          reason:
              '${action.id} default ${binding.label} collides with $conflicts',
        );
      }
    }
  });
}
