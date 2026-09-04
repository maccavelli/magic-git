import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/escape_dismissible.dart';
import '../common/sized_sheet.dart';
import 'commit_composer.dart';
import 'commit_composer_controller.dart';

/// Focused editor around the same repository-scoped composer used by the
/// Repository task dock. Closing this wrapper never discards its draft.
class CommitDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final int stagedCount;

  /// Runs the push for **Accept + Push**, returning whether it succeeded.
  ///
  /// Supplied by the caller rather than implemented here: push carries policy
  /// this sheet has no business duplicating — the behind-upstream guardrail,
  /// force/set-upstream variants, follow-tags, and output-dock logging all
  /// live in `RepoStatusView._push`. The sheet's job is to sequence commit and
  /// push through one `submit()` so a push failure is reported against the
  /// commit that caused it.
  final Future<bool> Function() onPush;

  /// The branch this commit lands on. Was the literal string
  /// `'current branch'` — a placeholder that shipped, and the one piece of
  /// scope a focused sheet cannot leave to the workspace behind it.
  final String branchLabel;

  const CommitDialog({
    super.key,
    required this.repoPath,
    required this.stagedCount,
    required this.onPush,
    required this.branchLabel,
  });

  @override
  ConsumerState<CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends ConsumerState<CommitDialog> {
  VoidCallback? _escInterceptorDisposer;

  CommitComposerController get _controller {
    final epoch = ref.read(connectionProvider).sessionEpoch;
    return ref.read(
      commitComposerControllerProvider(
        CommitComposerKey(widget.repoPath, epoch),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Swallow Escape only while the COMMIT is in flight — a moment, and one
    // that must not be interrupted halfway. It used to stay swallowed for the
    // push too, so the one key that should dismiss a stuck-looking sheet did
    // nothing for the entire wait (0023 P1).
    _escInterceptorDisposer ??= EscapeInterceptor.of(
      context,
      () => _controller.committing && !_controller.localCommitLanded,
    );
  }

  @override
  void dispose() {
    _escInterceptorDisposer?.call();
    super.dispose();
  }

  Future<void> _accept(bool push) async {
    final controller = _controller;
    // Closed as soon as the COMMIT lands, not when the push finishes. The
    // push keeps running behind the workspace and reports through the output
    // log (which `_push` streams `--progress` into live) and the Activity
    // Center. Holding this modal across the push is what made a network wait
    // read as a frozen app: every control disabled, Escape swallowed, and no
    // indicator (0023 P1).
    var closed = false;
    void closeOnCommit() {
      if (closed || !mounted) return;
      closed = true;
      // The refresh for the COMMIT. Not redundant with `_push`'s: that one is
      // the narrow fetch-family set for the push, and this surface commits
      // through a raw `git.commit` with no runGuarded/runLogged refresh of its
      // own — so without this the sheet's commit would leave History, stashes,
      // reflog and snapshots stale (0023 Amendment A1).
      refreshAfterMutation(ref, widget.repoPath);
      if (context.mounted) Navigator.of(context).pop(true);
    }

    final outcome = await controller.submit(
      // Deliberately NOT wrapped in `runAction`: that reports by stacking a
      // modal alert on top of this sheet, which puts the failure somewhere the
      // message it refers to is no longer visible. Letting the throw reach
      // `submit` records it on the controller, and the composer renders it in
      // the sheet's own status line beside the draft that is still there.
      commit: (message) async {
        await ref
            .read(gitServiceProvider)
            .commit(widget.repoPath, message: message);
        return true;
      },
      push: push ? widget.onPush : null,
      onLocalCommitted: closeOnCommit,
    );
    // A commit that did not land leaves the sheet open with the message
    // intact; `submit` has already recorded the reason on the controller.
    if (!outcome.localCommitted) return;
    // Belt and braces: if the seam somehow did not fire (a future refactor of
    // `submit`), the sheet must still close and refresh rather than stay up.
    closeOnCommit();
    if (!push && mounted) {
      unawaited(
        ref
            .read(connectionProvider.notifier)
            .fetchInBackground(widget.repoPath),
      );
    }
  }

  /// Sizing follows the app's other content sheets (Blame, Rebase): a fraction
  /// of the window, clamped at both ends.
  ///
  /// Not literally intrinsic, despite what a "wraps its content" sheet would
  /// suggest: the composer's message field is an `Expanded` with
  /// `expands: true`, so the column it lives in requires a bounded height.
  /// Making it size to its text would mean reworking the shared composer body,
  /// which belongs to the dock too. The fixed 760×390 this replaces was the
  /// real complaint — it left a one-line subject adrift in a half-empty card on
  /// a large display and scrolled a long generated body inside a short box on
  /// any display.
  static double _width(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.58).clamp(560, 820);

  static double _height(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.62).clamp(420, 760);

  @override
  Widget build(BuildContext context) {
    final epoch = ref.watch(
      connectionProvider.select((connection) => connection.sessionEpoch),
    );
    final controller = ref.watch(
      commitComposerControllerProvider(
        CommitComposerKey(widget.repoPath, epoch),
      ),
    );
    // The staged count/signature is NOT set here. `RepoStatusView` owns it: it
    // pushes the real content signature from a post-frame callback, which is
    // what preview-staleness compares against. Doing it again from this build
    // both overwrote that signature with a synthetic `focused:N` — two
    // different staged sets of the same size hash alike — and notified
    // listeners mid-build, marking the still-mounted docked composer dirty
    // while the framework was already building.
    final keymap = ref.watch(keymapProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => CallbackShortcuts(
        bindings: resolveShortcuts(keymap, {
          'commit.confirm': controller.canAccept ? () => _accept(false) : null,
          'commit.confirmAndPush': controller.canAccept
              ? () => _accept(true)
              : null,
        }),
        child: SizedSheet(
          width: _width(context),
          height: _height(context),
          child: CommitComposer(
            controller: controller,
            presentation: CommitComposerPresentation.expanded,
            branchLabel: widget.branchLabel,
            onAccept: _accept,
            focused: true,
          ),
        ),
      ),
    );
  }
}
