import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import 'actions.dart';

/// THE mutating-action runner for panel views — the busy gate, the
/// error-surfacing, and the always-refresh contract, in one place.
///
/// Five views (Repository, History, Branches, Stashes, Worktrees) each grew
/// their own `_busy` flag plus `_run`/`_runLogged` copies of this, and the
/// copies drifted: the worktrees copy called its refresh *outside* the
/// mounted guard (a post-dispose `ref` touch), and the history copy
/// refreshed only on success — leaving a conflicting op's in-progress state
/// invisible until some unrelated refresh, the very bug the other copies
/// documented fixing.
///
/// The contract, spelled out once:
///
///  * **Busy gate.** A second activation while one mutation is in flight is a
///    no-op — overlapping mutations race on `.git/index.lock` (and, for
///    worktrees, on the shared admin directory). Views disable buttons and
///    shortcut handlers off [busy].
///  * **Refresh even on failure.** GitService signals a merge/rebase/
///    cherry-pick/revert conflict by *throwing* — a failed op can still have
///    rewritten the working tree, and pendingOpProvider must observe the
///    in-progress state now, not on some later unrelated refresh.
///  * **Nothing after disposal.** The refresh and the busy reset both touch
///    `ref`/`setState`, so the whole finally block is mounted-guarded — a
///    view can be torn down while a slow operation is in flight.
mixin BusyActionState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _busy = false;

  /// Whether a mutation is in flight — drives disabled buttons and the
  /// keyboard-shortcut gate.
  bool get busy => _busy;

  /// The view's post-mutation refresh, run in `finally` while still mounted.
  /// Usually [refreshAfterMutation] plus any view-local invalidations.
  void refreshAfterAction();

  /// Runs [op] behind the busy gate, surfacing failure via [runAction]'s
  /// error dialog. Returns whether it ran and succeeded; [onSuccess] fires
  /// before the refresh, for view-local state that must only change on
  /// success (e.g. clearing a selection that an op invalidated).
  Future<bool> runGuarded(
    Future<void> Function() op, {
    void Function()? onSuccess,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final ok = await runAction(context, op);
      if (ok && mounted) onSuccess?.call();
      return ok;
    } finally {
      if (mounted) {
        refreshAfterAction();
        setState(() => _busy = false);
      }
    }
  }

  /// Holds the busy gate around [body] WITHOUT the error-dialog/refresh
  /// contract — for modal flows (e.g. History's rebase sheet) where a sheet
  /// owns the interaction and its own refreshing, but the panel underneath
  /// must stay inert (shortcuts and buttons disabled) until it closes.
  Future<R> holdBusyWhile<R>(Future<R> Function() body) async {
    setState(() => _busy = true);
    try {
      return await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Like [runGuarded], but hands [body] the output log — for operations
  /// (merge, cherry-pick, pull) where the actual git output matters. A
  /// [GitException]'s result is logged before the error dialog; other errors
  /// log their message.
  ///
  /// [describeError] lets a view translate a domain error into friendlier
  /// dialog copy (e.g. the stash panel's [StashStaleException]); returning
  /// null falls through to the standard handling.
  Future<bool> runLogged(
    String title,
    Future<void> Function(OutputLogNotifier log) body, {
    String? Function(Object error)? describeError,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    final log = ref.read(outputLogProvider.notifier);
    var success = false;
    try {
      await body(log);
      success = true;
    } catch (e) {
      final custom = describeError?.call(e);
      if (custom != null) {
        if (mounted) await showErrorDialog(context, custom);
      } else if (e is GitException) {
        log.logResult(title, e.result);
        if (mounted) await showErrorDialog(context, e.toString());
      } else {
        log.logError(title, e.toString());
        if (mounted) await showErrorDialog(context, e.toString());
      }
    } finally {
      if (mounted) {
        refreshAfterAction();
        setState(() => _busy = false);
      }
    }
    return success;
  }
}
