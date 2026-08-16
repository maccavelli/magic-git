import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
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

  const CommitDialog({
    super.key,
    required this.repoPath,
    required this.stagedCount,
    required this.onPush,
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
    _escInterceptorDisposer ??= EscapeInterceptor.of(
      context,
      () => _controller.committing,
    );
  }

  @override
  void dispose() {
    _escInterceptorDisposer?.call();
    super.dispose();
  }

  Future<void> _accept(bool push) async {
    final controller = _controller;
    final outcome = await controller.submit(
      commit: (message) => runAction(
        context,
        () => ref
            .read(gitServiceProvider)
            .commit(widget.repoPath, message: message),
      ),
      push: push ? widget.onPush : null,
    );
    // A commit that did not land leaves the sheet open with the message
    // intact; `submit` has already recorded the reason on the controller.
    if (!mounted || !outcome.localCommitted) return;
    refreshAfterMutation(ref, widget.repoPath);
    if (!push) {
      unawaited(
        ref
            .read(connectionProvider.notifier)
            .fetchInBackground(widget.repoPath),
      );
    }
    // The push already ran inside `submit`, so the result reports only that
    // the commit landed — no caller has follow-up work to do.
    if (context.mounted) Navigator.of(context).pop(true);
  }

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
    controller.updateStaged(
      count: widget.stagedCount,
      signature: 'focused:${widget.stagedCount}',
    );
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
          width: 760,
          child: SizedBox(
            height: 390,
            child: CommitComposer(
              controller: controller,
              presentation: CommitComposerPresentation.expanded,
              branchLabel: 'current branch',
              onAccept: _accept,
              focused: true,
            ),
          ),
        ),
      ),
    );
  }
}
