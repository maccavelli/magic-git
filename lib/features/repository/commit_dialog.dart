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

/// Optional focused editor around the same repository-scoped composer used by
/// the Repository task dock. Closing this wrapper never discards its draft.
class CommitDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final int stagedCount;

  const CommitDialog({
    super.key,
    required this.repoPath,
    required this.stagedCount,
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
    );
    if (!mounted || !outcome.localCommitted) return;
    refreshAfterMutation(ref, widget.repoPath);
    if (!push) {
      unawaited(
        ref
            .read(connectionProvider.notifier)
            .fetchInBackground(widget.repoPath),
      );
    }
    if (context.mounted) Navigator.of(context).pop(push);
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
