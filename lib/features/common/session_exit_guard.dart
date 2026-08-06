import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import 'actions.dart';

/// Confirms disconnect / tab-close when the active repo has uncommitted work
/// or a mid-flight merge/rebase/cherry-pick/revert (audit H8).
///
/// Returns true when the caller should proceed with disconnect. Clean trees
/// proceed without a dialog. [container] is the session container that owns
/// [repoPath] (active tab for Logout, the closing tab for tab-close).
Future<bool> confirmSessionExit(
  BuildContext context,
  ProviderContainer container, {
  required String repoPath,
  required String title,
}) async {
  var status = container.read(statusProvider(repoPath)).value;
  if (status == null) {
    final fetched = await runAction(context, () async {
      status = await container.read(statusProvider(repoPath).future);
    });
    if (!fetched || !context.mounted) return false;
  }

  final dirty = status != null && !status!.isClean;
  final pending =
      container.read(pendingOpProvider(repoPath)).value ?? PendingOp.none;
  final hasPending = pending != PendingOp.none;

  if (!dirty && !hasPending) return true;
  if (!context.mounted) return false;

  final parts = <String>[];
  if (dirty) {
    parts.add('You have uncommitted changes in this repository.');
  }
  if (hasPending) {
    parts.add(
      'A ${pending.name} is still in progress. Use Recovery or the '
      'Repository banner to continue or abort before leaving if you need to '
      'finish it.',
    );
  }
  parts.add(
    'Logging out or closing this tab does not delete files on the host, '
    'but you will leave this session.',
  );

  return confirmAction(
    context,
    title: title,
    message: parts.join('\n\n'),
    confirmLabel: title.contains('Close') ? 'Close Tab' : 'Log Out',
    destructive: true,
  );
}
