import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local/scoped_access.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_local_repo.dart';
import '../common/actions.dart';

/// Holds the macOS security-scoped grants for worktrees opened inside the
/// Worktrees panel, and releases them when their tabs close.
///
/// Why this is needed at all: the app is sandboxed and may read only folders the
/// user picked. The main repository's grant covers `<main>/…` — and a linked
/// worktree lives *outside* it (conventionally a sibling, `../repo-feature`). So
/// listing worktrees works with the main grant alone (`git worktree list` reads
/// `<main>/.git/worktrees/`), but actually *working in* one needs a grant on its
/// own folder, or every `git status` there fails with a raw permission error.
///
/// A worktree this app created got its grant from the destination folder picker.
/// One created in a terminal has never been granted, so the first open prompts
/// for it — once — and the bookmark is persisted so it never prompts again.
///
/// On the SSH backend there is no sandbox and none of this applies: [ensure]
/// short-circuits to success.
class WorktreeAccess {
  WorktreeAccess(this._ref);

  final Ref _ref;

  /// Worktree paths this panel currently holds a grant for.
  final Set<String> _held = {};

  /// Ensures a grant on [worktreePath] is held, prompting for the folder if we
  /// have never been given one. Returns false if the user cancels or access
  /// can't be established — the caller must not open the worktree then.
  Future<bool> ensure(BuildContext context, String worktreePath) async {
    // Remote host: no sandbox, nothing to grant.
    if (!_ref.read(connectionProvider).isLocal) return true;
    if (_held.contains(worktreePath)) return true;

    // Already saved (this app created it, or it was opened before) — resolve the
    // bookmark silently.
    for (final saved in await _ref.read(localRepoStoreProvider).list()) {
      if (saved.repoPath != worktreePath || saved.bookmarkData.isEmpty) continue;
      final resolved = await ScopedAccess.instance.acquire(saved.bookmarkData);
      if (resolved != null) {
        _held.add(worktreePath);
        return true;
      }
      break; // Bookmark went stale — fall through and re-ask.
    }

    if (!context.mounted) return false;
    final proceed = await confirmAction(
      context,
      title: 'Grant access to this worktree',
      message:
          'This worktree lives outside the main repository folder:\n\n'
          '$worktreePath\n\n'
          'macOS requires you to select it before this app can read it. You '
          'will only be asked once.',
      confirmLabel: 'Choose Folder…',
    );
    if (!proceed || !context.mounted) return false;

    final picked = await getDirectoryPath(initialDirectory: worktreePath);
    if (picked == null || !context.mounted) return false;
    if (picked != worktreePath) {
      await showErrorDialog(
        context,
        'That is a different folder. Please choose:\n\n$worktreePath',
      );
      return false;
    }

    // Persist the grant so reopening never prompts again. The entry also records
    // the main repo, which a linked worktree needs granted alongside it — see
    // [SavedLocalRepo.mainRepoPath].
    final bookmark = await SecurityScopedBookmark.create(picked);
    if (bookmark != null) {
      await _saveGrant(worktreePath, bookmark);
    }
    _held.add(worktreePath);
    return true;
  }

  /// Records a freshly-granted worktree so a later open resolves it silently.
  /// Called by the Add-Worktree flow too, whose destination picker mints the
  /// grant as a side effect of choosing where the worktree goes.
  Future<void> remember(String worktreePath, String bookmark) async {
    _held.add(worktreePath);
    await _saveGrant(worktreePath, bookmark);
  }

  Future<void> _saveGrant(String worktreePath, String bookmark) async {
    final store = _ref.read(localRepoStoreProvider);
    final mainRepoPath = _ref.read(connectionProvider).repoPath ?? '';
    // The main repo's own bookmark, so opening this worktree as a top-level repo
    // later can re-acquire BOTH grants without prompting for either.
    var mainBookmark = '';
    for (final saved in await store.list()) {
      if (saved.repoPath == mainRepoPath) {
        mainBookmark = saved.bookmarkData;
        break;
      }
    }
    await store.save(
      SavedLocalRepo(
        id: 'wt-${worktreePath.hashCode}',
        label: '',
        repoPath: worktreePath,
        bookmarkData: bookmark,
        mainRepoPath: mainRepoPath,
        mainRepoBookmarkData: mainBookmark,
      ),
    );
    _ref.invalidate(savedLocalReposProvider);
  }

  /// Drops the grant for one worktree (its tab closed).
  Future<void> release(String worktreePath) async {
    if (!_held.remove(worktreePath)) return;
    await ScopedAccess.instance.release(worktreePath);
  }

  /// Drops every grant this panel holds — the repo changed, or we're going away.
  /// Without this the native grants leak for the app's lifetime.
  Future<void> releaseAll() async {
    final held = List<String>.from(_held);
    _held.clear();
    for (final path in held) {
      await ScopedAccess.instance.release(path);
    }
  }
}

/// One [WorktreeAccess] per tab container, so grants are scoped to the session
/// that took them.
final worktreeAccessProvider = Provider<WorktreeAccess>((ref) {
  final access = WorktreeAccess(ref);
  ref.onDispose(access.releaseAll);
  return access;
});
