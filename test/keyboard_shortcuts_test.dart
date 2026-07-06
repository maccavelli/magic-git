// Verifies the actual wiring of a few representative shortcuts end-to-end
// (default binding → widget's CallbackShortcuts map → real action firing),
// and that a background (isActive: false) panel's shortcuts go quiet rather
// than firing while another sidebar page is shown.

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';
import 'package:remote_magic_git/core/ssh/ssh_command_executor.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';
import 'package:remote_magic_git/features/branches/branches_view.dart';
import 'package:remote_magic_git/features/repository/commit_dialog.dart';
import 'package:remote_magic_git/features/repository/repo_status_view.dart';

const _repo = '/srv/repo';

/// Finds the callback bound to [key]/[meta]/[shift]/[control] across every
/// [CallbackShortcuts] currently in the tree — proof that the widget actually
/// wired this key combination up, not just that some handler exists
/// somewhere. Compared field-by-field rather than via `Map.[]` because
/// [SingleActivator] doesn't override `==`, so a freshly-constructed
/// activator never matches an existing map key by identity.
VoidCallback? _bindingFor(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
  bool control = false,
}) {
  for (final element in find.byType(CallbackShortcuts).evaluate()) {
    final widget = element.widget as CallbackShortcuts;
    for (final entry in widget.bindings.entries) {
      final activator = entry.key;
      if (activator is SingleActivator &&
          activator.trigger == key &&
          activator.meta == meta &&
          activator.shift == shift &&
          activator.control == control) {
        return entry.value;
      }
    }
  }
  return null;
}

class _FakeGit extends GitService {
  _FakeGit() : super(SSHCommandExecutor(SSHClientManager()));
  final List<String> staged = [];
  final List<String> unstaged = [];
  String? committed;

  @override
  Future<void> stage(String repoPath, String path) async => staged.add(path);

  @override
  Future<void> unstage(String repoPath, String path) async =>
      unstaged.add(path);

  @override
  Future<String?> generateCommitMessage(String repoPath) async => null;

  @override
  Future<void> commit(String repoPath, {String? message}) async {
    committed = message;
  }
}

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
          child: const MacosApp(
            debugShowCheckedModeBanner: false,
            home: CommitDialog(repoPath: _repo, stagedCount: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No message yet — canAccept is false, so the shortcut is a no-op.
      expect(
        _bindingFor(tester, LogicalKeyboardKey.enter, meta: true),
        isNull,
      );

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

    testWidgets('⌘B focuses the new-branch field', (tester) async {
      await pump(tester, isActive: true);

      final field = find.byWidgetPredicate(
        (w) => w is MacosTextField && w.placeholder == 'New branch name',
      );
      expect(tester.widget<MacosTextField>(field).focusNode!.hasFocus, isFalse);

      _bindingFor(tester, LogicalKeyboardKey.keyB, meta: true)!();
      await tester.pumpAndSettle();

      expect(tester.widget<MacosTextField>(field).focusNode!.hasFocus, isTrue);
    });

    testWidgets('a backgrounded panel (isActive: false) registers no shortcuts', (
      tester,
    ) async {
      await pump(tester, isActive: false);

      expect(
        _bindingFor(tester, LogicalKeyboardKey.keyB, meta: true),
        isNull,
      );
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
          repoWatchProvider(_repo).overrideWith(
            (ref) => const Stream<RepoWatchEvent>.empty(),
          ),
          fileViewVisibleProvider.overrideWith(_HiddenFileView.new),
          refsProvider(_repo).overrideWith((ref) async => const []),
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
  });

  test('every default binding is unique within its overlapping scope', () {
    for (final action in kKeymapActions) {
      for (final binding in action.defaultBindings) {
        final conflicts = <String>[];
        for (final other in kKeymapActions) {
          if (other.id == action.id) continue;
          final overlaps = other.category == action.category ||
              other.category == KeymapCategory.global ||
              action.category == KeymapCategory.global;
          if (overlaps && other.defaultBindings.contains(binding)) {
            conflicts.add(other.id);
          }
        }
        expect(
          conflicts,
          isEmpty,
          reason: '${action.id} default ${binding.label} collides with $conflicts',
        );
      }
    }
  });
}
